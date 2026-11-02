import Foundation
import SwiftData

/// 本地余额调整写入边界产生的错误。
enum BalanceAdjustmentRepositoryError: Error, Equatable {
    /// 相同流水 UUID 已存在，拒绝再次联动账户余额。
    case duplicateID(UUID)

    /// 草稿绑定的账户不存在。
    case accountNotFound(UUID)

    /// 停用账户不能再新增余额调整流水。
    case accountDeactivated(UUID)

    /// 未知账户类型不能安全执行余额调整。
    case unsupportedAccountType(String)

    /// 当前版本仅允许 CNY 账户调整余额。
    case unsupportedCurrency(String)

    /// 存量账户余额超过 CNY 两位小数精度，不能静默舍入。
    case unsupportedStoredBalancePrecision

    /// 草稿目标总余额无效。
    case invalidTargetBalance

    /// 要删除的流水不存在。
    case transactionNotFound(UUID)

    /// 要删除的流水不是余额调整。
    case notBalanceAdjustment(UUID)
}

/// 在主 actor 上原子设置账户目标总余额并新增调整流水的本地仓库。
@MainActor
final class LocalBalanceAdjustmentRepository {
    /// 应用或测试持有的完整本地财务容器。
    private let container: ModelContainer

    /// 测试可注入的保存前故障点；生产环境默认为空操作。
    private let beforeSave: () throws -> Void

    /// 使用应用级容器创建余额调整仓库。
    ///
    /// - Parameters:
    ///   - container: 应用或测试持有的完整本地财务容器。
    ///   - beforeSave: 流水与余额均完成内存修改后、显式保存前执行的故障点。
    init(
        container: ModelContainer,
        beforeSave: @escaping () throws -> Void = {}
    ) {
        self.container = container
        self.beforeSave = beforeSave
    }

    /// 重新读取账户实际余额，并通过一次显式保存设置目标总余额和新增调整流水。
    ///
    /// - Parameters:
    ///   - draft: Sheet 提交时复制的稳定草稿。
    ///   - now: 保存时间；没有指定记账日时也作为业务日。
    ///   - calendar: 生成当天 `YYYYMMDD` 时使用的日历。
    ///   - transactionDay: 指定的 `YYYYMMDD` 记账日，例如语音里说了日期的单边转账；为空时取当天。
    /// - Returns: 成功保存的值类型回执，或没有变化的当前余额。
    /// - Throws: 草稿、账户、币种、精度、UUID 或持久化不符合约束时抛出错误。
    func save(
        _ draft: BalanceAdjustmentDraft,
        now: Date = .now,
        calendar: Calendar = .current,
        transactionDay: Int? = nil
    ) throws -> BalanceAdjustmentSaveResult {
        let modelContext = container.makeManualSaveContext()

        guard let targetBalance = draft.targetBalance else {
            throw BalanceAdjustmentRepositoryError.invalidTargetBalance
        }
        guard try !modelContext.containsTransaction(id: draft.id) else {
            throw BalanceAdjustmentRepositoryError.duplicateID(draft.id)
        }
        guard let account = try modelContext.account(id: draft.accountID) else {
            throw BalanceAdjustmentRepositoryError.accountNotFound(draft.accountID)
        }
        guard account.isActive else {
            throw BalanceAdjustmentRepositoryError.accountDeactivated(draft.accountID)
        }
        guard account.supportsBookkeeping else {
            throw BalanceAdjustmentRepositoryError.unsupportedAccountType(account.typeRawValue)
        }
        guard account.currencyCode == "CNY" else {
            throw BalanceAdjustmentRepositoryError.unsupportedCurrency(account.currencyCode)
        }
        guard AccountAmountParser.hasCNYPrecision(account.balance) else {
            throw BalanceAdjustmentRepositoryError.unsupportedStoredBalancePrecision
        }
        guard targetBalance != account.balance else {
            return .unchanged(currentBalance: account.balance)
        }

        let transaction = try AccountTransaction.validatingBalanceAdjustment(
            id: draft.id,
            accountID: draft.accountID,
            balanceBefore: account.balance,
            balanceAfter: targetBalance,
            transactionDay: transactionDay ?? TransactionDay.encode(now, calendar: calendar),
            note: draft.note,
            savedAt: now
        )
        modelContext.insert(transaction)
        account.balance = targetBalance
        try modelContext.saveOrRollback(beforeSave: beforeSave)
        return .saved(currentBalance: targetBalance)
    }

    /// 在调用方的 context 中删除一笔余额调整，并从账户余额中扣回它的差额；不保存。
    ///
    /// 只用于撤销语音会话刚写入的调整：按差额扣回而不是还原成调整前的余额，期间其他流水对余额的影响得以保留，
    /// 与 `AccountBalanceRebuilder` 只累加差额的规则一致。
    ///
    /// - Parameters:
    ///   - id: 待删除余额调整的稳定 UUID。
    ///   - context: 调用方的 manual-save context。
    /// - Throws: 流水不存在、不是余额调整、账户不存在或已停用、金额计算失败时抛出错误，由调用方回滚。
    static func delete(id: UUID, in context: ModelContext) throws {
        guard let transaction = try context.transaction(id: id) else {
            throw BalanceAdjustmentRepositoryError.transactionNotFound(id)
        }
        guard case let .balanceAdjustment(_, _, delta)? = try? transaction.validatedPayload() else {
            throw BalanceAdjustmentRepositoryError.notBalanceAdjustment(id)
        }
        guard let account = try context.account(id: transaction.accountID) else {
            throw BalanceAdjustmentRepositoryError.accountNotFound(transaction.accountID)
        }
        // 与转账、收支一致：停用账户的余额不能再变，否则会出现余额不为 0 的停用账户
        guard account.isActive else {
            throw BalanceAdjustmentRepositoryError.accountDeactivated(account.id)
        }
        guard let balance = account.balance.exactlyAdding(-delta) else {
            throw ExpenseRepositoryError.balanceCalculationFailed
        }
        account.balance = balance
        context.delete(transaction)
    }
}
