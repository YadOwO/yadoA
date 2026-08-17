import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import yadoA

@Suite("账户列表展示", .serialized)
@MainActor
struct AccountListPresentationTests {
    @Test("空与非空状态始终只提供一个主要添加入口")
    func addActionStateHasExactlyOneEntryPoint() {
        #expect(AccountListState.showsInlineAdd(accountCount: 0))
        #expect(!AccountListState.showsToolbarAdd(accountCount: 0))
        #expect(!AccountListState.showsInlineAdd(accountCount: 2))
        #expect(AccountListState.showsToolbarAdd(accountCount: 2))
    }

    @Test("显式语言环境可解析列表文案且未知键安全回退")
    func listLocalizationHonorsLocaleAndFallsBackForUnknownKey() {
        #expect(
            AccountLocalization.string(
                "account.list.title",
                locale: Locale(identifier: "en")
            ) == "Accounts"
        )
        #expect(
            AccountLocalization.string(
                "account.list.title",
                locale: Locale(identifier: "zh-Hans")
            ) == "账户"
        )
        #expect(
            AccountLocalization.string(
                "account.list.missing-key",
                locale: Locale(identifier: "en")
            ) == "account.list.missing-key"
        )
        #expect(
            AccountLocalization.string(
                "account.summary.net_assets",
                locale: Locale(identifier: "zh-Hans")
            ) == "净资产"
        )
    }

    @Test("账户列表汇总资产、负债并突出计算净资产")
    func summaryAggregatesAssetsLiabilitiesAndNetAssets() {
        let summary = AccountSummaryPresentation.summary(
            for: [
                makeAccount(typeRawValue: AccountType.cash.rawValue, balance: 100),
                makeAccount(typeRawValue: AccountType.investment.rawValue, balance: 50),
                makeAccount(typeRawValue: AccountType.creditCard.rawValue, balance: 30),
                makeAccount(typeRawValue: AccountType.liability.rawValue, balance: 20)
            ],
            locale: Locale(identifier: "en_US")
        )

        #expect(summary.assets == 150)
        #expect(summary.liabilities == 50)
        #expect(summary.netAssets == 100)
        #expect(summary.formattedNetAssets.contains("100"))
        #expect(summary.formattedAssets.contains("150"))
        #expect(summary.formattedLiabilities.contains("50"))
        #expect(summary.accessibilityLabel.contains("Net assets"))
        #expect(summary.accessibilityLabel.contains("Liabilities"))
    }

    @Test("未知账户类型的余额不会从资产汇总中丢失")
    func unknownAccountTypeFallsBackToAssets() {
        let summary = AccountSummaryPresentation.summary(
            for: [makeAccount(typeRawValue: "futureType", balance: 40)],
            locale: Locale(identifier: "en_US")
        )

        #expect(summary.assets == 40)
        #expect(summary.liabilities == 0)
        #expect(summary.netAssets == 40)
    }

    @Test("账户按最新时间和 UUID 并列键稳定排序")
    func deterministicNewestFirstSorting() {
        let sameDate = Date(timeIntervalSince1970: 100)
        let newer = makeAccount(
            id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
            updatedAt: sameDate.addingTimeInterval(1)
        )
        let equalTimeFirst = makeAccount(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            updatedAt: sameDate
        )
        let equalTimeSecond = makeAccount(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            updatedAt: sameDate
        )

        let result = AccountListPresentation.sorted([equalTimeSecond, newer, equalTimeFirst])

        #expect(result.map(\.id) == [newer.id, equalTimeFirst.id, equalTimeSecond.id])
    }

    @Test("已知模板本地化并显示品牌图标和掩码后缀")
    func knownTemplateUsesLocalizedBrandPresentation() {
        let account = makeAccount(
            typeRawValue: AccountType.debitCard.rawValue,
            templateID: "debitCard.ccb",
            name: "创建时的建设银行",
            lastFourDigits: "1234"
        )

        let english = AccountListPresentation.row(
            for: account,
            locale: Locale(identifier: "en")
        )
        let chinese = AccountListPresentation.row(
            for: account,
            locale: Locale(identifier: "zh-Hans")
        )

        #expect(english.name == "China Construction Bank")
        #expect(chinese.name == "建设银行")
        #expect(english.icon.brandImageName == "BrandCCB")
        #expect(english.detail.contains("1234"))
        #expect(english.detail.contains("••••"))
    }

    @Test("模板缺失或未知时保留名称并使用类型图标")
    func missingTemplateFallsBackToPersistedNameAndTypeIcon() {
        let account = makeAccount(
            typeRawValue: AccountType.virtualAccount.rawValue,
            templateID: "virtualAccount.removed",
            name: "  已清理的旧账户  "
        )
        account.name = "已清理的旧账户"

        let presentation = AccountListPresentation.row(for: account)

        #expect(presentation.name == "已清理的旧账户")
        #expect(presentation.icon.brandImageName == nil)
        #expect(presentation.icon.symbolName == AccountType.virtualAccount.symbolName)
    }

    @Test("负债保持正数并明确展示与播报债务语义")
    func positiveLiabilityUsesDebtSemantics() {
        let account = makeAccount(
            typeRawValue: AccountType.liability.rawValue,
            name: "房贷",
            balance: 2800
        )

        let presentation = AccountListPresentation.row(
            for: account,
            locale: Locale(identifier: "en_US")
        )

        #expect(account.balance == 2800)
        #expect(presentation.amountLabel == "Debt")
        #expect(presentation.amountAccessibilityLabel.contains("Debt"))
        #expect(presentation.formattedAmount.contains("2,800"))
        #expect(!presentation.formattedAmount.contains("-"))
    }

    @Test("未知持久类型安全降级且金额标签可访问")
    func unknownTypeHasSafeFallback() {
        let account = makeAccount(typeRawValue: "futureType", name: "未来账户")

        let presentation = AccountListPresentation.row(
            for: account,
            locale: Locale(identifier: "en_US")
        )

        #expect(presentation.name == "未来账户")
        #expect(presentation.detail == "Unknown Account")
        #expect(presentation.icon.symbolName == "questionmark.circle.fill")
        #expect(presentation.amountAccessibilityLabel.contains("Amount"))
        #expect(presentation.amountAccessibilityLabel.contains("40"))
    }

    @Test("真实容器中仓库保存可被查询并立即转换为列表行")
    func repositorySaveFeedsRealQueryAndPresentation() throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let queryContext = ModelContext(dataContainer.modelContainer)
        let repository = LocalAccountRepository(container: dataContainer.modelContainer)
        let draft = AccountDraft(
            id: UUID(),
            accountType: .cash,
            name: "现金",
            amountText: "40"
        )

        #expect(try queryContext.fetch(FetchDescriptor<Account>()).isEmpty)
        try repository.save(draft, locale: Locale(identifier: "en_US"))

        let queriedAccounts = try queryContext.fetch(FetchDescriptor<Account>())
        let rows = AccountListPresentation.sorted(queriedAccounts).map {
            AccountListPresentation.row(for: $0, locale: Locale(identifier: "en_US"))
        }

        #expect(rows.map(\.id) == [draft.id])
        #expect(rows.first?.name == "现金")
        #expect(rows.first?.formattedAmount.contains("40") == true)
    }

    @Test("记账不更新时间戳或改变账户相对顺序")
    func expenseSaveDoesNotReorderAccounts() throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let accountRepository = LocalAccountRepository(container: dataContainer.modelContainer)
        let firstID = UUID()
        let secondID = UUID()
        let firstUpdatedAt = Date(timeIntervalSince1970: 200)
        let secondUpdatedAt = Date(timeIntervalSince1970: 100)
        try accountRepository.save(
            AccountDraft(
                id: firstID,
                accountType: .cash,
                name: "账户 A",
                amountText: "100"
            ),
            locale: Locale(identifier: "en_US"),
            now: firstUpdatedAt
        )
        try accountRepository.save(
            AccountDraft(
                id: secondID,
                accountType: .cash,
                name: "账户 B",
                amountText: "100"
            ),
            locale: Locale(identifier: "en_US"),
            now: secondUpdatedAt
        )
        let expenseRepository = LocalExpenseRepository(container: dataContainer.modelContainer)

        try expenseRepository.save(
            DiningExpenseDraft(
                accountID: secondID,
                amountText: "10",
                transactionDay: 20260813
            )
        )

        let queryContext = ModelContext(dataContainer.modelContainer)
        let accounts = try queryContext.fetch(FetchDescriptor<Account>())
        let sortedAccounts = AccountListPresentation.sorted(accounts)
        let first = try #require(accounts.first { $0.id == firstID })
        let second = try #require(accounts.first { $0.id == secondID })
        #expect(sortedAccounts.map(\.id) == [firstID, secondID])
        #expect(first.updatedAt == firstUpdatedAt)
        #expect(second.updatedAt == secondUpdatedAt)
        #expect(second.balance == Decimal(90))
    }

    @Test("余额调整不更新时间戳或改变账户相对顺序")
    func balanceAdjustmentDoesNotReorderAccounts() throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let accountRepository = LocalAccountRepository(container: dataContainer.modelContainer)
        let firstID = UUID()
        let secondID = UUID()
        let firstUpdatedAt = Date(timeIntervalSince1970: 200)
        let secondUpdatedAt = Date(timeIntervalSince1970: 100)
        try accountRepository.save(
            AccountDraft(
                id: firstID,
                accountType: .cash,
                name: "账户 A",
                amountText: "100"
            ),
            locale: Locale(identifier: "en_US"),
            now: firstUpdatedAt
        )
        try accountRepository.save(
            AccountDraft(
                id: secondID,
                accountType: .cash,
                name: "账户 B",
                amountText: "100"
            ),
            locale: Locale(identifier: "en_US"),
            now: secondUpdatedAt
        )

        _ = try LocalBalanceAdjustmentRepository(
            container: dataContainer.modelContainer
        ).save(
            BalanceAdjustmentDraft(accountID: secondID, amountText: "120")
        )

        let accounts = try ModelContext(dataContainer.modelContainer).fetch(
            FetchDescriptor<Account>()
        )
        let sortedAccounts = AccountListPresentation.sorted(accounts)
        let first = try #require(accounts.first { $0.id == firstID })
        let second = try #require(accounts.first { $0.id == secondID })
        #expect(sortedAccounts.map(\.id) == [firstID, secondID])
        #expect(first.updatedAt == firstUpdatedAt)
        #expect(second.updatedAt == secondUpdatedAt)
        #expect(second.balance == Decimal(120))
    }

    /// 构造已持久化形态的账户，用于隔离展示层边界。
    private func makeAccount(
        id: UUID = UUID(),
        typeRawValue: String = AccountType.cash.rawValue,
        templateID: String? = nil,
        name: String = "现金",
        lastFourDigits: String? = nil,
        balance: Decimal = 40,
        updatedAt: Date = Date(timeIntervalSince1970: 100)
    ) -> Account {
        Account(
            id: id,
            typeRawValue: typeRawValue,
            templateID: templateID,
            name: name,
            note: nil,
            lastFourDigits: lastFourDigits,
            balance: balance,
            currencyCode: "CNY",
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
    }
}
