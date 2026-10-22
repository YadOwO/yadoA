import Foundation
import SwiftData

/// 本地收支写入边界产生的错误。
enum ExpenseRepositoryError: Error, Equatable {
    /// 相同流水 UUID 已经存在，拒绝覆盖或再次联动账户金额。
    case duplicateID(UUID)

    /// 修改或删除对应的流水不存在。
    case transactionNotFound(UUID)

    /// 当前版本只允许修改收入或支出流水。
    case transactionNotEditable(UUID)

    /// 草稿绑定的账户不存在。
    case accountNotFound(UUID)

    /// 停用账户不能继续修改或写入收支流水。
    case accountDeactivated(UUID)

    /// 持久化账户类型未知，无法安全判断金额影响方向。
    case unsupportedAccountType(String)

    /// 当前版本仅允许 CNY 账户记录支出。
    case unsupportedCurrency(String)

    /// 精确十进制金额计算失败。
    case balanceCalculationFailed

    /// 流水引用的分类不存在或已删除。
    case categoryUnavailable(String)
}

/// 在主 actor 上原子保存收支流水和账户金额变化的本地仓库。
@MainActor
final class LocalExpenseRepository {
    /// 应用或测试持有的完整本地财务容器；每次保存命令创建新鲜 context。
    private let container: ModelContainer

    /// 测试可注入的保存前故障点；生产环境默认为空操作。
    private let beforeSave: () throws -> Void

    /// 使用应用级容器创建串行写入仓库。
    ///
    /// - Parameters:
    ///   - container: 应用或测试持有的完整本地财务容器。
    ///   - beforeSave: 流水与金额均完成内存修改后、显式保存前执行的故障点。
    init(
        container: ModelContainer,
        beforeSave: @escaping () throws -> Void = {}
    ) {
        self.container = container
        self.beforeSave = beforeSave
    }

    /// 校验草稿，并通过一次显式保存同时新增流水和联动账户金额。
    ///
    /// - Parameters:
    ///   - draft: 页面提交时复制的稳定草稿。
    ///   - savedAt: 注入的保存时间，供同日流水排序使用。
    /// - Throws: 流水重复、草稿无效、账户不可用、金额计算或保存失败时抛出错误。
    func save(
        _ draft: DiningExpenseDraft,
        savedAt: Date = .now
    ) throws {
        let modelContext = container.makeManualSaveContext()
        guard try !modelContext.containsTransaction(id: draft.id) else {
            throw ExpenseRepositoryError.duplicateID(draft.id)
        }

        let transaction = try AccountTransaction.validating(
            draft: draft,
            savedAt: savedAt
        )
        let (account, accountType) = try Self.bookkeepingAccount(id: transaction.accountID, in: modelContext)
        let payload = try transaction.validatedPayload()
        try requireAvailableCategory(of: payload, in: modelContext)
        guard let (entryType, amount) = payload.bookkeepingAmount else {
            throw AccountTransactionValidationError.invalidPayload
        }
        let updatedBalance = try Self.updatedBalance(
            account.balance,
            by: amount,
            effect: accountType.expenseBalanceEffect,
            entryType: entryType
        )

        modelContext.insert(transaction)
        account.balance = updatedBalance
        try modelContext.saveOrRollback(beforeSave: beforeSave)
    }

    /// 校验并原子更新一笔已有收支流水，同时修正绑定账户的金额。
    ///
    /// 撤销旧收支影响，再应用新收支影响；同一账户只施加净差额。
    /// 始终从当前余额修正，业务日不承担余额重放，既有调整快照保持原样。
    ///
    /// - Parameter draft: 完整编辑页面提交的值类型草稿。
    /// - Throws: 流水、账户、金额、标题或保存边界不符合约束时抛出对应错误。
    func update(_ draft: DiningExpenseEditDraft) throws {
        let modelContext = container.makeManualSaveContext()
        guard let transaction = try modelContext.transaction(id: draft.id) else {
            throw ExpenseRepositoryError.transactionNotFound(draft.id)
        }
        let replacement = try draft.validatedTransaction(savedAt: transaction.savedAt)
        try replace(transaction, with: replacement, in: modelContext)
        try modelContext.saveOrRollback(beforeSave: beforeSave)
    }

    /// 在同一个 context 中依次执行一批收支变更，全部成功后保存一次；任一步失败则整体回滚。
    ///
    /// 每一步都走与新增、修改、删除相同的账户、分类、金额校验和余额联动。
    /// 语音记账逐条执行工具调用，以及撤销一轮语音改动时都使用它，保证不会只写入或撤销一半。
    ///
    /// - Parameter mutations: 按顺序执行的变更；后面的变更能看到前面变更的结果。
    /// - Throws: 任一变更不符合约束或保存失败时抛出对应错误，此时没有任何变更生效。
    func apply(_ mutations: [BookkeepingEntryMutation]) throws {
        let modelContext = container.makeManualSaveContext()
        for mutation in mutations {
            switch mutation {
            case let .insert(snapshot):
                guard try !modelContext.containsTransaction(id: snapshot.id) else {
                    throw ExpenseRepositoryError.duplicateID(snapshot.id)
                }
                let transaction = try snapshot.validatedTransaction()
                let (account, accountType) = try Self.bookkeepingAccount(id: transaction.accountID, in: modelContext)
                try requireAvailableCategory(of: transaction.validatedPayload(), in: modelContext)
                account.balance = try Self.updatedBalance(
                    account.balance, by: snapshot.amount,
                    effect: accountType.expenseBalanceEffect, entryType: snapshot.entryType
                )
                modelContext.insert(transaction)
            case let .replace(snapshot):
                guard let transaction = try modelContext.transaction(id: snapshot.id) else {
                    throw ExpenseRepositoryError.transactionNotFound(snapshot.id)
                }
                try replace(transaction, with: snapshot.validatedTransaction(), in: modelContext)
            case let .delete(id):
                guard let transaction = try modelContext.transaction(id: id) else {
                    throw ExpenseRepositoryError.transactionNotFound(id)
                }
                try Self.deleteTransactionsReversingBalances([transaction], in: modelContext)
            }
        }
        try modelContext.saveOrRollback(beforeSave: beforeSave)
    }

    /// 用已校验的替换值改写一笔收支，并修正新旧账户的余额；不保存。
    ///
    /// 撤销旧收支影响，再应用新收支影响；同一账户只施加净差额。
    /// 始终从当前余额修正，业务日不承担余额重放，既有调整快照保持原样。
    ///
    /// - Parameters:
    ///   - transaction: 已从 `modelContext` 读取的待修改流水。
    ///   - replacement: 尚未插入 context 的替换值，`id` 与 `savedAt` 不会被采用。
    ///   - modelContext: 调用方的 manual-save context。
    /// - Throws: 流水不可编辑、账户不可用、分类不可用或金额计算失败时抛出错误。
    private func replace(
        _ transaction: AccountTransaction,
        with replacement: AccountTransaction,
        in modelContext: ModelContext
    ) throws {
        let (oldAmount, oldEntryType) = try Self.editableAmountAndType(for: transaction)
        let (newAmount, newEntryType) = try Self.editableAmountAndType(for: replacement)
        try requireAvailableCategory(of: replacement.validatedPayload(), in: modelContext)
        let (source, sourceType) = try Self.bookkeepingAccount(id: transaction.accountID, in: modelContext)

        if source.id == replacement.accountID {
            source.balance = try Self.updatedBalance(
                source.balance, from: oldAmount, oldEntryType: oldEntryType,
                to: newAmount, newEntryType: newEntryType, effect: sourceType.expenseBalanceEffect
            )
        } else {
            let (target, targetType) = try Self.bookkeepingAccount(id: replacement.accountID, in: modelContext)
            let restoredBalance = try Self.updatedBalance(
                source.balance, by: -oldAmount,
                effect: sourceType.expenseBalanceEffect, entryType: oldEntryType
            )
            let targetBalance = try Self.updatedBalance(
                target.balance, by: newAmount,
                effect: targetType.expenseBalanceEffect, entryType: newEntryType
            )
            source.balance = restoredBalance
            target.balance = targetBalance
        }
        transaction.accountID = replacement.accountID
        transaction.typeRawValue = replacement.typeRawValue
        transaction.categoryRawValue = replacement.categoryRawValue
        transaction.title = replacement.title
        transaction.amount = replacement.amount
        transaction.transactionDay = replacement.transactionDay
        transaction.note = replacement.note
    }

    /// 原子删除一笔收支，并撤销其对当前账户余额的影响；不允许删除调整快照。
    /// - Parameter id: 待删除流水的稳定 UUID，重复提交会报告流水不存在。
    func delete(id: UUID) throws {
        let context = container.makeManualSaveContext()
        guard let transaction = try context.transaction(id: id) else {
            throw ExpenseRepositoryError.transactionNotFound(id)
        }
        try Self.deleteTransactionsReversingBalances([transaction], in: context)
        try context.saveOrRollback(beforeSave: beforeSave)
    }

    /// 在调用方的 context 中删除一批收支，并撤销它们对账户余额的影响；不保存。
    ///
    /// 单笔删除和删除分类时「流水一并删除」共用这套校验与余额计算，由调用方统一保存或回滚。
    ///
    /// - Parameters:
    ///   - transactions: 已从 `context` 读取的收支流水。
    ///   - context: 调用方的 manual-save context。
    /// - Throws: 流水不可编辑、账户不存在或已停用、金额计算失败时抛出错误。
    static func deleteTransactionsReversingBalances(
        _ transactions: [AccountTransaction],
        in context: ModelContext
    ) throws {
        for transaction in transactions {
            let (amount, entryType) = try editableAmountAndType(for: transaction)
            let (account, accountType) = try bookkeepingAccount(id: transaction.accountID, in: context)
            account.balance = try updatedBalance(
                account.balance, by: -amount,
                effect: accountType.expenseBalanceEffect, entryType: entryType
            )
            context.delete(transaction)
        }
    }

    /// 修改与删除共用的合法收支边界，拒绝币种转换和损坏载荷。
    private static func editableAmountAndType(
        for transaction: AccountTransaction
    ) throws -> (Decimal, BookkeepingEntryType) {
        guard let (entryType, amount) = try? transaction.validatedPayload().bookkeepingAmount
        else { throw ExpenseRepositoryError.transactionNotEditable(transaction.id) }
        guard transaction.currencyCode == "CNY" else {
            throw ExpenseRepositoryError.unsupportedCurrency(transaction.currencyCode)
        }
        return (amount, entryType)
    }

    /// 最终写入前确认分类仍可使用，避免记账期间分类在别处被删除。
    private func requireAvailableCategory(
        of payload: AccountTransactionPayload,
        in context: ModelContext
    ) throws {
        guard let reference = payload.categoryReference else { return }
        guard try context.isCategoryAvailable(key: reference.key, direction: reference.direction) else {
            throw ExpenseRepositoryError.categoryUnavailable(reference.key)
        }
    }

    /// 最终写入前重新校验账户，避免编辑期间停用、删除或类型变化绕过限制。
    private static func bookkeepingAccount(id: UUID, in context: ModelContext) throws -> (Account, AccountType) {
        guard let account = try context.account(id: id) else {
            throw ExpenseRepositoryError.accountNotFound(id)
        }
        guard account.isActive else { throw ExpenseRepositoryError.accountDeactivated(id) }
        guard account.currencyCode == "CNY" else {
            throw ExpenseRepositoryError.unsupportedCurrency(account.currencyCode)
        }
        guard account.supportsBookkeeping, let type = account.accountType else {
            throw ExpenseRepositoryError.unsupportedAccountType(account.typeRawValue)
        }
        return (account, type)
    }

    /// 根据账户语义计算收支后的精确金额，并拒绝溢出或精度损失；转账按转出记支出、转入记收入复用这套方向规则。
    ///
    /// - Parameters:
    ///   - balance: 账户当前余额。
    ///   - amount: 正数收支金额，撤销时传入负数。
    ///   - effect: 账户类型决定的支出影响方向。
    ///   - entryType: 收支方向。
    /// - Returns: 应用后的精确余额。
    /// - Throws: 精确十进制计算失败时抛出 `ExpenseRepositoryError.balanceCalculationFailed`。
    static func updatedBalance(
        _ balance: Decimal,
        by amount: Decimal,
        effect: ExpenseBalanceEffect,
        entryType: BookkeepingEntryType
    ) throws -> Decimal {
        try adding(balanceChange(amount, effect: effect, entryType: entryType), to: balance)
    }

    /// 把正数收支金额转换为对账户余额的带符号影响，撤销时可传入负数金额。
    private static func balanceChange(
        _ amount: Decimal,
        effect: ExpenseBalanceEffect,
        entryType: BookkeepingEntryType
    ) -> Decimal {
        switch (entryType, effect) {
        case (.expense, .decreaseValue), (.income, .increaseDebt): -amount
        case (.expense, .increaseDebt), (.income, .decreaseValue): amount
        }
    }

    /// 使用精确十进制加法应用余额变化，拒绝溢出和精度损失。
    private static func adding(_ change: Decimal, to balance: Decimal) throws -> Decimal {
        var currentBalance = balance
        var change = change
        var result = Decimal()
        guard NSDecimalAdd(&result, &currentBalance, &change, .plain) == .noError else {
            throw ExpenseRepositoryError.balanceCalculationFailed
        }
        return result
    }

    /// 根据旧、新记账金额的差值修正账户余额。
    private static func updatedBalance(
        _ balance: Decimal,
        from oldAmount: Decimal,
        oldEntryType: BookkeepingEntryType,
        to newAmount: Decimal,
        newEntryType: BookkeepingEntryType,
        effect: ExpenseBalanceEffect
    ) throws -> Decimal {
        var oldAmount = balanceChange(oldAmount, effect: effect, entryType: oldEntryType)
        var newAmount = balanceChange(newAmount, effect: effect, entryType: newEntryType)
        var amountDelta = Decimal()
        guard NSDecimalSubtract(
            &amountDelta,
            &newAmount,
            &oldAmount,
            .plain
        ) == .noError else {
            throw ExpenseRepositoryError.balanceCalculationFailed
        }

        return try adding(amountDelta, to: balance)
    }
}
