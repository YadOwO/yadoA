import Foundation
import SwiftData
import Testing
@testable import yadoA

@Suite("图表页周期投影")
@MainActor
struct ChartOverviewPresentationTests {
    @Test("分类排行跨账户合并并按金额降序，金额相同保持稳定顺序", arguments: ChartPeriod.allCases)
    func ranksExpenseCategories(period: ChartPeriod) throws {
        let shopping = try AccountTransaction.validatingExpense(
            id: UUID(), accountID: UUID(), category: .shopping,
            amount: 20, transactionDay: 20260819
        )
        let entertainment = try AccountTransaction.validatingExpense(
            id: UUID(), accountID: UUID(), category: .entertainment,
            amount: 20, transactionDay: 20260819
        )
        let chart = ChartOverviewPresentation(
            period: period,
            anchorDate: try #require(date(year: 2026, month: 8, day: 19)),
            transactions: [
                shopping, entertainment,
                try dining(amount: "10.10", transactionDay: 20260819),
                try dining(amount: "20.20", transactionDay: 20260819),
                try income(amount: "999", transactionDay: 20260819),
                try dining(amount: "999", transactionDay: 20270101)
            ],
            calendar: utcCalendar,
            locale: Locale(identifier: "en")
        )

        #expect(chart.categoryRanking.map(\.id) == [
            "expense.dining", "expense.entertainment", "expense.shopping"
        ])
        #expect(chart.categoryRanking.first?.amount == Decimal(string: "30.30"))
        #expect(chart.categoryRanking.first?.title == ExpenseCategory.dining.localizedTitle(locale: Locale(identifier: "en")))
        #expect(chart.categoryRanking.first?.symbolName == ExpenseCategory.dining.symbolName)
        #expect(chart.categoryRanking.reduce(Decimal.zero) { $0 + $1.amount } == chart.totalAmount)
    }

    @Test("收入按周月年独立聚合，排除支出、调整和周期外流水", arguments: ChartPeriod.allCases)
    func projectsIncomeByPeriod(period: ChartPeriod) throws {
        let chart = ChartOverviewPresentation(
            period: period,
            entryType: .income,
            anchorDate: try #require(date(year: 2026, month: 8, day: 19)),
            transactions: [
                try income(amount: "100.10", transactionDay: 20260819),
                try income(amount: "0.20", transactionDay: 20260819),
                try income(amount: "10.50", transactionDay: 20260801),
                try income(amount: "20.00", transactionDay: 20260101),
                try income(amount: "999.00", transactionDay: 20270101),
                try dining(amount: "888.00", transactionDay: 20260819),
                try AccountTransaction.validatingBalanceAdjustment(
                    id: UUID(), accountID: UUID(), balanceBefore: 0,
                    balanceAfter: 500, transactionDay: 20260819
                )
            ],
            calendar: utcCalendar,
            locale: Locale(identifier: "en_US")
        )
        let expected: (total: String, count: Int, buckets: Int, bucket: Int, amount: String)
        switch period {
        case .week: expected = ("100.30", 2, 7, 20260819, "100.30")
        case .month: expected = ("110.80", 3, 31, 20260819, "100.30")
        case .year: expected = ("130.80", 4, 12, 202608, "110.80")
        }

        #expect(chart.entryType == .income)
        #expect(chart.totalAmount == Decimal(string: expected.total))
        #expect(chart.transactionCount == expected.count)
        #expect(chart.points.count == expected.buckets)
        #expect(chart.points.first { $0.bucketValue == expected.bucket }?.amount == Decimal(string: expected.amount))
        #expect(chart.points.reduce(Decimal.zero) { $0 + $1.amount } == chart.totalAmount)
        #expect(chart.categoryRanking.map(\.id) == ["income.salary"])
        #expect(chart.categoryRanking.first?.amount == chart.totalAmount)
        #expect(chart.points.contains { $0.amount == .zero })
        #expect(AccountLocalization.string(chart.summaryTitleLocalizationKey, locale: Locale(identifier: "en")) == "Income overview")
        #expect(AccountLocalization.string(chart.totalTitleLocalizationKey, locale: Locale(identifier: "zh-Hans")) == "总收入")
        #expect(AccountLocalization.string(chart.chartTitleLocalizationKey, locale: Locale(identifier: "zh-Hans")) == (period == .year ? "每月收入" : "每日收入"))
    }

    @Test("收入图表排除损坏金额、分类、业务日和未知类型")
    func excludesInvalidIncome() throws {
        let invalidAmount = try income(amount: "1", transactionDay: 20260819)
        invalidAmount.amount = -1
        let invalidCategory = try income(amount: "1", transactionDay: 20260819)
        invalidCategory.categoryRawValue = "unknown"
        let invalidDay = try income(amount: "1", transactionDay: 20260819)
        invalidDay.transactionDay = 20260230
        let unknownType = try income(amount: "1", transactionDay: 20260819)
        unknownType.typeRawValue = "unknown"
        let chart = ChartOverviewPresentation(
            period: .month,
            entryType: .income,
            anchorDate: try #require(date(year: 2026, month: 8, day: 19)),
            transactions: [invalidAmount, invalidCategory, invalidDay, unknownType],
            calendar: utcCalendar
        )

        #expect(chart.transactionCount == 0)
        #expect(chart.categoryRanking.isEmpty)
        #expect(chart.totalAmount == .zero)
        #expect(chart.points.count == 31)
        #expect(chart.points.allSatisfy { $0.amount == .zero })
    }

    @Test("查询同时读取收支，收入初始周期使用真实收入日期")
    func fetchesBothEntryTypesAndSelectsIncomeAnchor() throws {
        let container = try AccountDataContainer.inMemory()
        let context = ModelContext(container.modelContainer)
        let expense = try dining(amount: "3", transactionDay: 20260819)
        let salary = try income(amount: "100", transactionDay: 20260720)
        context.insert(expense)
        context.insert(salary)
        context.insert(try AccountTransaction.validatingBalanceAdjustment(
            id: UUID(), accountID: UUID(), balanceBefore: 0,
            balanceAfter: 10, transactionDay: 20260819
        ))
        try context.save()

        let transactions = try context.fetch(ChartOverviewPresentation.descriptor())
        #expect(Set(transactions.map(\.id)) == Set([expense.id, salary.id]))
        let now = try #require(date(year: 2026, month: 8, day: 19))
        let chart = ChartOverviewPresentation(
            period: .month,
            entryType: .income,
            transactions: transactions,
            now: now,
            calendar: utcCalendar
        )
        #expect(chart.anchorDate == date(year: 2026, month: 7, day: 20))
        #expect(chart.totalAmount == 100)
        #expect(ChartOverviewPresentation.initialAnchorDate(
            transactions: transactions, entryType: .income, now: now, calendar: utcCalendar
        ) == chart.anchorDate)
    }

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
            ),
            try AccountTransaction.validatingIncome(
                id: UUID(),
                accountID: UUID(),
                category: .salary,
                amount: 500,
                transactionDay: 20260819
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
        #expect(chart.totalAmount == Decimal(string: "10.00")!)
        #expect(chart.transactionCount == 3)
        #expect(chart.points.count == 7)
        #expect(chart.points.map(\.bucketValue) == [
            20260817, 20260818, 20260819, 20260820,
            20260821, 20260822, 20260823
        ])
        #expect(
            chart.points.first(where: { $0.bucketValue == 20260819 })?.amount
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
        #expect(chart.totalAmount == Decimal(string: "4.00")!)
        #expect(chart.transactionCount == 2)
        #expect(chart.points.count == 31)
        #expect(chart.points.first?.bucketValue == 20260801)
        #expect(chart.points.last?.bucketValue == 20260831)
        #expect(
            chart.points.first(where: { $0.bucketValue == 20260802 })?.amount
                == .zero
        )
        #expect(
            chart.points.first(where: { $0.bucketValue == 20260819 })?.amount
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
        #expect(chart.totalAmount == Decimal(string: "35.00")!)
        #expect(chart.transactionCount == 3)
        #expect(chart.points.map(\.bucketValue) == Array(202601...202612))
        #expect(
            chart.points.first(where: { $0.bucketValue == 202608 })?.amount
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
        #expect(chart.points.allSatisfy { $0.amount == .zero })
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
        #expect(chart.totalAmount == Decimal(string: "3.00")!)
    }

    @Test("每个点带完整时间和当天笔数，供选中时替换摘要")
    func pointsCarryDetailLabelAndCount() throws {
        let anchorDate = try #require(date(year: 2026, month: 8, day: 19))
        let transactions = [
            try dining(amount: "3.25", transactionDay: 20260819),
            try dining(amount: "4.75", transactionDay: 20260819),
            try dining(amount: "1.00", transactionDay: 20260801)
        ]
        let month = ChartOverviewPresentation(
            period: .month,
            anchorDate: anchorDate,
            transactions: transactions,
            calendar: utcCalendar,
            locale: Locale(identifier: "en_US")
        )
        let selected = try #require(month.point(bucketValue: 20260819))

        #expect(selected.formattedLabel == "19")
        #expect(selected.formattedDetailLabel.contains("Aug"))
        #expect(selected.formattedDetailLabel.contains("19"))
        #expect(selected.formattedDetailLabel.contains("Wed"))
        #expect(selected.transactionCount == 2)
        #expect(month.point(bucketValue: 20260802)?.transactionCount == 0)
        #expect(month.points.reduce(0) { $0 + $1.transactionCount } == month.transactionCount)

        let year = ChartOverviewPresentation(
            period: .year,
            anchorDate: anchorDate,
            transactions: transactions,
            calendar: utcCalendar,
            locale: Locale(identifier: "zh-Hans")
        )
        let august = try #require(year.point(bucketValue: 202608))
        #expect(august.formattedDetailLabel.contains("2026"))
        #expect(august.formattedDetailLabel.contains("8月"))
        #expect(august.transactionCount == 3)
    }

    @Test("按时间桶取点，没选中或不在本周期时为空")
    func looksUpPointByBucketValue() throws {
        let chart = try weekChart()

        #expect(chart.point(bucketValue: 20260819)?.bucketValue == 20260819)
        #expect(chart.point(bucketValue: nil) == nil)
        #expect(chart.point(bucketValue: 20260901) == nil)
    }

    @Test("按屏幕横坐标找最近的点，滑出两端停在头尾，一样近取较早的")
    func findsNearestPointByPosition() throws {
        let chart = try weekChart()
        let position = evenlySpacedPositions(of: chart, spacing: 40)

        #expect(chart.point(nearestX: 85, position: position)?.bucketValue == 20260819)
        #expect(chart.point(nearestX: 100, position: position)?.bucketValue == 20260819)
        #expect(chart.point(nearestX: -60, position: position)?.bucketValue == 20260817)
        #expect(chart.point(nearestX: 900, position: position)?.bucketValue == 20260823)
        // 算不出位置的点不参与比较
        #expect(chart.point(nearestX: 85) { $0.bucketValue == 20260819 ? nil : position($0) }?.bucketValue == 20260820)
        #expect(chart.point(nearestX: 85) { _ in nil } == nil)
    }

    @Test("点按选中最近的点，点在已选中的点上收起，点旁边的点换过去")
    func togglesSelectionOnTap() throws {
        let chart = try weekChart()
        let sparse = evenlySpacedPositions(of: chart, spacing: 40)

        // 没选中：选中最近的点
        #expect(chart.bucketValue(afterTapAtX: 125, selectedBucketValue: nil, tolerance: 22, position: sparse) == 20260820)
        // 点在已选中的点上：收起
        #expect(chart.bucketValue(afterTapAtX: 130, selectedBucketValue: 20260820, tolerance: 22, position: sparse) == nil)
        // 点在别的点上：换过去
        #expect(chart.bucketValue(afterTapAtX: 162, selectedBucketValue: 20260820, tolerance: 22, position: sparse) == 20260821)
        // 最近的还是已选中的点，但离得比手指宽还远（例如点在最后一点右边的空白）：保持不变
        #expect(chart.bucketValue(afterTapAtX: 280, selectedBucketValue: 20260823, tolerance: 22, position: sparse) == 20260823)

        // 点挨得近（月视图）：在手指宽度内但离旁边的点更近，换到旁边的点而不是收起
        let dense = evenlySpacedPositions(of: chart, spacing: 10)
        #expect(chart.bucketValue(afterTapAtX: 41, selectedBucketValue: 20260820, tolerance: 22, position: dense) == 20260821)
        #expect(chart.bucketValue(afterTapAtX: 31, selectedBucketValue: 20260820, tolerance: 22, position: dense) == nil)

        // 一个点的位置都算不出：不改动选中
        #expect(chart.bucketValue(afterTapAtX: 30, selectedBucketValue: 20260820, tolerance: 22) { _ in nil } == 20260820)
    }

    @Test("读屏上下轻扫逐点移动，到头停住，没选中时往后从头、往前从尾开始")
    func stepsThroughPointsForVoiceOver() throws {
        let chart = try weekChart()

        #expect(chart.point(steppingFrom: nil, by: 1)?.bucketValue == 20260817)
        #expect(chart.point(steppingFrom: nil, by: -1)?.bucketValue == 20260823)
        #expect(chart.point(steppingFrom: 20260819, by: 1)?.bucketValue == 20260820)
        #expect(chart.point(steppingFrom: 20260819, by: -1)?.bucketValue == 20260818)
        #expect(chart.point(steppingFrom: 20260817, by: -1)?.bucketValue == 20260817)
        #expect(chart.point(steppingFrom: 20260823, by: 1)?.bucketValue == 20260823)
        #expect(chart.point(steppingFrom: 20260901, by: 1)?.bucketValue == 20260817)
    }

    /// 2026-08-17（周一）到 08-23 的周视图，七个点，供选中逻辑测试。
    private func weekChart() throws -> ChartOverviewPresentation {
        let chart = ChartOverviewPresentation(
            period: .week,
            anchorDate: try #require(date(year: 2026, month: 8, day: 19)),
            transactions: [try dining(amount: "8.00", transactionDay: 20260819)],
            calendar: utcCalendar,
            locale: Locale(identifier: "en_US")
        )
        #expect(chart.points.map(\.bucketValue) == Array(20260817...20260823))
        return chart
    }

    /// 模拟图表把点等距排开：第 n 个点画在 `n * spacing` 处。
    ///
    /// - Parameters:
    ///   - chart: 要排开的周期投影。
    ///   - spacing: 相邻两点的间距。
    private func evenlySpacedPositions(
        of chart: ChartOverviewPresentation,
        spacing: CGFloat
    ) -> (ChartPointPresentation) -> CGFloat? {
        let indices = Dictionary(uniqueKeysWithValues: chart.points.enumerated().map { ($1.bucketValue, $0) })
        return { point in indices[point.bucketValue].map { CGFloat($0) * spacing } }
    }

    /// 创建独立账户的有效收入流水，覆盖跨账户聚合。
    private func income(amount: String, transactionDay: Int) throws -> AccountTransaction {
        try AccountTransaction.validatingIncome(
            id: UUID(),
            accountID: UUID(),
            category: .salary,
            amount: Decimal(string: amount)!,
            transactionDay: transactionDay
        )
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
