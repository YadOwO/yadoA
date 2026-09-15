import Foundation
import Testing
@testable import yadoA

@Suite("记账详情投影", .serialized)
@MainActor
struct BookkeepingTransactionDetailPresentationTests {
    @Test("详情展示用户标题、方向和完整字段")
    func detailShowsCompleteBookkeepingFields() throws {
        let accountID = UUID()
        let transaction = try AccountTransaction.validatingDiningExpense(
            id: UUID(),
            accountID: accountID,
            amount: Decimal(string: "30.50")!,
            transactionDay: 20260826,
            title: "工作午餐",
            note: "和朋友吃火锅"
        )
        let account = makeAccount(id: accountID, name: "日常现金")

        let detail = try #require(
            BookkeepingSearchPresentation.detail(
                transactionID: transaction.id,
                transactions: [transaction],
                accounts: [account],
                calendar: utcCalendar,
                locale: chineseLocale
            )
        )

        #expect(detail.title == "工作午餐")
        #expect(detail.entryType == .expense)
        #expect(detail.categoryTitle == "餐饮")
        #expect(detail.formattedAmount.contains("30.50"))
        #expect(detail.transactionDay == 20260826)
        #expect(detail.accountName == "日常现金")
        #expect(detail.accountState == .active)
        #expect(detail.note == "和朋友吃火锅")
        #expect(detail.canEdit)
        #expect(detail.accessibilityLabel.contains("餐饮"))
        #expect(detail.accessibilityLabel.contains("工作午餐"))
    }

    @Test("停用和孤立账户详情都保持只读状态")
    func accountLifecycleRemovesEditing() throws {
        let inactiveID = UUID()
        let inactiveTransaction = try AccountTransaction.validatingDiningExpense(
            id: UUID(),
            accountID: inactiveID,
            amount: 10,
            transactionDay: 20260826
        )
        let inactive = makeAccount(
            id: inactiveID,
            name: "已停用现金",
            deactivatedAt: Date(timeIntervalSince1970: 10)
        )
        let inactiveDetail = try #require(
            BookkeepingSearchPresentation.detail(
                transactionID: inactiveTransaction.id,
                transactions: [inactiveTransaction],
                accounts: [inactive],
                calendar: utcCalendar,
                locale: englishLocale
            )
        )
        let orphanTransaction = try AccountTransaction.validatingDiningExpense(
            id: UUID(),
            accountID: UUID(),
            amount: 10,
            transactionDay: 20260826
        )
        let orphanDetail = try #require(
            BookkeepingSearchPresentation.detail(
                transactionID: orphanTransaction.id,
                transactions: [orphanTransaction],
                accounts: [],
                calendar: utcCalendar,
                locale: chineseLocale
            )
        )

        #expect(inactiveDetail.accountState == .deactivated)
        #expect(inactiveDetail.canEdit == false)
        #expect(orphanDetail.accountState == .unavailable)
        #expect(orphanDetail.accountName == nil)
        #expect(orphanDetail.canEdit == false)
    }

    @Test("缺失流水不降级到其他记录")
    func missingTransactionDoesNotResolveAnotherRecord() {
        #expect(
            BookkeepingSearchPresentation.detail(
                transactionID: UUID(),
                transactions: [],
                accounts: [],
                calendar: utcCalendar,
                locale: englishLocale
            ) == nil
        )
    }

    @Test("账户从启用变为停用后详情立即移除编辑能力")
    func accountDeactivationRemovesEditing() throws {
        let accountID = UUID()
        let transaction = try AccountTransaction.validatingDiningExpense(
            id: UUID(),
            accountID: accountID,
            amount: 10,
            transactionDay: 20260826
        )
        let active = makeAccount(id: accountID, name: "现金")
        let activeDetail = try #require(
            BookkeepingSearchPresentation.detail(
                transactionID: transaction.id,
                transactions: [transaction],
                accounts: [active],
                calendar: utcCalendar,
                locale: englishLocale
            )
        )
        active.deactivatedAt = Date(timeIntervalSince1970: 20)
        let inactiveDetail = try #require(
            BookkeepingSearchPresentation.detail(
                transactionID: transaction.id,
                transactions: [transaction],
                accounts: [active],
                calendar: utcCalendar,
                locale: englishLocale
            )
        )

        #expect(activeDetail.canEdit)
        #expect(inactiveDetail.accountState == .deactivated)
        #expect(inactiveDetail.canEdit == false)
    }

    @Test("未知账户类型和非 CNY 数据保持只读")
    func unsupportedMetadataRemovesMutationActions() throws {
        let account = makeAccount(id: UUID(), name: "现金")
        let transaction = try AccountTransaction.validatingIncome(
            id: UUID(), accountID: account.id, category: .bonus,
            amount: 10, transactionDay: 20260915
        )
        account.typeRawValue = "futureAccountType"
        let unknown = BookkeepingSearchPresentation.detail(
            transactionID: transaction.id, transactions: [transaction], accounts: [account]
        )
        #expect(unknown?.canEdit == false)
        account.typeRawValue = AccountType.cash.rawValue
        account.currencyCode = "USD"
        let unsupportedCurrency = BookkeepingSearchPresentation.detail(
            transactionID: transaction.id, transactions: [transaction], accounts: [account]
        )
        #expect(unsupportedCurrency?.canEdit == false)
    }

    private var englishLocale: Locale { Locale(identifier: "en_US") }

    private var chineseLocale: Locale { Locale(identifier: "zh-Hans") }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    private func makeAccount(
        id: UUID,
        name: String,
        deactivatedAt: Date? = nil
    ) -> Account {
        Account(
            id: id,
            typeRawValue: AccountType.cash.rawValue,
            templateID: nil,
            name: name,
            note: nil,
            lastFourDigits: nil,
            balance: 100,
            currencyCode: "CNY",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            deactivatedAt: deactivatedAt
        )
    }
}
