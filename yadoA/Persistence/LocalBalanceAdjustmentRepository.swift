import Foundation
import SwiftData

/// 本地余额调整写入边界产生的错误。
enum BalanceAdjustmentRepositoryError: Error, Equatable {
    /// 相同流水 UUID 已存在，拒绝再次联动账户余额。
    case duplicateID(UUID)

    /// 草稿绑定的账户不存在。
    case accountNotFound(UUID)

    /// 当前版本仅允许 CNY 账户调整余额。
    case unsupportedCurrency(String)

    /// 存量账户余额超过 CNY 两位小数精度，不能静默舍入。
    case unsupportedStoredBalancePrecision

    /// 草稿目标总余额无效。
    case invalidTargetBalance
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
    ///   - now: 同时用于业务日与保存时间的注入时刻。
    ///   - calendar: 生成当天 `YYYYMMDD` 时使用的日历。
    /// - Returns: 成功保存的值类型回执，或没有变化的当前余额。
    /// - Throws: 草稿、账户、币种、精度、UUID 或持久化不符合约束时抛出错误。
    func save(
        _ draft: BalanceAdjustmentDraft,
        now: Date = .now,
        calendar: Calendar = .current
    ) throws -> BalanceAdjustmentSaveResult {
        let modelContext = ModelContext(container)
        modelContext.autosaveEnabled = false

        guard let targetBalance = draft.targetBalance else {
            throw BalanceAdjustmentRepositoryError.invalidTargetBalance
        }
        guard try !containsTransaction(id: draft.id, in: modelContext) else {
            throw BalanceAdjustmentRepositoryError.duplicateID(draft.id)
        }
        guard let account = try account(id: draft.accountID, in: modelContext) else {
            throw BalanceAdjustmentRepositoryError.accountNotFound(draft.accountID)
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
            transactionDay: TransactionDay.encode(now, calendar: calendar),
            note: draft.note,
            savedAt: now
        )
        modelContext.insert(transaction)
        account.balance = targetBalance
        do {
            try beforeSave()
            try modelContext.save()
            return .saved(currentBalance: targetBalance)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// 获取指定 UUID 的账户。
    private func account(id: UUID, in modelContext: ModelContext) throws -> Account? {
        let accountID = id
        var descriptor = FetchDescriptor<Account>(
            predicate: #Predicate<Account> { account in
                account.id == accountID
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /// 跨全部账户流水类型检查 UUID，防止重复联动余额。
    private func containsTransaction(
        id: UUID,
        in modelContext: ModelContext
    ) throws -> Bool {
        let transactionID = id
        let descriptor = FetchDescriptor<AccountTransaction>(
            predicate: #Predicate<AccountTransaction> { transaction in
                transaction.id == transactionID
            }
        )
        return try modelContext.fetchCount(descriptor) > 0
    }

}
