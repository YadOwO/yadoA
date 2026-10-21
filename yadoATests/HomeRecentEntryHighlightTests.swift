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
}
