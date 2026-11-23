import Foundation

/// 环形占比图的展示投影；完整排行保持不变，仅在环形图中合并长尾。
///
/// 分类统计按分类、资产分析按账户类型使用它，两处共用同一套合并与占比规则。
struct CategoryBreakdownPresentation: Equatable {
    /// 合并项独立于账本中的“其他”分类，避免名称相同导致标识冲突。
    static let remainingID = "category-breakdown.remaining"

    /// 最多 `maxSegments` 个独立项和一个合并项。
    let segments: [CategoryRankingItem]

    /// 所有有效项的精确总额，与排行榜保持同一统计口径。
    let totalAmount: Decimal

    /// 将汇总转为有限数量的环形扇区。
    ///
    /// - Parameters:
    ///   - items: 每一项的汇总；金额不为正的项不画。
    ///   - locale: 合并项名称使用的语言环境。
    ///   - maxSegments: 单独画出的最多项数，超出的合并成一项；分类统计用 5，资产构成按配色位数用 3。
    ///   - remainingTitleKey: 合并项名称的本地化键。
    init(
        items: [CategoryRankingItem],
        locale: Locale = .current,
        maxSegments: Int = 5,
        remainingTitleKey: String = "chart.category.remaining"
    ) {
        let rankedItems = items.filter { $0.amount > 0 }.sorted {
            $0.amount == $1.amount ? $0.id < $1.id : $0.amount > $1.amount
        }
        totalAmount = rankedItems.reduce(Decimal.zero) { $0 + $1.amount }
        if rankedItems.count > maxSegments {
            segments = Array(rankedItems.prefix(maxSegments)) + [CategoryRankingItem(
                id: Self.remainingID,
                title: AccountLocalization.string(remainingTitleKey, locale: locale),
                symbolName: "ellipsis",
                amount: rankedItems.dropFirst(maxSegments).reduce(Decimal.zero) { $0 + $1.amount }
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
