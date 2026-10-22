import Foundation
import SwiftData

/// 本地转账写入边界产生的错误。
enum TransferRepositoryError: Error, Equatable {
    /// 相同流水 UUID 已存在，拒绝再次联动账户余额。
    case duplicateID(UUID)

    /// 草稿缺少金额或账户，或转入转出是同一个账户。
    case invalidDraft

    /// 转出或转入账户不存在。
    case accountNotFound(UUID)

    /// 停用账户不能转账，也不能撤回涉及它的转账。
    case accountDeactivated(UUID)

    /// 未知账户类型无法判断余额方向。
    case unsupportedAccountType(String)

    /// 当前版本仅允许 CNY 账户转账。
    case unsupportedCurrency(String)

    /// 要删除的流水不存在。
    case transactionNotFound(UUID)

    /// 要删除的流水不是转账。
    case notTransfer(UUID)
}

/// 在主 actor 上原子保存或删除转账，并同时联动转出、转入两个账户余额的本地仓库。
///
/// 转账只挂一条流水在转出账户上，转入账户通过 `counterpartAccountID` 关联；
/// 对转出账户按支出、对转入账户按收入计算余额方向，信用卡和负债账户因此自动按“债务增减”处理。
@MainActor
final class LocalTransferRepository {
    /// 应用或测试持有的完整本地财务容器。
    private let container: ModelContainer

    /// 测试可注入的保存前故障点；生产环境默认为空操作。
    private let beforeSave: () throws -> Void

    /// 使用应用级容器创建转账仓库。
    ///
    /// - Parameters:
    ///   - container: 应用或测试持有的完整本地财务容器。
    ///   - beforeSave: 流水与两边余额均完成内存修改后、显式保存前执行的故障点。
    init(
        container: ModelContainer,
        beforeSave: @escaping () throws -> Void = {}
    ) {
        self.container = container
        self.beforeSave = beforeSave
    }

    /// 校验草稿并通过一次显式保存新增转账、扣减转出账户、增加转入账户。
    ///
    /// - Parameters:
    ///   - draft: 表单提交时复制的稳定草稿。
    ///   - savedAt: 注入的保存时间，供同日流水排序使用。
    /// - Throws: 草稿无效、账户不可用、UUID 重复、金额计算或保存失败时抛出错误。
    func save(_ draft: TransferDraft, savedAt: Date = .now) throws {
        guard draft.isComplete,
              let amount = draft.amount,
              let fromAccountID = draft.fromAccountID,
              let toAccountID = draft.toAccountID
        else {
            throw TransferRepositoryError.invalidDraft
        }
        let context = container.makeManualSaveContext()
        guard try !context.containsTransaction(id: draft.id) else {
            throw TransferRepositoryError.duplicateID(draft.id)
        }
        let (fromAccount, fromType) = try Self.transferAccount(id: fromAccountID, in: context)
        let (toAccount, toType) = try Self.transferAccount(id: toAccountID, in: context)

        let transaction = try AccountTransaction.validatingTransfer(
            id: draft.id,
            fromAccountID: fromAccountID,
            toAccountID: toAccountID,
            amount: amount,
            transactionDay: draft.transactionDay,
            note: draft.note,
            savedAt: savedAt
        )
        context.insert(transaction)
        try Self.apply(
            amount,
            from: (fromAccount, fromType),
            to: (toAccount, toType)
        )
        try context.saveOrRollback(beforeSave: beforeSave)
    }

    /// 原子删除一笔转账，并把金额退回转出账户、从转入账户扣回。
    ///
    /// - Parameter id: 待删除转账的稳定 UUID；重复提交会报告流水不存在。
    /// - Throws: 流水不存在、不是转账、任一账户不可用或保存失败时抛出错误。
    func delete(id: UUID) throws {
        let context = container.makeManualSaveContext()
        guard let transaction = try context.transaction(id: id) else {
            throw TransferRepositoryError.transactionNotFound(id)
        }
        guard case let .transfer(toAccountID, amount)? = try? transaction.validatedPayload() else {
            throw TransferRepositoryError.notTransfer(id)
        }
        let from = try Self.transferAccount(id: transaction.accountID, in: context)
        let to = try Self.transferAccount(id: toAccountID, in: context)
        try Self.apply(-amount, from: from, to: to)
        context.delete(transaction)
        try context.saveOrRollback(beforeSave: beforeSave)
    }

    /// 把转账金额同时应用到两个账户；撤销时传入负数金额。
    private static func apply(
        _ amount: Decimal,
        from: (account: Account, type: AccountType),
        to: (account: Account, type: AccountType)
    ) throws {
        from.account.balance = try LocalExpenseRepository.updatedBalance(
            from.account.balance,
            by: amount,
            effect: from.type.expenseBalanceEffect,
            entryType: .expense
        )
        to.account.balance = try LocalExpenseRepository.updatedBalance(
            to.account.balance,
            by: amount,
            effect: to.type.expenseBalanceEffect,
            entryType: .income
        )
    }

    /// 最终写入前重新校验账户，避免表单打开期间账户被停用、删除或类型变化。
    private static func transferAccount(id: UUID, in context: ModelContext) throws -> (Account, AccountType) {
        guard let account = try context.account(id: id) else {
            throw TransferRepositoryError.accountNotFound(id)
        }
        guard account.isActive else { throw TransferRepositoryError.accountDeactivated(id) }
        guard account.currencyCode == "CNY" else {
            throw TransferRepositoryError.unsupportedCurrency(account.currencyCode)
        }
        guard account.supportsBookkeeping, let type = account.accountType else {
            throw TransferRepositoryError.unsupportedAccountType(account.typeRawValue)
        }
        return (account, type)
    }
}
