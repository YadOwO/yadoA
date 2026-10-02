import Foundation

/// 分类占比图的展示投影；完整排行保持不变，仅在环形图中合并长尾分类。
struct CategoryBreakdownPresentation: Equatable {
    /// 合并项独立于账本中的“其他”分类，避免名称相同导致标识冲突。
    static let remainingID = "category-breakdown.remaining"

    /// 最多展示五个独立分类和一个合并项。
    let segments: [CategoryRankingItem]

    /// 所有有效分类的精确总额，与排行榜保持同一统计口径。
    let totalAmount: Decimal

    /// 将当前周期的分类汇总转为有限数量的环形扇区。
    init(items: [CategoryRankingItem], locale: Locale = .current) {
        let rankedItems = items.filter { $0.amount > 0 }.sorted {
            $0.amount == $1.amount ? $0.id < $1.id : $0.amount > $1.amount
        }
        totalAmount = rankedItems.reduce(Decimal.zero) { $0 + $1.amount }
        if rankedItems.count > 5 {
            segments = Array(rankedItems.prefix(5)) + [CategoryRankingItem(
                id: Self.remainingID,
                title: AccountLocalization.string("chart.category.remaining", locale: locale),
                symbolName: "ellipsis",
                amount: rankedItems.dropFirst(5).reduce(Decimal.zero) { $0 + $1.amount }
            )]
        } else {
            segments = rankedItems
        }
    }

    /// 仅在绘制角度和格式化百分比时转为 Double，金额汇总始终使用 Decimal。
    func share(of item: CategoryRankingItem) -> Double {
        guard totalAmount > 0 else { return 0 }
        return NSDecimalNumber(decimal: item.amount / totalAmount).doubleValue
    }

    /// Swift Charts 的角度选择值与扇区累计占比使用相同的零到一坐标。
    func segment(at value: Double) -> CategoryRankingItem? {
        guard value.isFinite, value >= 0, value <= 1 else { return nil }
        var upperBound = 0.0
        for segment in segments {
            upperBound += share(of: segment)
            if value < upperBound {
                return segment
            }
        }
        return segments.last
    }
}
