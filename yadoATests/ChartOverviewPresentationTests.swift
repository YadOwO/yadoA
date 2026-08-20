import Foundation
import Testing
@testable import yadoA

@Suite("图表页周期投影")
@MainActor
struct ChartOverviewPresentationTests {
    @Test("周视图按七个自然日聚合并排除周期外和余额调整流水")
    func projectsCalendarWeekByDay() throws {
        let anchorDate = try #require(date(year: 2026, month: 8, day: 19))
        let transactions = [
            try dining(amount: "2.00", transactionDay: 20260817),
            try dining(amount: "3.25", transactionDay: 20260819),
            try dining(amount: "4.75", transactionDay: 20260819),
            try dining(amount: "99.00", transactionDay: 20260824),
            try AccountTransaction.validatingBalanceAdjustment(
                id: UUID(),
                accountID: UUID(),
                balanceBefore: 10,
                balanceAfter: 20,
                transactionDay: 20260818
            )
        ]

        let chart = ChartOverviewPresentation(
            period: .week,
            anchorDate: anchorDate,
            transactions: transactions,
            calendar: utcCalendar,
            locale: Locale(identifier: "en_US")
        )

        #expect(chart.period == .week)
        #expect(chart.totalExpense == Decimal(string: "10.00")!)
        #expect(chart.transactionCount == 3)
        #expect(chart.points.count == 7)
        #expect(chart.points.map(\.bucketValue) == [
            20260817, 20260818, 20260819, 20260820,
            20260821, 20260822, 20260823
        ])
        #expect(
            chart.points.first(where: { $0.bucketValue == 20260819 })?.expenseTotal
                == Decimal(string: "8.00")!
        )
    }

    @Test("月视图生成整月自然日并将无支出日期补零")
    func projectsCalendarMonthByDay() throws {
        let chart = ChartOverviewPresentation(
            period: .month,
            anchorDate: try #require(date(year: 2026, month: 8, day: 19)),
            transactions: [
                try dining(amount: "1.50", transactionDay: 20260801),
                try dining(amount: "2.50", transactionDay: 20260819),
                try dining(amount: "99.00", transactionDay: 20260901)
            ],
            calendar: utcCalendar,
            locale: Locale(identifier: "en_US")
        )

        #expect(chart.period == .month)
        #expect(chart.totalExpense == Decimal(string: "4.00")!)
        #expect(chart.transactionCount == 2)
        #expect(chart.points.count == 31)
        #expect(chart.points.first?.bucketValue == 20260801)
        #expect(chart.points.last?.bucketValue == 20260831)
        #expect(
            chart.points.first(where: { $0.bucketValue == 20260802 })?.expenseTotal
                == .zero
        )
        #expect(
            chart.points.first(where: { $0.bucketValue == 20260819 })?.expenseTotal
                == Decimal(string: "2.50")!
        )
        #expect(chart.formattedPeriod.contains("August"))
        #expect(chart.monthlyXAxisLabelValues == [
            "1", "6", "11", "16", "21", "26", "31"
        ])
    }

    @Test("月份滚轮年份不使用数字分组符")
    func formatsMonthPickerYearWithoutGroupingSeparator() {
        #expect(
            HomeMonthPickerPresentation.wheelTitle(
                for: 2026,
                locale: Locale(identifier: "en_US")
            ) == "2026"
        )
    }

    @Test("年视图生成十二个月并聚合同月支出")
    func projectsCalendarYearByMonth() throws {
        let chart = ChartOverviewPresentation(
            period: .year,
            anchorDate: try #require(date(year: 2026, month: 8, day: 19)),
            transactions: [
                try dining(amount: "10.00", transactionDay: 20260115),
                try dining(amount: "20.00", transactionDay: 20260801),
                try dining(amount: "5.00", transactionDay: 20260819),
                try dining(amount: "100.00", transactionDay: 20270101)
            ],
            calendar: utcCalendar,
            locale: Locale(identifier: "zh-Hans")
        )

        #expect(chart.period == .year)
        #expect(chart.totalExpense == Decimal(string: "35.00")!)
        #expect(chart.transactionCount == 3)
        #expect(chart.points.map(\.bucketValue) == Array(202601...202612))
        #expect(
            chart.points.first(where: { $0.bucketValue == 202608 })?.expenseTotal
                == Decimal(string: "25.00")!
        )
        #expect(chart.formattedPeriod.contains("2026"))
    }

    @Test("首次日期优先当前月、最近历史月、最早未来月或当前日期")
    func selectsInitialAnchorDateFromRealExpenses() throws {
        let now = try #require(date(year: 2026, month: 8, day: 19))
        let previousDate = try #require(date(year: 2026, month: 7, day: 20))
        let futureDate = try #require(date(year: 2026, month: 9, day: 5))

        #expect(
            ChartOverviewPresentation.initialAnchorDate(
                transactions: [try dining(amount: "1", transactionDay: 20260801)],
                now: now,
                calendar: utcCalendar
            ) == now
        )
        #expect(
            ChartOverviewPresentation.initialAnchorDate(
                transactions: [
                    try dining(amount: "1", transactionDay: 20260720),
                    try dining(amount: "1", transactionDay: 20260905)
                ],
                now: now,
                calendar: utcCalendar
            ) == previousDate
        )
        #expect(
            ChartOverviewPresentation.initialAnchorDate(
                transactions: [try dining(amount: "1", transactionDay: 20260905)],
                now: now,
                calendar: utcCalendar
            ) == futureDate
        )
        #expect(
            ChartOverviewPresentation.initialAnchorDate(
                transactions: [],
                now: now,
                calendar: utcCalendar
            ) == now
        )
    }

    @Test("周月年标题支持中英文且时间移动使用当前周期")
    func localizesPeriodsAndShiftsAnchor() throws {
        let english = Locale(identifier: "en")
        let simplifiedChinese = Locale(identifier: "zh-Hans")
        let anchorDate = try #require(date(year: 2026, month: 8, day: 19))

        #expect(ChartPeriod.allCases == [.week, .month, .year])
        #expect(ChartPeriod.week.title(locale: english) == "Week")
        #expect(ChartPeriod.month.title(locale: simplifiedChinese) == "月")
        #expect(ChartPeriod.year.title(locale: simplifiedChinese) == "年")

        let nextWeek = try #require(
            ChartOverviewPresentation.shiftedAnchorDate(
                anchorDate,
                period: .week,
                by: 1,
                calendar: utcCalendar
            )
        )
        let previousMonth = try #require(
            ChartOverviewPresentation.shiftedAnchorDate(
                anchorDate,
                period: .month,
                by: -1,
                calendar: utcCalendar
            )
        )
        let nextYear = try #require(
            ChartOverviewPresentation.shiftedAnchorDate(
                anchorDate,
                period: .year,
                by: 1,
                calendar: utcCalendar
            )
        )

        #expect(TransactionDay.encode(nextWeek, calendar: utcCalendar) == 20260826)
        #expect(TransactionDay.encode(previousMonth, calendar: utcCalendar) == 20260719)
        #expect(TransactionDay.encode(nextYear, calendar: utcCalendar) == 20270819)
    }

    @Test("没有有效支出时当前周期全部补零")
    func fillsEmptyPeriodWithZeroes() throws {
        let chart = ChartOverviewPresentation(
            period: .week,
            anchorDate: try #require(date(year: 2026, month: 8, day: 19)),
            transactions: [],
            calendar: utcCalendar,
            locale: Locale(identifier: "zh-Hans")
        )

        #expect(chart.transactionCount == 0)
        #expect(chart.points.count == 7)
        #expect(chart.points.allSatisfy { $0.expenseTotal == .zero })
    }

    @Test("夏令时周仍按本地自然日生成七个时间桶")
    func keepsSevenLocalDaysAcrossDaylightSavingTime() throws {
        let calendar = losAngelesCalendar
        let anchorDate = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 11))
        )
        let chart = ChartOverviewPresentation(
            period: .week,
            anchorDate: anchorDate,
            transactions: [
                try dining(amount: "1.00", transactionDay: 20260308),
                try dining(amount: "2.00", transactionDay: 20260314)
            ],
            calendar: calendar,
            locale: Locale(identifier: "en_US")
        )

        #expect(chart.points.map(\.bucketValue) == Array(20260308...20260314))
        #expect(chart.totalExpense == Decimal(string: "3.00")!)
    }

    /// 使用稳定 UUID 创建有效餐饮支出流水。
    private func dining(
        amount: String,
        transactionDay: Int
    ) throws -> AccountTransaction {
        try AccountTransaction.validatingDiningExpense(
            id: UUID(),
            accountID: UUID(),
            amount: Decimal(string: amount)!,
            transactionDay: transactionDay
        )
    }

    /// 测试统一使用周一为首日的 UTC 公历。
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    /// 使用周日为首日并覆盖夏令时切换的洛杉矶公历。
    private var losAngelesCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
        calendar.firstWeekday = 1
        calendar.minimumDaysInFirstWeek = 1
        return calendar
    }

    /// 构造测试使用的 UTC 公历日期。
    private func date(year: Int, month: Int, day: Int) -> Date? {
        utcCalendar.date(from: DateComponents(year: year, month: month, day: day))
    }
}
