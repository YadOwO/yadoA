import Foundation
import SwiftData

/// 按「期初余额 + 全部流水影响」重算账户余额缓存。
///
/// 各仓库写入时仍对 `Account.balance` 做增量更新；这里给出同一规则的全量版本，
/// 用于导入备份、应用其他设备同步来的流水之后，把余额缓存恢复成与流水一致的值。
/// 规则与仓库保持一致：
/// - 收支按账户类型的 `expenseBalanceEffect` 决定加减；
/// - 转账对转出账户按支出、对转入账户按收入计算；
/// - 余额调整只累加 `balanceDelta`，不采用调整时记录的目标余额。
enum AccountBalanceRebuilder {
    /// 计算一组流水对各账户余额的累计影响。
    ///
    /// 字段组合损坏的流水跳过；账户类型未知时无法判断方向，该账户不出现在结果里。
    ///
    /// - Parameters:
    ///   - transactions: 参与计算的流水。
    ///   - accountTypes: 账户 UUID 到已知账户类型的映射。
    /// - Returns: 账户 UUID 到累计余额影响的映射；没有流水的已知账户为零。
    /// - Throws: 精确十进制计算失败时抛出 `ExpenseRepositoryError.balanceCalculationFailed`。
    static func netEffects(
        of transactions: [AccountTransaction],
        accountTypes: [UUID: AccountType]
    ) throws -> [UUID: Decimal] {
        var effects = accountTypes.mapValues { _ in Decimal.zero }
        for transaction in transactions {
            for change in try balanceChanges(of: transaction, accountTypes: accountTypes) {
                guard let current = effects[change.accountID] else { continue }
                effects[change.accountID] = try adding(change.amount, to: current)
            }
        }
        return effects
    }

    /// 单笔流水对各账户余额的带符号影响；累计影响和账户余额走势都按它计算。
    ///
    /// 字段组合损坏的流水返回空；账户类型未知时无法判断方向，该账户不出现在结果里。
    /// 转账依次给出转出账户（按支出）和转入账户（按收入）两条。
    ///
    /// - Parameters:
    ///   - transaction: 一笔流水。
    ///   - accountTypes: 账户 UUID 到已知账户类型的映射。
    /// - Returns: 受影响的账户和余额变化，余额变化与 `Account.balance` 同号：资产类为余额增减，负债类为欠款增减。
    /// - Throws: 精确十进制计算失败时抛出 `ExpenseRepositoryError.balanceCalculationFailed`。
    static func balanceChanges(
        of transaction: AccountTransaction,
        accountTypes: [UUID: AccountType]
    ) throws -> [(accountID: UUID, amount: Decimal)] {
        guard let payload = try? transaction.validatedPayload() else { return [] }

        func change(
            _ amount: Decimal,
            entryType: BookkeepingEntryType,
            to accountID: UUID
        ) throws -> [(accountID: UUID, amount: Decimal)] {
            guard let type = accountTypes[accountID] else { return [] }
            let signedAmount = try LocalExpenseRepository.updatedBalance(
                .zero,
                by: amount,
                effect: type.expenseBalanceEffect,
                entryType: entryType
            )
            return [(accountID: accountID, amount: signedAmount)]
        }

        switch payload {
        case let .expense(_, amount):
            return try change(amount, entryType: .expense, to: transaction.accountID)
        case let .income(_, amount):
            return try change(amount, entryType: .income, to: transaction.accountID)
        case let .transfer(toAccountID, amount):
            return try change(amount, entryType: .expense, to: transaction.accountID)
                + change(amount, entryType: .income, to: toAccountID)
        case let .balanceAdjustment(_, _, delta):
            guard accountTypes[transaction.accountID] != nil else { return [] }
            return [(accountID: transaction.accountID, amount: delta)]
        }
    }

    /// 在调用方的 context 中把账户余额重算为期初余额加流水影响；不保存。
    ///
    /// 只改动余额确实变化的账户。余额不属于同步内容，所以这一步不会被同步台账记成修改。
    ///
    /// - Parameters:
    ///   - accountIDs: 需要重算的账户；为 `nil` 时重算全部账户。
    ///   - context: 调用方的 manual-save context。
    /// - Returns: 余额发生变化的账户数量。
    /// - Throws: 读取失败或精确十进制计算失败时抛出错误。
    @discardableResult
    static func rebuild(accountIDs: Set<UUID>? = nil, in context: ModelContext) throws -> Int {
        let accounts = try context.fetch(FetchDescriptor<Account>())
            .filter { accountIDs?.contains($0.id) ?? true }
        guard !accounts.isEmpty else { return 0 }

        var accountTypes: [UUID: AccountType] = [:]
        for account in accounts {
            if let type = account.accountType { accountTypes[account.id] = type }
        }
        let effects = try netEffects(
            of: context.fetch(FetchDescriptor<AccountTransaction>()),
            accountTypes: accountTypes
        )

        var changedCount = 0
        for account in accounts {
            guard let effect = effects[account.id] else { continue }
            let balance = try balance(openingBalance: account.openingBalance, effect: effect)
            if account.balance != balance {
                account.balance = balance
                changedCount += 1
            }
        }
        return changedCount
    }

    /// 由期初余额和流水累计影响得出余额。
    ///
    /// - Parameters:
    ///   - openingBalance: 账户期初余额。
    ///   - effect: 该账户全部流水的累计影响。
    /// - Returns: `openingBalance + effect`。
    /// - Throws: 溢出或精度损失时抛出 `ExpenseRepositoryError.balanceCalculationFailed`。
    static func balance(openingBalance: Decimal, effect: Decimal) throws -> Decimal {
        try adding(effect, to: openingBalance)
    }

    /// 由当前余额倒推期初余额，供缺少期初余额的旧备份使用。
    ///
    /// - Parameters:
    ///   - balance: 记录里的当前余额。
    ///   - effect: 该账户全部流水的累计影响。
    /// - Returns: `balance - effect`。
    /// - Throws: 精确十进制计算失败时抛出 `ExpenseRepositoryError.balanceCalculationFailed`。
    static func openingBalance(fromBalance balance: Decimal, effect: Decimal) throws -> Decimal {
        try adding(-effect, to: balance)
    }

    /// 使用精确十进制加法，拒绝溢出和精度损失。
    private static func adding(_ change: Decimal, to value: Decimal) throws -> Decimal {
        guard let result = value.exactlyAdding(change) else {
            throw ExpenseRepositoryError.balanceCalculationFailed
        }
        return result
    }
}

extension Decimal {
    /// 精确相加；溢出或无法精确表示时返回 nil。
    ///
    /// 不能只看 `NSDecimalAdd` 的返回值：尾数溢出需要舍入时它可能仍返回 `.noError`
    /// （iOS 27 实测最大尾数加 30 被舍入成 …480 却不报错），所以加完再减回去核对。
    ///
    /// - Parameter other: 加数。
    /// - Returns: 精确的和；不精确时为 nil。
    nonisolated func exactlyAdding(_ other: Decimal) -> Decimal? {
        var lhs = self
        var rhs = other
        var sum = Decimal()
        guard NSDecimalAdd(&sum, &lhs, &rhs, .plain) == .noError else { return nil }
        var roundTrip = Decimal()
        var sumCopy = sum
        guard NSDecimalSubtract(&roundTrip, &sumCopy, &rhs, .plain) == .noError, roundTrip == self else {
            return nil
        }
        return sum
    }
}
