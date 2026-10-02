import SwiftUI

/// 可复用分类排行的展示数据，不依赖 Charts 页面或 SwiftData 查询。
struct CategoryRankingItem: Identifiable, Equatable {
    /// 分类的稳定标识。
    let id: String
    /// 已本地化的分类名称。
    let title: String
    /// 分类的 SF Symbols 图标。
    let symbolName: String
    /// 分类汇总金额，使用 Decimal 保持金额精度。
    let amount: Decimal
}

/// 分类排行榜卡片；调用方传入当前筛选下的分类汇总，组件负责排序和占比展示。
struct CategoryRankingView: View {
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 已本地化的排行榜标题。
    let title: String
    /// 每个分类一项的汇总数据；零额分类不展示。
    let items: [CategoryRankingItem]
    /// 金额展示使用的货币代码，默认与现有记账保持一致。
    var currencyCode = "CNY"

    var body: some View {
        let rankedItems = items.filter { $0.amount > 0 }.sorted {
            $0.amount == $1.amount ? $0.id < $1.id : $0.amount > $1.amount
        }
        let total = rankedItems.reduce(Decimal.zero) { $0 + $1.amount }
        let maximum = rankedItems.first?.amount ?? .zero

        VStack(alignment: .leading, spacing: 20) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if rankedItems.isEmpty {
                Text(AccountLocalization.string("category.ranking.empty", locale: locale))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 64)
            } else {
                ForEach(rankedItems) { item in
                    rankingRow(item, total: total, maximum: maximum)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityIdentifier("category-ranking")
    }

    /// 一行分类信息；大字号下将金额移至下一行，保证名称和金额可完整阅读。
    private func rankingRow(
        _ item: CategoryRankingItem,
        total: Decimal,
        maximum: Decimal
    ) -> some View {
        let percentage = ratio(item.amount, to: total)
            .formatted(.percent.precision(.fractionLength(1)).locale(locale))
        let amount = item.amount.formatted(.currency(code: currencyCode).locale(locale))

        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.symbolName)
                .font(.body)
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.1), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                if dynamicTypeSize.isAccessibilitySize {
                    categoryLabel(item, percentage: percentage)
                    Text(amount)
                        .font(.subheadline.monospacedDigit())
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            categoryLabel(item, percentage: percentage)
                            Spacer(minLength: 0)
                            Text(amount)
                                .font(.subheadline.monospacedDigit())
                                .fixedSize()
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            categoryLabel(item, percentage: percentage)
                            Text(amount)
                                .font(.subheadline.monospacedDigit())
                        }
                    }
                }

                ProgressView(value: ratio(item.amount, to: maximum))
                    .tint(Color.accentColor)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(item.title))
        .accessibilityValue(Text("\(amount), \(percentage)"))
        .accessibilityIdentifier("category-ranking-\(item.id)")
    }

    /// 分类名称与本周期金额占比。
    private func categoryLabel(_ item: CategoryRankingItem, percentage: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(item.title)
                .font(.subheadline.weight(.medium))
            Text(percentage)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    /// 只在绘制比例时转为 Double，空分母返回零。
    private func ratio(_ amount: Decimal, to total: Decimal) -> Double {
        guard total > 0 else { return 0 }
        return min(max(NSDecimalNumber(decimal: amount / total).doubleValue, 0), 1)
    }
}

#Preview("Expense ranking") {
    CategoryRankingView(
        title: "支出排行榜",
        items: [
            .init(id: "dining", title: "餐饮", symbolName: "fork.knife", amount: 407.55),
            .init(id: "shopping", title: "购物", symbolName: "bag", amount: 500.13),
            .init(id: "entertainment", title: "娱乐", symbolName: "gamecontroller", amount: 1525.34)
        ]
    )
    .padding()
    .background(Color(uiColor: .systemGroupedBackground))
}

#Preview("Empty ranking") {
    CategoryRankingView(title: "Income ranking", items: [])
        .padding()
        .preferredColorScheme(.dark)
}
