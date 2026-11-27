import Foundation
import SwiftData
import Testing
@testable import yadoA

@Suite("更换账本币种", .serialized)
@MainActor
struct LedgerCurrencyChangeTests {
    private struct InjectedFailure: Error {}

    /// 建好两个 CNY 账户、一笔支出、一笔收入和一笔转账的账本。
    private func makeLedger() throws -> (container: ModelContainer, cashID: UUID, walletID: UUID) {
        let container = try AccountDataContainer.inMemory().modelContainer
        let accounts = LocalAccountRepository(container: container, defaults: LedgerTestDefaults.cny)
        let cashID = UUID()
        let walletID = UUID()
        try accounts.save(
            AccountDraft(id: cashID, accountType: .cash, name: "现金", amountText: "100"),
            locale: Locale(identifier: "en_US"),
            now: Date(timeIntervalSince1970: 1_000)
        )
        try accounts.save(
            AccountDraft(id: walletID, accountType: .cash, name: "钱包", amountText: "50"),
            locale: Locale(identifier: "en_US"),
            now: Date(timeIntervalSince1970: 2_000)
        )
        let expenses = LocalExpenseRepository(container: container)
        try expenses.save(DiningExpenseDraft(
            accountID: cashID, entryType: .expense, amountText: "12.5", transactionDay: 20260901
        ))
        try expenses.save(DiningExpenseDraft(
            accountID: cashID, entryType: .income, amountText: "30", transactionDay: 20260902
        ))
        try LocalTransferRepository(container: container).save(
            TransferDraft(fromAccountID: cashID, toAccountID: walletID, amountText: "20", transactionDay: 20260903)
        )
        return (container, cashID, walletID)
    }

    @Test("改成 USD 后所有账户和流水都是 USD，金额不变，本机存的值也是 USD")
    func changeRewritesEveryRecord() throws {
        let ledger = try makeLedger()
        let defaults = LedgerTestDefaults.make(currency: "CNY", name: "changeAll")
        let before = try snapshot(of: ledger.container)
        #expect(before.accounts.count == 2)
        #expect(before.transactions.count == 3)
        #expect(Set(before.accounts.map(\.currencyCode)) == ["CNY"])
        #expect(Set(before.transactions.map(\.currencyCode)) == ["CNY"])
        let now = Date(timeIntervalSince1970: 9_000)

        try LocalLedgerCurrencyRepository(container: ledger.container, defaults: defaults)
            .change(to: "USD", now: now)

        let after = try snapshot(of: ledger.container)
        #expect(Set(after.accounts.map(\.currencyCode)) == ["USD"])
        #expect(Set(after.transactions.map(\.currencyCode)) == ["USD"])
        // 只换符号，不换算：余额和流水金额一分不差
        #expect(after.accounts.map(\.balance) == before.accounts.map(\.balance))
        #expect(after.transactions.map(\.amount) == before.transactions.map(\.amount))
        #expect(after.accounts.allSatisfy { $0.updatedAt == now })
        #expect(defaults.string(forKey: BookkeepingCurrency.storageKey) == "USD")
        let context = ledger.container.makeManualSaveContext()
        #expect(try BookkeepingCurrency.current(in: context, defaults: defaults) == "USD")
    }

    @Test("换币种后可以继续用新币种记账")
    func entriesAfterChangeUseNewCurrency() throws {
        let ledger = try makeLedger()
        let defaults = LedgerTestDefaults.make(currency: "CNY", name: "changeThenRecord")
        try LocalLedgerCurrencyRepository(container: ledger.container, defaults: defaults).change(to: "EUR")

        let draft = DiningExpenseDraft(accountID: ledger.walletID, amountText: "5", transactionDay: 20260910)
        try LocalExpenseRepository(container: ledger.container).save(draft)

        let saved = try #require(try ledger.container.makeManualSaveContext().transaction(id: draft.id))
        #expect(saved.currencyCode == "EUR")
    }

    @Test("币种不在可选范围内时抛错，数据和本机存的值都不变")
    func invalidCodeThrowsAndChangesNothing() throws {
        let ledger = try makeLedger()
        let defaults = LedgerTestDefaults.make(currency: "CNY", name: "changeInvalid")
        let before = try snapshot(of: ledger.container)
        let repository = LocalLedgerCurrencyRepository(container: ledger.container, defaults: defaults)

        for code in ["usd", "US", "ZZZ", ""] {
            #expect(throws: LedgerCurrencyRepositoryError.invalidCurrency(code)) {
                try repository.change(to: code)
            }
        }

        let after = try snapshot(of: ledger.container)
        #expect(after.accounts == before.accounts)
        #expect(after.transactions == before.transactions)
        #expect(defaults.string(forKey: BookkeepingCurrency.storageKey) == "CNY")
    }

    @Test("保存失败时整体回滚，抛出错误，本机存的值不写")
    func failedSaveRollsBackAndKeepsStoredValue() throws {
        let ledger = try makeLedger()
        let defaults = LedgerTestDefaults.make(currency: "CNY", name: "changeFailed")
        let before = try snapshot(of: ledger.container)
        let repository = LocalLedgerCurrencyRepository(
            container: ledger.container,
            defaults: defaults,
            beforeSave: { throw InjectedFailure() }
        )

        #expect(throws: InjectedFailure.self) {
            try repository.change(to: "USD")
        }

        let after = try snapshot(of: ledger.container)
        #expect(after.accounts == before.accounts)
        #expect(after.transactions == before.transactions)
        #expect(defaults.string(forKey: BookkeepingCurrency.storageKey) == "CNY")
    }

    /// 取出账户和流水的值快照，按 UUID 排序，便于前后对比。
    private func snapshot(of container: ModelContainer) throws -> (accounts: [AccountSnapshot], transactions: [TransactionValues]) {
        let context = container.makeManualSaveContext()
        let accounts = try context.fetch(FetchDescriptor<Account>())
            .map(AccountSnapshot.init(account:))
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let transactions = try context.fetch(FetchDescriptor<AccountTransaction>())
            .map(TransactionValues.init(transaction:))
            .sorted { $0.id.uuidString < $1.id.uuidString }
        return (accounts, transactions)
    }

    /// 流水的可比较值。
    private struct TransactionValues: Equatable {
        let id: UUID
        let accountID: UUID
        let amount: Decimal?
        let currencyCode: String

        init(transaction: AccountTransaction) {
            id = transaction.id
            accountID = transaction.accountID
            amount = transaction.amount
            currencyCode = transaction.currencyCode
        }
    }
}
