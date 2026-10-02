import Foundation
import Testing
@testable import yadoA

@Suite("记账搜索投影", .serialized)
@MainActor
struct BookkeepingSearchPresentationTests {
    @Test("收入分类支持搜索与详情展示")
    func incomeMatchesSearchAndDetail() throws {
        let transaction = try AccountTransaction.validatingIncome(
            id: UUID(),
            accountID: UUID(),
            category: .salary,
            amount: 500,
            transactionDay: 20260902
        )
        let account = account(id: transaction.accountID, name: "Cash")
        let presentation = BookkeepingSearchPresentation(
            transactions: [transaction],
            accounts: [account],
            query: "工资",
            locale: chineseLocale
        )
        let detail = BookkeepingSearchPresentation.detail(
            for: transaction,
            account: account,
            locale: chineseLocale
        )

        #expect(presentation.dayGroups.first?.rows.first?.categoryTitle == "工资")
        #expect(presentation.dayGroups.first?.rows.first?.formattedAmount.contains("500") == true)
        #expect(detail?.categoryTitle == "工资")
        #expect(detail?.formattedAmount.contains("500") == true)
    }

    @Test("备注支持包含匹配，且遗留标题不参与搜索")
    func noteMatchesWithoutUsingTitle() throws {
        let transaction = try dining(
            id: uuid("00000000-0000-0000-0000-000000000001"),
            accountID: uuid("00000000-0000-0000-0000-000000000101"),
            amount: "30",
            transactionDay: 20260826,
            title: "火锅标题",
            note: "和朋友吃火锅"
        )
        let account = account(
            id: transaction.accountID,
            name: "现金"
        )

        let noteMatch = BookkeepingSearchPresentation(
            transactions: [transaction],
            accounts: [account],
            query: " 火锅 ",
            locale: chineseLocale
        )
        let titleOnlyMatch = BookkeepingSearchPresentation(
            transactions: [transaction],
            accounts: [account],
            query: "标题",
            locale: chineseLocale
        )

        #expect(noteMatch.dayGroups.flatMap(\.rows).map(\.id) == [transaction.id])
        #expect(titleOnlyMatch.dayGroups.isEmpty)
        #expect(noteMatch.dayGroups[0].rows[0].note == "和朋友吃火锅")
    }

    @Test("类别按当前语言环境匹配")
    func categoryMatchesLocalizedTitle() throws {
        let transaction = try dining(
            id: UUID(),
            accountID: UUID(),
            amount: "12.34",
            transactionDay: 20260826
        )
        let account = account(id: transaction.accountID, name: "Cash")

        let chinese = BookkeepingSearchPresentation(
            transactions: [transaction],
            accounts: [account],
            query: "餐",
            locale: chineseLocale
        )
        let english = BookkeepingSearchPresentation(
            transactions: [transaction],
            accounts: [account],
            query: "Din",
            locale: englishLocale
        )

        #expect(chinese.dayGroups.flatMap(\.rows).count == 1)
        #expect(english.dayGroups.flatMap(\.rows).count == 1)
        #expect(chinese.dayGroups[0].rows[0].categoryTitle == "餐饮")
        #expect(english.dayGroups[0].rows[0].categoryTitle == "Dining")
    }

    @Test("新增分类按中英文名称搜索并进入详情")
    func selectedCategoryMatchesSearchAndDetail() throws {
        let transaction = try AccountTransaction.validatingExpense(
            id: UUID(),
            accountID: UUID(),
            category: .medical,
            amount: 50,
            transactionDay: 20260831
        )
        let account = account(id: transaction.accountID, name: "Cash")

        let chinese = BookkeepingSearchPresentation(
            transactions: [transaction],
            accounts: [account],
            query: "医疗",
            locale: chineseLocale
        )
        let english = BookkeepingSearchPresentation(
            transactions: [transaction],
            accounts: [account],
            query: "Medical",
            locale: englishLocale
        )
        let detail = BookkeepingSearchPresentation.detail(
            for: transaction,
            account: account,
            locale: chineseLocale
        )

        #expect(chinese.dayGroups[0].rows[0].categoryTitle == "医疗")
        #expect(english.dayGroups[0].rows[0].categoryTitle == "Medical")
        #expect(detail?.categoryTitle == "医疗")
    }

    @Test("金额查询使用完整 Decimal 精确相等")
    func amountMatchesExactly() throws {
        let accountID = UUID()
        let transactions = try [
            dining(id: UUID(), accountID: accountID, amount: "30.00", transactionDay: 20260826),
            dining(id: UUID(), accountID: accountID, amount: "30.50", transactionDay: 20260825),
            dining(id: UUID(), accountID: accountID, amount: "130.00", transactionDay: 20260824)
        ]
        let account = account(id: accountID, name: "Cash")

        let thirty = BookkeepingSearchPresentation(
            transactions: transactions,
            accounts: [account],
            query: "30",
            locale: englishLocale
        )
        let thirtyWithDecimals = BookkeepingSearchPresentation(
            transactions: transactions,
            accounts: [account],
            query: "30.00",
            locale: englishLocale
        )
        let thirtyPointFive = BookkeepingSearchPresentation(
            transactions: transactions,
            accounts: [account],
            query: "30.5",
            locale: englishLocale
        )
        let currencyLike = BookkeepingSearchPresentation(
            transactions: transactions,
            accounts: [account],
            query: "¥30.00",
            locale: englishLocale
        )

        #expect(thirty.dayGroups.flatMap(\.rows).map(\.formattedAmount).count == 1)
        #expect(thirtyWithDecimals.dayGroups.flatMap(\.rows).map(\.formattedAmount).count == 1)
        #expect(thirtyPointFive.dayGroups.flatMap(\.rows).map(\.formattedAmount).count == 1)
        #expect(thirty.dayGroups[0].rows[0].formattedAmount.contains("30"))
        #expect(thirtyWithDecimals.dayGroups[0].rows[0].id == transactions[0].id)
        #expect(thirtyPointFive.dayGroups[0].rows[0].id == transactions[1].id)
        #expect(currencyLike.dayGroups.isEmpty)
    }

    @Test("区域小数分隔符可解析，混合金额字符不形成字符串包含匹配")
    func amountParsingUsesLocaleWithoutPartialMatching() throws {
        let accountID = UUID()
        let target = try dining(
            id: UUID(),
            accountID: accountID,
            amount: "30.50",
            transactionDay: 20260826,
            note: "午餐"
        )
        let other = try dining(
            id: UUID(),
            accountID: accountID,
            amount: "130.00",
            transactionDay: 20260825,
            note: "其他"
        )
        let account = account(id: accountID, name: "Cash")

        let comma = BookkeepingSearchPresentation(
            transactions: [target, other],
            accounts: [account],
            query: "30,50",
            locale: Locale(identifier: "de_DE")
        )
        let grouped = BookkeepingSearchPresentation(
            transactions: [target, other],
            accounts: [account],
            query: "1,000",
            locale: Locale(identifier: "de_DE")
        )
        let textStillMatches = BookkeepingSearchPresentation(
            transactions: [target, other],
            accounts: [account],
            query: "午",
            locale: chineseLocale
        )

        #expect(comma.dayGroups.flatMap(\.rows).map(\.id) == [target.id])
        #expect(grouped.dayGroups.isEmpty)
        #expect(textStillMatches.dayGroups.flatMap(\.rows).map(\.id) == [target.id])
    }

    @Test("关键词和业务日范围使用 OR 后 AND 语义")
    func queryAndClosedDateRangeIntersect() throws {
        let accountID = UUID()
        let transactions = try [
            dining(id: UUID(), accountID: accountID, amount: "10", transactionDay: 20260801, note: "早餐"),
            dining(id: UUID(), accountID: accountID, amount: "20", transactionDay: 20260815, note: "午餐"),
            dining(id: UUID(), accountID: accountID, amount: "30", transactionDay: 20260831, note: "晚餐")
        ]
        let range = try #require(
            BookkeepingSearchDateRange(startDay: 20260815, endDay: 20260831)
        )
        let account = account(id: accountID, name: "Cash")

        let dateOnly = BookkeepingSearchPresentation(
            transactions: transactions,
            accounts: [account],
            query: "",
            timeFilter: .custom(range),
            locale: englishLocale
        )
        let intersected = BookkeepingSearchPresentation(
            transactions: transactions,
            accounts: [account],
            query: "午",
            timeFilter: .custom(range),
            locale: chineseLocale
        )

        #expect(dateOnly.dayGroups.flatMap(\.rows).map(\.id) == [transactions[2].id, transactions[1].id])
        #expect(intersected.dayGroups.flatMap(\.rows).map(\.id) == [transactions[1].id])
        #expect(dateOnly.state == .results)
    }

    @Test("业务日范围包含首尾且拒绝反向区间")
    func dateRangeIsInclusiveAndOrdered() throws {
        let range = try #require(
            BookkeepingSearchDateRange(startDay: 20260815, endDay: 20260831)
        )

        #expect(range.contains(20260815))
        #expect(range.contains(20260831))
        #expect(range.contains(20260901) == false)
        #expect(BookkeepingSearchDateRange(startDay: 20260831, endDay: 20260815) == nil)
    }

    @Test("空关键词和不限时间是初始态，不展示全部流水")
    func emptyUnboundedSearchIsInitial() throws {
        let transaction = try dining(
            id: UUID(),
            accountID: UUID(),
            amount: "10",
            transactionDay: 20260826
        )
        let presentation = BookkeepingSearchPresentation(
            transactions: [transaction],
            accounts: [],
            query: " \n\t",
            locale: englishLocale
        )

        #expect(presentation.normalizedQuery.isEmpty)
        #expect(presentation.state == .initial)
        #expect(presentation.dayGroups.isEmpty)
    }

    @Test("余额调整、未知类型、损坏载荷和无效业务日均被排除")
    func invalidAndNonDiningTransactionsAreExcluded() throws {
        let accountID = UUID()
        let validDining = try dining(
            id: UUID(),
            accountID: accountID,
            amount: "10",
            transactionDay: 20260826,
            note: "命中"
        )
        let adjustment = try AccountTransaction.validatingBalanceAdjustment(
            id: UUID(),
            accountID: accountID,
            balanceBefore: 100,
            balanceAfter: 120,
            transactionDay: 20260826,
            note: "命中"
        )
        let unknown = try dining(
            id: UUID(),
            accountID: accountID,
            amount: "10",
            transactionDay: 20260826,
            note: "命中"
        )
        unknown.typeRawValue = "futureType"
        let corrupted = try dining(
            id: UUID(),
            accountID: accountID,
            amount: "10",
            transactionDay: 20260826,
            note: "命中"
        )
        corrupted.amount = nil
        let invalidDay = try dining(
            id: UUID(),
            accountID: accountID,
            amount: "10",
            transactionDay: 20260826,
            note: "命中"
        )
        invalidDay.transactionDay = 20260230

        let presentation = BookkeepingSearchPresentation(
            transactions: [adjustment, unknown, corrupted, invalidDay, validDining],
            accounts: [account(id: accountID, name: "Cash")],
            query: "命中",
            locale: englishLocale
        )

        let rows = presentation.dayGroups.flatMap { $0.rows }
        #expect(rows.map { $0.id } == [validDining.id])
    }

    @Test("启用、停用和孤立账户都保留，且结果稳定排序")
    func accountLifecycleAndOrderingArePreserved() throws {
        let activeID = uuid("00000000-0000-0000-0000-000000000201")
        let inactiveID = uuid("00000000-0000-0000-0000-000000000202")
        let missingID = uuid("00000000-0000-0000-0000-000000000203")
        let sameTime = Date(timeIntervalSince1970: 100)
        let firstID = uuid("00000000-0000-0000-0000-000000000301")
        let secondID = uuid("00000000-0000-0000-0000-000000000302")
        let transactions = try [
            dining(id: firstID, accountID: activeID, amount: "10", transactionDay: 20260826, savedAt: sameTime),
            dining(id: secondID, accountID: activeID, amount: "20", transactionDay: 20260826, savedAt: sameTime),
            dining(id: UUID(), accountID: inactiveID, amount: "30", transactionDay: 20260825),
            dining(id: UUID(), accountID: missingID, amount: "40", transactionDay: 20260824)
        ]
        let presentation = BookkeepingSearchPresentation(
            transactions: transactions,
            accounts: [
                account(id: activeID, name: "Active"),
                account(id: inactiveID, name: "Inactive", deactivatedAt: sameTime)
            ],
            query: "",
            timeFilter: .custom(try #require(BookkeepingSearchDateRange(startDay: 20260824, endDay: 20260826))),
            locale: englishLocale
        )
        let rows = presentation.dayGroups.flatMap(\.rows)

        #expect(rows.map(\.id) == [firstID, secondID, transactions[2].id, transactions[3].id])
        #expect(rows[0].accountState == .active)
        #expect(rows[0].accountName == "Active")
        #expect(rows[2].accountState == .deactivated)
        #expect(rows[2].accountName == "Inactive")
        #expect(rows[3].accountState == .unavailable)
        #expect(rows[3].accountName == nil)
    }

    @Test("搜索投影在大数据量下先过滤后格式化")
    func representativeProjectionMeetsPerformanceBudget() throws {
        let accountID = UUID()
        let account = account(id: accountID, name: "Cash")
        let transactions = try (0..<10_000).map { index in
            try dining(
                id: UUID(),
                accountID: accountID,
                amount: "10",
                transactionDay: 20260101 + index % 28,
                note: index == 5_000 ? "火锅" : "普通餐"
            )
        }
        let start = Date()
        let presentation = BookkeepingSearchPresentation(
            transactions: transactions,
            accounts: [account],
            query: "火锅",
            locale: chineseLocale
        )
        let elapsed = Date().timeIntervalSince(start)

        #expect(presentation.dayGroups.flatMap(\.rows).count == 1)
        #expect(elapsed < 0.1)
    }

    private var englishLocale: Locale { Locale(identifier: "en_US") }

    private var chineseLocale: Locale { Locale(identifier: "zh-Hans") }

    private func dining(
        id: UUID,
        accountID: UUID,
        amount: String,
        transactionDay: Int,
        title: String? = nil,
        note: String = "",
        savedAt: Date = Date(timeIntervalSince1970: 1_786_608_000)
    ) throws -> AccountTransaction {
        try AccountTransaction.validatingDiningExpense(
            id: id,
            accountID: accountID,
            amount: try #require(Decimal(string: amount)),
            transactionDay: transactionDay,
            title: title,
            note: note,
            savedAt: savedAt
        )
    }

    private func account(
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

    private func uuid(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }
}
