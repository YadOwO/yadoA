import Foundation
import SwiftData

/// 本地收支写入边界产生的错误。
enum ExpenseRepositoryError: Error, Equatable {
    /// 相同流水 UUID 已经存在，拒绝覆盖或再次联动账户金额。
    case duplicateID(UUID)

    /// 快速修改对应的流水不存在。
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
        let modelContext = makeContext()
        guard try !containsTransaction(id: draft.id, in: modelContext) else {
            throw ExpenseRepositoryError.duplicateID(draft.id)
        }

        let transaction = try AccountTransaction.validating(
            draft: draft,
            savedAt: savedAt
        )
        guard let account = try account(id: transaction.accountID, in: modelContext) else {
            throw ExpenseRepositoryError.accountNotFound(transaction.accountID)
        }
        guard account.isActive else {
            throw ExpenseRepositoryError.accountDeactivated(transaction.accountID)
        }
        guard account.currencyCode == transaction.currencyCode else {
            throw ExpenseRepositoryError.unsupportedCurrency(account.currencyCode)
        }
        guard account.supportsBookkeeping, let accountType = account.accountType else {
            throw ExpenseRepositoryError.unsupportedAccountType(account.typeRawValue)
        }
        let payload = try transaction.validatedPayload()
        guard let (amount, entryType) = Self.amountAndEntryType(for: payload) else {
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
        do {
            try beforeSave()
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// 校验并原子更新一笔已有收支流水，同时修正绑定账户的金额。
    ///
    /// 标题只更新流水自身；金额更新会先抵消旧支出，再按账户类型应用新支出，
    /// 因此重复提交、金额变大或变小都不会累积错误余额。
    ///
    /// - Parameter draft: 首页快速修改页面提交的值类型草稿。
    /// - Throws: 流水、账户、金额、标题或保存边界不符合约束时抛出对应错误。
    func update(_ draft: DiningExpenseEditDraft) throws {
        let modelContext = makeContext()
        guard let transaction = try transaction(id: draft.id, in: modelContext) else {
            throw ExpenseRepositoryError.transactionNotFound(draft.id)
        }
        guard let payload = try? transaction.validatedPayload() else {
            throw ExpenseRepositoryError.transactionNotEditable(draft.id)
        }
        guard let (oldAmount, entryType) = Self.amountAndEntryType(for: payload) else {
            throw ExpenseRepositoryError.transactionNotEditable(draft.id)
        }
        guard let newAmount = draft.amount else {
            throw AccountTransactionValidationError.invalidAmount
        }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw DiningExpenseEditDraftValidationError.titleRequired
        }

        guard let account = try account(id: transaction.accountID, in: modelContext) else {
            throw ExpenseRepositoryError.accountNotFound(transaction.accountID)
        }
        guard account.isActive else {
            throw ExpenseRepositoryError.accountDeactivated(transaction.accountID)
        }
        guard account.currencyCode == transaction.currencyCode else {
            throw ExpenseRepositoryError.unsupportedCurrency(account.currencyCode)
        }
        guard account.supportsBookkeeping, let accountType = account.accountType else {
            throw ExpenseRepositoryError.unsupportedAccountType(account.typeRawValue)
        }

        let updatedBalance = try Self.updatedBalance(
            account.balance,
            from: oldAmount,
            to: newAmount,
            effect: accountType.expenseBalanceEffect,
            entryType: entryType
        )

        transaction.title = title
        transaction.amount = newAmount
        account.balance = updatedBalance
        do {
            try beforeSave()
            try modelContext.save()
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

    /// 判断指定 UUID 的流水是否已经存在，避免实例化无须读取的完整模型。
    private func containsTransaction(id: UUID, in modelContext: ModelContext) throws -> Bool {
        let transactionID = id
        let descriptor = FetchDescriptor<AccountTransaction>(
            predicate: #Predicate<AccountTransaction> { transaction in
                transaction.id == transactionID
            }
        )
        return try modelContext.fetchCount(descriptor) > 0
    }

    /// 获取指定 UUID 的流水。
    private func transaction(
        id: UUID,
        in modelContext: ModelContext
    ) throws -> AccountTransaction? {
        let transactionID = id
        var descriptor = FetchDescriptor<AccountTransaction>(
            predicate: #Predicate<AccountTransaction> { transaction in
                transaction.id == transactionID
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /// 从可编辑的收支载荷中提取金额与方向。
    private static func amountAndEntryType(
        for payload: AccountTransactionPayload
    ) -> (Decimal, BookkeepingEntryType)? {
        switch payload {
        case let .expense(_, amount):
            (amount, .expense)
        case let .income(_, amount):
            (amount, .income)
        case .balanceAdjustment:
            nil
        }
    }

    /// 根据账户语义计算收支后的精确金额，并拒绝溢出或精度损失。
    private static func updatedBalance(
        _ balance: Decimal,
        by amount: Decimal,
        effect: ExpenseBalanceEffect,
        entryType: BookkeepingEntryType
    ) throws -> Decimal {
        var currentBalance = balance
        var amount = amount
        var result = Decimal()
        let calculationError: Decimal.CalculationError
        switch (entryType, effect) {
        case (.expense, .decreaseValue), (.income, .increaseDebt):
            calculationError = NSDecimalSubtract(
                &result,
                &currentBalance,
                &amount,
                .plain
            )
        case (.expense, .increaseDebt), (.income, .decreaseValue):
            calculationError = NSDecimalAdd(
                &result,
                &currentBalance,
                &amount,
                .plain
            )
        }
        guard calculationError == .noError else {
            throw ExpenseRepositoryError.balanceCalculationFailed
        }
        return result
    }

    /// 根据旧、新记账金额的差值修正账户余额。
    private static func updatedBalance(
        _ balance: Decimal,
        from oldAmount: Decimal,
        to newAmount: Decimal,
        effect: ExpenseBalanceEffect,
        entryType: BookkeepingEntryType
    ) throws -> Decimal {
        var oldAmount = oldAmount
        var newAmount = newAmount
        var amountDelta = Decimal()
        guard NSDecimalSubtract(
            &amountDelta,
            &newAmount,
            &oldAmount,
            .plain
        ) == .noError else {
            throw ExpenseRepositoryError.balanceCalculationFailed
        }

        return try updatedBalance(
            balance,
            by: amountDelta,
            effect: effect,
            entryType: entryType
        )
    }

    /// 创建一个关闭自动保存的新鲜 context。
    private func makeContext() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }
}
