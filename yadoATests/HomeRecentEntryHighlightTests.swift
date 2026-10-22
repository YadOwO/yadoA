import Foundation
import Testing
@testable import yadoA

/// 首页变更提示通道支持一次登记多条，语音记账一句话可能同时改动好几笔。
@Suite("首页变更提示", .serialized)
@MainActor
struct HomeRecentEntryHighlightTests {
    @Test("多条提示按登记顺序一次取走，取走后清空")
    func consumesAllEntriesInOrder() {
        let highlight = HomeRecentEntryHighlight.shared
        _ = highlight.consume()
        let first = UUID()
        let second = UUID()

        highlight.mark(id: first, transactionDay: 20261020)
        highlight.mark(id: second, transactionDay: 20260930, change: .updated(previous: nil))

        let entries = highlight.consume()
        #expect(entries.map(\.id) == [first, second])
        #expect(entries.map(\.transactionDay) == [20261020, 20260930])
        #expect(highlight.consume().isEmpty)
    }

    @Test("同一笔流水再次登记时替换尚未展示的旧提示")
    func replacesPendingEntryForSameTransaction() {
        let highlight = HomeRecentEntryHighlight.shared
        _ = highlight.consume()
        let id = UUID()

        highlight.mark(id: id, transactionDay: 20261020)
        highlight.mark(id: id, transactionDay: 20261021, change: .updated(previous: nil))

        let entries = highlight.consume()
        #expect(entries.count == 1)
        #expect(entries.first?.transactionDay == 20261021)
        #expect(entries.first?.change == .updated(previous: nil))
    }

    // MARK: - 定位目标

    @Test("一批变更切到笔数最多的月份，只在该月的流水里取锚点")
    func focusesMonthWithMostEntries() throws {
        let october = [UUID(), UUID()]
        let entries = [
            entry(day: 20260928),
            entry(october[0], day: 20261020),
            entry(october[1], day: 20261003)
        ]

        let focus = try #require(HomeEntryFocus(entries: entries, currentMonth: month(202609), today: month(202610)))

        #expect(focus.month == month(202610))
        #expect(focus.transactionIDs == Set(october))
    }

    @Test("笔数相同时优先停留在首页当前所在的月份")
    func prefersCurrentMonthOnTie() throws {
        let entries = [entry(day: 20261020), entry(day: 20260815)]

        let focus = try #require(HomeEntryFocus(entries: entries, currentMonth: month(202608), today: month(202610)))

        #expect(focus.month == month(202608))
    }

    @Test("笔数相同且都不是当前月份时选离今天最近的月份")
    func prefersMonthNearestToToday() throws {
        let entries = [entry(day: 20260115), entry(day: 20261105)]

        let focus = try #require(HomeEntryFocus(entries: entries, currentMonth: month(202607), today: month(202610)))

        #expect(focus.month == month(202611))
    }

    @Test("与今天距离也相同时选更晚的月份")
    func prefersLaterMonthWhenEquallyNear() throws {
        let entries = [entry(day: 20260901), entry(day: 20261101)]

        let focus = try #require(HomeEntryFocus(entries: entries, currentMonth: nil, today: month(202610)))

        #expect(focus.month == month(202611))
    }

    @Test("记账日都无效时没有定位目标")
    func noFocusForInvalidDays() {
        #expect(HomeEntryFocus(entries: [entry(day: 0)], currentMonth: nil, today: month(202610)) == nil)
        #expect(HomeEntryFocus(entries: [], currentMonth: nil, today: month(202610)) == nil)
    }

    /// 生成一条新增提示。
    private func entry(_ id: UUID = UUID(), day: Int) -> HomeRecentEntryHighlight.Entry {
        HomeRecentEntryHighlight.Entry(id: id, transactionDay: day, change: .added, savedAt: .now)
    }

    /// 由 `YYYYMM` 生成月份。
    private func month(_ value: Int) -> HomeMonth? {
        HomeMonth(value: value)
    }
}
