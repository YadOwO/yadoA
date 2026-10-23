import Foundation
import SwiftData
import Testing
@testable import yadoA

@Suite("账户余额由期初余额和流水推导", .serialized)
@MainActor
struct AccountBalanceRebuilderTests {
    @Test("各类写入后，余额缓存与按流水重算的结果一致")
    func incrementalBalancesMatchRebuild() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let cashID = UUID()
        let creditID = UUID()
        try saveAccount(id: cashID, accountType: .cash, amountText: "1000", in: container)
        try saveAccount(id: creditID, accountType: .creditCard, amountText: "200", in: container)

        let expenses = LocalExpenseRepository(container: container)
        let lunch = DiningExpenseDraft(accountID: cashID, amountText: "35.5", transactionDay: 20261020)
        try expenses.save(lunch)
        try expenses.save(
            DiningExpenseDraft(
                accountID: cashID,
                entryType: .income,
                incomeCategoryKey: IncomeCategory.salary.rawValue,
                amountText: "500",
                transactionDay: 20261021
            )
        )
        try expenses.save(DiningExpenseDraft(accountID: creditID, amountText: "80", transactionDay: 20261021))
        try LocalTransferRepository(container: container).save(
            TransferDraft(fromAccountID: cashID, toAccountID: creditID, amountText: "150", transactionDay: 20261022)
        )
        _ = try LocalBalanceAdjustmentRepository(container: container).save(
            BalanceAdjustmentDraft(accountID: cashID, amountText: "1200")
        )
        try expenses.update(
            DiningExpenseEditDraft(
                id: lunch.id, accountID: creditID, expenseCategoryKey: ExpenseCategory.dining.rawValue,
                title: "午饭", amountText: "40", transactionDay: 20261020
            )
        )
        try expenses.save(DiningExpenseDraft(accountID: cashID, amountText: "12", transactionDay: 20261001))

        let context = container.makeManualSaveContext()
        let before = try balances(in: context)
        let changed = try AccountBalanceRebuilder.rebuild(in: context)

        #expect(changed == 0)
        #expect(try balances(in: context) == before)
        // 现金：调整到 1200 后，午饭改到信用卡退回 35.5，又记了一笔更早日期的 12 元支出，余额按差额累加。
        #expect(before[cashID] == Decimal(string: "1223.5"))
        // 信用卡：期初欠款 200 + 80 + 40（午饭改到信用卡）- 150 还款。
        #expect(before[creditID] == 170)
    }

    @Test("余额缓存被改乱后，重算恢复为期初余额加流水")
    func rebuildRestoresCorruptedBalance() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let cashID = UUID()
        try saveAccount(id: cashID, accountType: .cash, amountText: "100", in: container)
        try LocalExpenseRepository(container: container).save(
            DiningExpenseDraft(accountID: cashID, amountText: "30", transactionDay: 20261020)
        )

        let context = container.makeManualSaveContext()
        let account = try #require(try context.account(id: cashID))
        #expect(account.openingBalance == 100)
        account.balance = 9999

        let changed = try AccountBalanceRebuilder.rebuild(accountIDs: [cashID], in: context)

        #expect(changed == 1)
        #expect(account.balance == 70)
    }

    @Test("导入时按期初余额重算余额，不采用文件里的余额缓存")
    func importRecomputesBalanceFromOpeningBalance() throws {
        let accountID = UUID()
        let backup = makeBackup(accountID: accountID, balance: "999", openingBalance: "100")

        let records = try BackupImportService.validatedRecords(from: backup)

        let account = try #require(records.accounts.first)
        #expect(account.openingBalance == 100)
        #expect(account.balance == 70)
    }

    @Test("旧备份缺少期初余额时，由余额减去流水影响倒推")
    func importDerivesMissingOpeningBalance() throws {
        let accountID = UUID()
        let backup = makeBackup(accountID: accountID, balance: "70", openingBalance: nil)

        let records = try BackupImportService.validatedRecords(from: backup)

        let account = try #require(records.accounts.first)
        #expect(account.openingBalance == 100)
        #expect(account.balance == 70)
    }

    @Test("余额计算溢出或损失精度时报错，不产生近似值")
    func balanceRejectsOverflowAndPrecisionLoss() throws {
        let maxMantissa = try #require(Decimal(string: "340282366920938463463374607431768211455"))

        #expect(throws: ExpenseRepositoryError.balanceCalculationFailed) {
            try AccountBalanceRebuilder.balance(
                openingBalance: .greatestFiniteMagnitude,
                effect: .greatestFiniteMagnitude
            )
        }
        #expect(throws: ExpenseRepositoryError.balanceCalculationFailed) {
            try AccountBalanceRebuilder.balance(openingBalance: maxMantissa, effect: Decimal(string: "0.5")!)
        }
    }

    @Test("导入时期初余额加流水损失精度，整份备份判为无效")
    func importRejectsImpreciseBalance() throws {
        // 期初余额已占满十进制尾数，再记一笔 30 元支出就无法精确表示。
        let backup = makeBackup(
            accountID: UUID(),
            balance: "0",
            openingBalance: "-340282366920938463463374607431768211455"
        )

        #expect(throws: BackupImportError.invalidContent) {
            try BackupImportService.validatedRecords(from: backup)
        }
    }

    // MARK: - 工具

    /// 通过账户仓库保存一个账户。
    private func saveAccount(
        id: UUID,
        accountType: AccountType,
        amountText: String,
        in container: ModelContainer
    ) throws {
        try LocalAccountRepository(container: container).save(
            AccountDraft(
                id: id,
                accountType: accountType,
                template: accountType.requiresTemplateSelection ? accountType.templates.first : nil,
                name: accountType.rawValue,
                amountText: amountText
            ),
            locale: Locale(identifier: "en_US")
        )
    }

    /// 读取全部账户余额。
    private func balances(in context: ModelContext) throws -> [UUID: Decimal] {
        Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Account>()).map { ($0.id, $0.balance) })
    }

    /// 构造一个现金账户和一笔 30 元支出的备份。
    private func makeBackup(accountID: UUID, balance: String, openingBalance: String?) -> BackupFile {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        return BackupFile(
            exportedAt: date,
            appVersion: "1.0",
            appBuild: "1",
            accounts: [
                BackupAccount(
                    id: accountID,
                    type: AccountType.cash.rawValue,
                    templateID: nil,
                    name: "现金",
                    note: nil,
                    lastFourDigits: nil,
                    balance: balance,
                    openingBalance: openingBalance,
                    currencyCode: "CNY",
                    createdAt: date,
                    updatedAt: date,
                    deactivatedAt: nil
                ),
            ],
            transactions: [
                BackupTransaction(
                    id: UUID(),
                    accountID: accountID,
                    type: AccountTransactionType.expense.rawValue,
                    category: ExpenseCategory.dining.rawValue,
                    amount: "30",
                    title: nil,
                    balanceBefore: nil,
                    balanceAfter: nil,
                    balanceDelta: nil,
                    currencyCode: "CNY",
                    transactionDay: 20261020,
                    note: nil,
                    savedAt: date
                ),
            ],
            bookkeepingPreference: nil
        )
    }
}
