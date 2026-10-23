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

        func apply(_ amount: Decimal, entryType: BookkeepingEntryType, to accountID: UUID) throws {
            guard let type = accountTypes[accountID], let current = effects[accountID] else { return }
            effects[accountID] = try LocalExpenseRepository.updatedBalance(
                current,
                by: amount,
                effect: type.expenseBalanceEffect,
                entryType: entryType
            )
        }

        for transaction in transactions {
            guard let payload = try? transaction.validatedPayload() else { continue }
            switch payload {
            case let .expense(_, amount):
                try apply(amount, entryType: .expense, to: transaction.accountID)
            case let .income(_, amount):
                try apply(amount, entryType: .income, to: transaction.accountID)
            case let .transfer(toAccountID, amount):
                try apply(amount, entryType: .expense, to: transaction.accountID)
                try apply(amount, entryType: .income, to: toAccountID)
            case let .balanceAdjustment(_, _, delta):
                guard let current = effects[transaction.accountID] else { continue }
                effects[transaction.accountID] = try adding(delta, to: current)
            }
        }
        return effects
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
        var lhs = value
        var rhs = change
        var result = Decimal()
        guard NSDecimalAdd(&result, &lhs, &rhs, .plain) == .noError else {
            throw ExpenseRepositoryError.balanceCalculationFailed
        }
        return result
    }
}
