import Foundation
import Testing
@testable import yadoA

/// 账单只按业务日统计真实收支，保证年、月与累计金额一致。
@Suite("账单年月汇总", .serialized)
@MainActor
struct BillOverviewPresentationTests {
    /// 使用固定时区，避免测试随运行设备日期和日历偏移。
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// 以 2026 年 10 月为当前月份。
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 2))!
    }

    @Test("跨账户按业务日精确汇总，历史年、未来月份和空月保持一致")
    func aggregatesByBusinessDate() throws {
        let transactions = [
            try expense("0.10", day: 20261001),
            try expense("0.20", day: 20261002),
            try income("100.00", day: 20261002),
            try expense("20.50", day: 20260831),
            try income("50.00", day: 20251231),
            try expense("10.00", day: 20261201)
        ]
        let presentation = makePresentation(transactions)
        let october = try #require(presentation.monthlyRows(for: 2026).first { $0.id == 202610 })
        #expect(october.totals.income == 100)
        #expect(october.totals.expense == Decimal(string: "0.30"))
        #expect(october.totals.balance == Decimal(string: "99.70"))
        #expect(presentation.totals(for: 2026).balance == Decimal(string: "69.20"))
        #expect(presentation.total.balance == Decimal(string: "119.20"))
        #expect(presentation.total.transactionCount == 6)
        #expect(presentation.availableYears == [2026, 2025])
        #expect(presentation.yearlyRows.map(\.id) == [2026, 2025])
        #expect(presentation.monthlyRows(for: 2026).map(\.id) == (1...12).reversed().map { 202600 + $0 })
        #expect(presentation.monthlyRows(for: 2026).first { $0.id == 202609 }?.totals == BillTotals())
        #expect(presentation.monthlyRows(for: 2025).count == 12)
        #expect(presentation.monthlyRows(for: 2025).reduce(Decimal.zero) { $0 + $1.totals.balance } == 50)
    }

    @Test("余额调整和损坏流水不产生账单或年份选项")
    func excludesNonBookkeepingTransactions() throws {
        let adjustment = try AccountTransaction.validatingBalanceAdjustment(
            id: UUID(), accountID: UUID(), balanceBefore: 0, balanceAfter: 999,
            transactionDay: 20240101
        )
        let invalidDate = try expense("5", day: 20250201)
        invalidDate.transactionDay = 20250230
        let invalidAmount = try expense("5", day: 20250101)
        invalidAmount.amount = nil
        let unknownType = try expense("5", day: 20250101)
        unknownType.typeRawValue = "futureType"
        let presentation = makePresentation([adjustment, invalidDate, invalidAmount, unknownType])
        #expect(presentation.total == BillTotals())
        #expect(presentation.availableYears == [2026])
        #expect(presentation.monthlyRows(for: 2026).count == 10)
        #expect(presentation.totals(for: 2025) == BillTotals())
    }

    @Test("收支相抵仍是有效账单，负结余保留符号")
    func distinguishesZeroBalanceFromEmpty() throws {
        let presentation = makePresentation([
            try income("10", day: 20260901),
            try expense("10", day: 20260902),
            try expense("8.75", day: 20261001)
        ])
        let september = try #require(presentation.monthlyRows(for: 2026).first { $0.id == 202609 })
        #expect(september.totals.balance == 0)
        #expect(september.totals.transactionCount == 2)
        #expect(presentation.total.balance == Decimal(string: "-8.75"))
    }

    @Test("非公历环境仍按持久化公历年份统计，当前空年也可选")
    func keepsGregorianYearsAndCurrentYear() throws {
        let transactions = [try income("25", day: 20251231)]
        let presentation = BillOverviewPresentation(
            transactions: transactions, now: now,
            calendar: Calendar(identifier: .buddhist), locale: Locale(identifier: "zh-Hans")
        )
        #expect(presentation.currentMonth.year == 2026)
        #expect(presentation.availableYears == [2026, 2025])
        #expect(presentation.yearTitle(2025).contains("2025"))
        #expect(presentation.totals(for: 2026).transactionCount == 0)
        #expect(presentation.total.income == 25)
    }

    /// 生成固定日期的投影。
    private func makePresentation(_ transactions: [AccountTransaction]) -> BillOverviewPresentation {
        BillOverviewPresentation(transactions: transactions, now: now, calendar: calendar)
    }

    /// 每条流水使用独立账户，覆盖跨账户聚合；保存时间与业务日刻意不同。
    private func expense(_ amount: String, day: Int) throws -> AccountTransaction {
        try AccountTransaction.validatingExpense(
            id: UUID(), accountID: UUID(), category: .dining,
            amount: Decimal(string: amount)!, transactionDay: day, savedAt: now
        )
    }

    /// 构造一笔工资收入。
    private func income(_ amount: String, day: Int) throws -> AccountTransaction {
        try AccountTransaction.validatingIncome(
            id: UUID(), accountID: UUID(), category: .salary,
            amount: Decimal(string: amount)!, transactionDay: day, savedAt: now
        )
    }
}
