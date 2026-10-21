import Foundation
import Testing
@testable import yadoA

@Suite("自定义分类在各页面的展示")
@MainActor
struct CustomCategoryPresentationTests {
    private let chinese = Locale(identifier: "zh-Hans")
    private let coffeeKey = BookkeepingCategoryKey.customKey(for: UUID())

    /// 含一个自定义支出分类的目录。
    private var catalog: BookkeepingCategoryCatalog {
        BookkeepingCategoryCatalog(items: [
            BookkeepingCategoryItem(
                direction: .expense,
                key: coffeeKey,
                customName: "咖啡",
                symbolName: "cup.and.saucer",
                sortIndex: 16,
                isDeleted: false
            )
        ])
    }

    @Test("首页行显示自定义分类的名称和图标")
    func homeRowUsesCustomCategory() throws {
        let transaction = try expense(key: coffeeKey, amount: 18)

        let row = try #require(HomeOverviewPresentation.row(for: transaction, locale: chinese, catalog: catalog))
        #expect(row.title == "咖啡")
        #expect(row.symbolName == "cup.and.saucer")

        let month = HomeOverviewPresentation(transactions: [transaction], locale: chinese, catalog: catalog)
            .presentation(for: try #require(HomeMonth(year: 2026, month: 10)))
        #expect(month.dayGroups.first?.rows.first?.title == "咖啡")
    }

    @Test("搜索按自定义分类名称匹配，详情显示自定义名称")
    func searchMatchesCustomCategoryName() throws {
        let transaction = try expense(key: coffeeKey, amount: 18)

        let result = BookkeepingSearchPresentation(
            transactions: [transaction], accounts: [], query: "咖啡", locale: chinese, catalog: catalog
        )
        #expect(result.state == .results)
        #expect(result.dayGroups.first?.rows.first?.categoryTitle == "咖啡")
        #expect(result.dayGroups.first?.rows.first?.symbolName == "cup.and.saucer")

        let detail = try #require(BookkeepingSearchPresentation.detail(
            for: transaction, account: nil, locale: chinese, catalog: catalog
        ))
        #expect(detail.categoryTitle == "咖啡")
        #expect(detail.categorySymbolName == "cup.and.saucer")
    }

    @Test("图表分类排行按自定义分类聚合")
    func chartRanksCustomCategory() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let chart = ChartOverviewPresentation(
            period: .month,
            anchorDate: try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 20))),
            transactions: [
                try expense(key: coffeeKey, amount: 18),
                try expense(key: coffeeKey, amount: 12),
                try expense(key: "dining", amount: 20)
            ],
            calendar: calendar,
            locale: chinese,
            catalog: catalog
        )

        #expect(chart.categoryRanking.first?.id == "expense.\(coffeeKey)")
        #expect(chart.categoryRanking.first?.title == "咖啡")
        #expect(chart.categoryRanking.first?.amount == 30)
    }

    @Test("账户流水和编辑草稿使用自定义分类名称")
    func historyAndEditDraftUseCustomCategory() throws {
        let transaction = try expense(key: coffeeKey, amount: 18)

        let row = try #require(AccountTransactionHistoryPresentation.row(
            for: transaction, locale: chinese, catalog: catalog
        ))
        #expect(row.title == "咖啡")

        let draft = try #require(DiningExpenseEditDraft(transaction: transaction, locale: chinese, catalog: catalog))
        #expect(draft.expenseCategoryKey == coffeeKey)
        #expect(draft.title == "咖啡")
        #expect(draft.incomeCategoryKey == "salary")
    }

    /// 创建 2026-10-20 的一笔支出。
    private func expense(key: String, amount: Decimal) throws -> AccountTransaction {
        try AccountTransaction.validatingExpense(
            id: UUID(), accountID: UUID(), categoryKey: key,
            amount: amount, transactionDay: 20261020
        )
    }
}
