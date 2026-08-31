import Foundation
import SwiftData
import Testing
@testable import yadoA

@Suite("首页跨账户投影与月份导航", .serialized)
@MainActor
struct HomeOverviewPresentationTests {
    @Test("首页按真实分类展示本地化标题和图标")
    func projectsSelectedCategoryTitleAndSymbol() throws {
        let transaction = try AccountTransaction.validatingExpense(
            id: UUID(),
            accountID: UUID(),
            category: .travel,
            amount: 20,
            transactionDay: 20260831
        )
        let row = try #require(
            HomeOverviewPresentation.row(
                for: transaction,
                locale: Locale(identifier: "zh-Hans"),
                calendar: utcCalendar
            )
        )

        #expect(row.title == "旅行")
        #expect(row.symbolName == "airplane")
        #expect(row.accessibilityLabel.contains("旅行"))
    }

    @Test("跨账户查询使用业务日、保存时间和 UUID 的稳定排序")
    func descriptorUsesCrossAccountStableOrdering() throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let context = ModelContext(dataContainer.modelContainer)
        context.autosaveEnabled = false
        let firstAccountID = UUID()
        let secondAccountID = UUID()
        let baseSavedAt = Date(timeIntervalSince1970: 1_786_608_000)
        let dayID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let sameTimeLaterID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let sameTimeEarlierID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let olderDayID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

        let transactions = [
            try dining(
                id: olderDayID,
                accountID: firstAccountID,
                amount: "1",
                transactionDay: 20260812,
                savedAt: baseSavedAt.addingTimeInterval(300)
            ),
            try dining(
                id: sameTimeEarlierID,
                accountID: firstAccountID,
                amount: "2",
                transactionDay: 20260813,
                savedAt: baseSavedAt
            ),
            try dining(
                id: dayID,
                accountID: secondAccountID,
                amount: "3",
                transactionDay: 20260813,
                savedAt: baseSavedAt.addingTimeInterval(60)
            ),
            try dining(
                id: sameTimeLaterID,
                accountID: secondAccountID,
                amount: "4",
                transactionDay: 20260813,
                savedAt: baseSavedAt
            )
        ]
        transactions.forEach { context.insert($0) }
        try context.save()

        let fetched = try ModelContext(dataContainer.modelContainer).fetch(
            HomeOverviewPresentation.descriptor()
        )

        #expect(fetched.map(\.id) == [dayID, sameTimeEarlierID, sameTimeLaterID, olderDayID])
    }

    @Test("跨账户只投影有效餐饮流水并按天精确聚合")
    func projectsValidDiningAcrossAccountsAndGroupsByDay() throws {
        let firstAccountID = UUID()
        let secondAccountID = UUID()
        let baseSavedAt = Date(timeIntervalSince1970: 1_786_608_000)
        let newestID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let olderID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let invalidPayload = try dining(
            id: UUID(),
            accountID: firstAccountID,
            amount: "99",
            transactionDay: 20260813,
            savedAt: baseSavedAt
        )
        invalidPayload.amount = nil
        let unknownType = try dining(
            id: UUID(),
            accountID: firstAccountID,
            amount: "88",
            transactionDay: 20260813,
            savedAt: baseSavedAt
        )
        unknownType.typeRawValue = "futureType"
        let invalidDay = try dining(
            id: UUID(),
            accountID: secondAccountID,
            amount: "77",
            transactionDay: 20260813,
            savedAt: baseSavedAt
        )
        invalidDay.transactionDay = 20260899

        let presentation = HomeOverviewPresentation(
            transactions: [
                try dining(
                    id: olderID,
                    accountID: firstAccountID,
                    amount: "0.66",
                    transactionDay: 20260812,
                    savedAt: baseSavedAt.addingTimeInterval(300)
                ),
                try balanceAdjustment(
                    accountID: secondAccountID,
                    transactionDay: 20260813,
                    savedAt: baseSavedAt.addingTimeInterval(500)
                ),
                try dining(
                    id: newestID,
                    accountID: secondAccountID,
                    amount: "2.34",
                    transactionDay: 20260813,
                    note: "  午餐  ",
                    savedAt: baseSavedAt.addingTimeInterval(600)
                ),
                invalidPayload,
                unknownType,
                invalidDay
            ],
            now: try #require(date(year: 2026, month: 8, day: 20)),
            calendar: utcCalendar,
            locale: Locale(identifier: "en_US")
        )
        let month = try #require(HomeMonth(year: 2026, month: 8))
        let monthPresentation = presentation.presentation(for: month)

        #expect(presentation.availableMonths == [month])
        #expect(monthPresentation.incomeTotal == 0)
        #expect(monthPresentation.expenseTotal == Decimal(string: "3.00"))
        #expect(monthPresentation.dayGroups.map(\.transactionDay) == [20260813, 20260812])
        #expect(monthPresentation.dayGroups[0].expenseTotal == Decimal(string: "2.34"))
        #expect(monthPresentation.dayGroups[1].expenseTotal == Decimal(string: "0.66"))
        #expect(monthPresentation.dayGroups[0].rows.map(\.id) == [newestID])
        #expect(monthPresentation.dayGroups[0].rows[0].note == "午餐")
        #expect(monthPresentation.dayGroups[0].rows[0].formattedAmount == Decimal(-2.34).formatted(
            .currency(code: "CNY").locale(Locale(identifier: "en_US"))
        ))
    }

    @Test("初始月份优先当前月、最近历史月、最早未来月或当前空月")
    func selectsInitialMonthWithoutUsingMachineClock() throws {
        let current = try #require(HomeMonth(year: 2026, month: 8))
        let previous = try #require(HomeMonth(year: 2026, month: 7))
        let oldestPrevious = try #require(HomeMonth(year: 2026, month: 5))
        let earliestFuture = try #require(HomeMonth(year: 2026, month: 9))
        let laterFuture = try #require(HomeMonth(year: 2026, month: 11))

        #expect(
            HomeOverviewPresentation.initialMonth(
                now: try #require(date(year: 2026, month: 8, day: 20)),
                calendar: utcCalendar,
                availableMonths: [current, previous]
            ) == current
        )
        #expect(
            HomeOverviewPresentation.initialMonth(
                now: try #require(date(year: 2026, month: 8, day: 20)),
                calendar: utcCalendar,
                availableMonths: [oldestPrevious, previous]
            ) == previous
        )
        #expect(
            HomeOverviewPresentation.initialMonth(
                now: try #require(date(year: 2026, month: 8, day: 20)),
                calendar: utcCalendar,
                availableMonths: [laterFuture, earliestFuture]
            ) == earliestFuture
        )
        #expect(
            HomeOverviewPresentation.initialMonth(
                now: try #require(date(year: 2026, month: 8, day: 20)),
                calendar: utcCalendar,
                availableMonths: []
            ) == current
        )
    }

    @Test("空月份保留空状态且双向导航跳过连续空月")
    func emptyMonthCanNavigateInBothDirections() throws {
        let earlier = try #require(HomeMonth(year: 2026, month: 5))
        let selected = try #require(HomeMonth(year: 2026, month: 8))
        let later = try #require(HomeMonth(year: 2026, month: 11))
        let empty = try #require(HomeMonth(year: 2026, month: 7))
        let navigator = HomeMonthNavigator(availableMonths: [earlier, selected, later])
        let presentation = HomeOverviewPresentation(
            transactions: [],
            now: try #require(date(year: 2026, month: 8, day: 20)),
            calendar: utcCalendar,
            locale: Locale(identifier: "en_US")
        )

        #expect(navigator.earlierMonth(from: selected) == earlier)
        #expect(navigator.laterMonth(from: selected) == later)
        #expect(navigator.earlierMonth(from: earlier) == nil)
        #expect(navigator.laterMonth(from: later) == nil)
        #expect(presentation.presentation(for: empty).isEmpty)
    }

    @Test("日期、月份、分类和金额跟随注入语言环境本地化")
    func localizesMonthDayAndRows() throws {
        let transaction = try dining(
            id: UUID(),
            accountID: UUID(),
            amount: "12.34",
            transactionDay: 20260813
        )
        let now = try #require(date(year: 2026, month: 8, day: 20))
        let month = try #require(HomeMonth(year: 2026, month: 8))
        let english = HomeOverviewPresentation(
            transactions: [transaction],
            now: now,
            calendar: utcCalendar,
            locale: Locale(identifier: "en_US")
        ).presentation(for: month)
        let chinese = HomeOverviewPresentation(
            transactions: [transaction],
            now: now,
            calendar: utcCalendar,
            locale: Locale(identifier: "zh-Hans")
        ).presentation(for: month)

        #expect(english.formattedMonth.contains("August"))
        #expect(english.dayGroups[0].formattedWeekday == "Thursday")
        #expect(english.dayGroups[0].rows[0].title == "Dining")
        #expect(chinese.dayGroups[0].formattedWeekday == "星期四")
        #expect(chinese.dayGroups[0].rows[0].title == "餐饮")
        #expect(chinese.dayGroups[0].rows[0].accessibilityLabel.contains("餐饮"))
    }

    @Test("首页优先展示用户自定义标题")
    func prefersCustomTitleForRow() throws {
        let transaction = try dining(
            id: UUID(),
            accountID: UUID(),
            amount: "12.34",
            transactionDay: 20260813,
            title: "工作午餐"
        )
        let month = try #require(HomeMonth(year: 2026, month: 8))
        let presentation = HomeOverviewPresentation(
            transactions: [transaction],
            now: try #require(date(year: 2026, month: 8, day: 20)),
            calendar: utcCalendar,
            locale: Locale(identifier: "zh-Hans")
        ).presentation(for: month)

        #expect(presentation.dayGroups[0].rows[0].title == "工作午餐")
    }

    /// 构造使用固定排序键的餐饮流水。
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

    /// 构造只用于确认首页过滤边界的余额调整流水。
    private func balanceAdjustment(
        accountID: UUID,
        transactionDay: Int,
        savedAt: Date
    ) throws -> AccountTransaction {
        try AccountTransaction.validatingBalanceAdjustment(
            id: UUID(),
            accountID: accountID,
            balanceBefore: 100,
            balanceAfter: 120,
            transactionDay: transactionDay,
            savedAt: savedAt
        )
    }

    /// 创建测试使用的固定 UTC 公历。
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    /// 生成不依赖机器当前时间的公历日期。
    private func date(year: Int, month: Int, day: Int) -> Date? {
        utcCalendar.date(from: DateComponents(year: year, month: month, day: day))
    }
}
