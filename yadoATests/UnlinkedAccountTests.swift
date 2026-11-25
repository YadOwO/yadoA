import Foundation
import SwiftData
import Testing
@testable import yadoA

/// 「不关联账户」：收支记到它上面只计入收支统计，不改变任何余额，也不出现在资产相关的地方。
@Suite("不关联账户", .serialized)
@MainActor
struct UnlinkedAccountTests {
    @Test("记到不关联账户时自动建好它，余额始终为 0，其他账户不受影响")
    func expenseOnUnlinkedAccountKeepsBalancesUnchanged() throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let container = dataContainer.modelContainer
        let cashID = try saveCash(amountText: "100", in: container)
        let repository = LocalExpenseRepository(container: container)
        let draft = DiningExpenseDraft(
            accountID: Account.unlinkedID,
            expenseCategoryKey: ExpenseCategory.dining.rawValue,
            amountText: "30",
            transactionDay: 20261124
        )

        try repository.save(draft)

        let unlinked = try #require(try account(id: Account.unlinkedID, in: container))
        #expect(unlinked.isUnlinked)
        #expect(unlinked.isActive)
        #expect(unlinked.balance == 0)
        #expect(unlinked.typeRawValue == Account.unlinkedTypeRawValue)
        #expect(try account(id: cashID, in: container)?.balance == 100)
        let saved = try #require(try container.makeManualSaveContext().transaction(id: draft.id))
        #expect(saved.accountID == Account.unlinkedID)
        #expect(try saved.validatedPayload() == .expense(categoryKey: ExpenseCategory.dining.rawValue, amount: 30))
    }

    @Test("收支在现金和不关联账户之间改来改去时，只有现金余额随之变化")
    func movingEntryBetweenCashAndUnlinkedAdjustsOnlyCash() throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let container = dataContainer.modelContainer
        let cashID = try saveCash(amountText: "100", in: container)
        let repository = LocalExpenseRepository(container: container)
        let entryID = UUID()
        var snapshot = BookkeepingEntrySnapshot(
            id: entryID,
            accountID: cashID,
            entryType: .expense,
            categoryKey: ExpenseCategory.dining.rawValue,
            amount: 20,
            transactionDay: 20261124,
            savedAt: Date(timeIntervalSince1970: 100)
        )
        try repository.apply([.insert(snapshot)])
        #expect(try account(id: cashID, in: container)?.balance == 80)

        // 改成不关联账户：现金余额恢复，不关联账户仍为 0
        snapshot.accountID = Account.unlinkedID
        try repository.apply([.replace(snapshot)])
        #expect(try account(id: cashID, in: container)?.balance == 100)
        #expect(try account(id: Account.unlinkedID, in: container)?.balance == 0)

        // 在不关联账户上改金额、改成收入，余额都不动
        snapshot.amount = 50
        snapshot.entryType = .income
        snapshot.categoryKey = IncomeCategory.salary.rawValue
        try repository.apply([.replace(snapshot)])
        #expect(try account(id: Account.unlinkedID, in: container)?.balance == 0)

        // 改回现金：按收入加到现金上
        snapshot.accountID = cashID
        try repository.apply([.replace(snapshot)])
        #expect(try account(id: cashID, in: container)?.balance == 150)

        // 再改回不关联账户后删除，现金回到最初的 100
        snapshot.accountID = Account.unlinkedID
        try repository.apply([.replace(snapshot)])
        try repository.delete(id: entryID)
        #expect(try account(id: cashID, in: container)?.balance == 100)
        #expect(try account(id: Account.unlinkedID, in: container)?.balance == 0)
    }

    @Test("余额重算后不关联账户仍为 0")
    func rebuildKeepsUnlinkedAtZero() throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let container = dataContainer.modelContainer
        let repository = LocalExpenseRepository(container: container)
        try repository.save(DiningExpenseDraft(
            accountID: Account.unlinkedID,
            expenseCategoryKey: ExpenseCategory.dining.rawValue,
            amountText: "12",
            transactionDay: 20261124
        ))

        let context = container.makeManualSaveContext()
        try AccountBalanceRebuilder.rebuild(in: context)
        #expect(try context.account(id: Account.unlinkedID)?.balance == 0)
    }

    @Test("选择框点不关联账户时只建一次")
    func ensureUnlinkedAccountIsIdempotent() throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let repository = LocalAccountRepository(container: dataContainer.modelContainer)

        #expect(try repository.ensureUnlinkedAccount(locale: Locale(identifier: "zh-Hans")) == Account.unlinkedID)
        #expect(try repository.ensureUnlinkedAccount() == Account.unlinkedID)

        let all = try dataContainer.modelContainer.makeManualSaveContext().fetch(FetchDescriptor<Account>())
        #expect(all.map(\.id) == [Account.unlinkedID])
        #expect(all.first?.name == AccountLocalization.string("account.unlinked.name", locale: Locale(identifier: "zh-Hans")))
    }

    @Test("只有不关联账户时仍自动建现金账户，且不关联账户不能当默认")
    func starterCashIgnoresUnlinkedAccount() throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let repository = LocalAccountRepository(container: dataContainer.modelContainer)
        try repository.ensureUnlinkedAccount()

        let starterID = try #require(try repository.createStarterAccountIfNeeded())
        #expect(try repository.defaultResolution() == .valid(starterID))
        #expect(try repository.defaultCandidates().map(\.id) == [starterID])
        #expect(throws: AccountRepositoryError.invalidDefaultCandidate(Account.unlinkedID)) {
            try repository.setDefaultAccount(id: Account.unlinkedID)
        }
    }

    @Test("不关联账户不能改名、停用或删除")
    func unlinkedAccountRejectsAccountOperations() throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let repository = LocalAccountRepository(container: dataContainer.modelContainer)
        try repository.ensureUnlinkedAccount()
        let unlinked = try #require(try repository.account(id: Account.unlinkedID))

        var draft = AccountEditDraft(account: unlinked)
        draft.name = "改个名"
        #expect(throws: AccountRepositoryError.accountNotFound(Account.unlinkedID)) {
            try repository.update(draft)
        }
        #expect(throws: AccountRepositoryError.accountNotFound(Account.unlinkedID)) {
            try repository.disposalPlan(for: Account.unlinkedID)
        }
        #expect(try repository.account(id: Account.unlinkedID)?.isActive == true)
    }

    @Test("账户列表、净资产和资产分析都不包含不关联账户")
    func presentationsExcludeUnlinkedAccount() throws {
        let now = Date(timeIntervalSince1970: 100)
        let cash = Account(
            id: UUID(),
            typeRawValue: AccountType.cash.rawValue,
            templateID: nil,
            name: "现金",
            note: nil,
            lastFourDigits: nil,
            balance: 100,
            currencyCode: BookkeepingCurrency.code,
            createdAt: now,
            updatedAt: now
        )
        let unlinked = Account.makeUnlinked(locale: Locale(identifier: "zh-Hans"), now: now)
        // 即使数据异常、不关联账户有余额，也不能算进资产
        unlinked.balance = 999
        let accounts = [cash, unlinked]

        #expect(AccountListPresentation.sorted(accounts, order: .default).map(\.id) == [cash.id])
        #expect(AccountSummaryPresentation.summary(for: accounts).netAssets == 100)
        #expect(AssetAnalysisPresentation(accounts: accounts).assets == 100)
        #expect(TransferView.transferableAccounts(accounts, order: .default).map(\.id) == [cash.id])
        #expect(unlinked.acceptsBookkeepingEntries)
        #expect(!unlinked.isEligibleForDefault)
        #expect(!unlinked.supportsBookkeeping)
    }

    @Test("不关联账户的行显示本地化名称和说明，不显示金额")
    func unlinkedRowPresentation() {
        let locale = Locale(identifier: "zh-Hans")
        let row = AccountListPresentation.row(
            for: Account.makeUnlinked(locale: Locale(identifier: "en_US")),
            locale: locale
        )
        #expect(row.id == Account.unlinkedID)
        #expect(row.name == AccountLocalization.string("account.unlinked.name", locale: locale))
        #expect(row.detail == AccountLocalization.string("account.unlinked.hint", locale: locale))
        #expect(row.formattedAmount.isEmpty)
        #expect(!row.isDefault)
    }

    @Test("语音上下文始终带上不关联账户，放在启用账户之后")
    func voiceContextIncludesUnlinkedOption() throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let container = dataContainer.modelContainer
        let cashID = try saveCash(amountText: "10", in: container)

        let context = VoiceSessionContext.make(container: container, locale: Locale(identifier: "zh-Hans"))
        #expect(context.accounts.map(\.id) == [cashID.uuidString, Account.unlinkedID.uuidString])
        let option = try #require(context.accounts.last)
        #expect(option.isActive)
        #expect(option.type == Account.unlinkedTypeRawValue)
    }

    @Test("启用账户已满上限时，语音上下文仍保留不关联账户")
    func voiceContextKeepsUnlinkedOptionWhenActiveAccountsFillLimit() throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let container = dataContainer.modelContainer
        for _ in 0..<VoiceSessionLimits.maxAccounts {
            _ = try saveCash(amountText: "10", in: container)
        }

        let context = VoiceSessionContext.make(container: container, locale: Locale(identifier: "zh-Hans"))
        #expect(context.accounts.count == VoiceSessionLimits.maxAccounts)
        #expect(context.accounts.map(\.id).contains(Account.unlinkedID.uuidString))
    }

    @Test("不关联账户的展示名称按当前语言取词，普通账户原样返回名称")
    func localizedNameFollowsCurrentLocale() {
        let chinese = Locale(identifier: "zh-Hans")
        let unlinked = Account.makeUnlinked(locale: Locale(identifier: "en_US"))
        #expect(
            unlinked.localizedName(locale: chinese)
                == AccountLocalization.string("account.unlinked.name", locale: chinese)
        )

        let cash = Account(
            id: UUID(),
            typeRawValue: AccountType.cash.rawValue,
            templateID: nil,
            name: "我的钱包",
            note: nil,
            lastFourDigits: nil,
            balance: 10,
            currencyCode: BookkeepingCurrency.code,
            createdAt: .now,
            updatedAt: .now,
            deactivatedAt: nil
        )
        #expect(cash.localizedName(locale: chinese) == "我的钱包")
    }

    // MARK: - 辅助

    /// 保存一个现金账户并返回它的 UUID。
    private func saveCash(amountText: String, in container: ModelContainer) throws -> UUID {
        let draft = AccountDraft(accountType: .cash, name: "现金", amountText: amountText)
        try LocalAccountRepository(container: container).save(draft, locale: Locale(identifier: "en_US"))
        return draft.id
    }

    /// 用新鲜 context 读取账户，避免读到写入仓库之外的缓存。
    private func account(id: UUID, in container: ModelContainer) throws -> Account? {
        try container.makeManualSaveContext().account(id: id)
    }
}
