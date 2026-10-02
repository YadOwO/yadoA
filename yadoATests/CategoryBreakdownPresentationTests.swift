import Foundation
import Testing
@testable import yadoA

/// 验证环形图长尾合并与角度选择，防止展示金额和完整排行榜不一致。
@Suite("分类占比投影")
@MainActor
struct CategoryBreakdownPresentationTests {
    @Test("前五分类之外的金额精确合并，账本其他分类保留独立标识")
    func combinesTailWithoutLosingAmounts() {
        let items: [CategoryRankingItem] = [
            item("expense.other", amount: "100.01"),
            item("expense.dining", amount: "90.02"),
            item("expense.shopping", amount: "80.03"),
            item("expense.travel", amount: "70.04"),
            item("expense.housing", amount: "60.05"),
            item("expense.clothing", amount: "0.10"),
            item("expense.entertainment", amount: "0.20")
        ]
        let breakdown = CategoryBreakdownPresentation(items: items.reversed(), locale: Locale(identifier: "zh-Hans"))
        #expect(breakdown.segments.count == 6)
        #expect(breakdown.segments.first?.id == "expense.other")
        #expect(breakdown.segments.last?.id == CategoryBreakdownPresentation.remainingID)
        #expect(breakdown.segments.last?.title == "其他分类")
        #expect(breakdown.segments.last?.amount == Decimal(string: "0.30"))
        #expect(breakdown.segments.reduce(Decimal.zero) { $0 + $1.amount } == breakdown.totalAmount)
        #expect(breakdown.totalAmount == Decimal(string: "400.45"))
    }

    @Test("空数据与非正金额不产生扇区，单分类占比为百分之百")
    func handlesEmptyAndSingleCategory() {
        let empty = CategoryBreakdownPresentation(items: [item("zero", amount: "0"), item("negative", amount: "-1")])
        #expect(empty.segments.isEmpty)
        #expect(empty.totalAmount == 0)
        #expect(empty.segment(at: 0) == nil)
        let single = item("income.salary", amount: "12.50")
        let breakdown = CategoryBreakdownPresentation(items: [single])
        #expect(breakdown.share(of: single) == 1)
        #expect(breakdown.segments == [single])
        #expect(breakdown.segment(at: 0.5) == single)
    }

    @Test("选择使用累计占比且正确处理边界和无效输入")
    func resolvesSelectedSector() {
        let first = item("income.salary", amount: "75")
        let second = item("income.bonus", amount: "25")
        let breakdown = CategoryBreakdownPresentation(items: [second, first])
        #expect(breakdown.segment(at: 0) == first)
        #expect(breakdown.segment(at: 0.749) == first)
        #expect(breakdown.segment(at: 0.75) == second)
        #expect(breakdown.segment(at: 1) == second)
        #expect(breakdown.segment(at: -.infinity) == nil)
        #expect(breakdown.segment(at: .nan) == nil)
        #expect(breakdown.segment(at: -0.1) == nil)
        #expect(breakdown.segment(at: 1.1) == nil)
    }

    /// 构造仅含展示数据的分类，无需数据库或 UI 环境。
    private func item(_ id: String, amount: String) -> CategoryRankingItem {
        CategoryRankingItem(id: id, title: id, symbolName: "circle", amount: Decimal(string: amount)!)
    }
}
