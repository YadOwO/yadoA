import SwiftData
import SwiftUI

/// 资产分析页：从账户页的汇总卡片点进来，顶部切换「净资产 / 资产 / 负债」三个 tab。
///
/// - 净资产：净资产走势，资产负债率（负债 ÷ 资产）和一句大白话说明，一道「负债 | 净资产」的比例条。
/// - 资产、负债：这一侧的走势，按账户类型的构成环形图（只有一类时不画），按账户的排行，点一行进账户详情（物品估值那一行进估值详情）。
///
/// 与汇总卡片同一口径：只算启用中的账户，未知类型按资产算；计入净资产的芽豆有物物品估值作为一项额外的资产，
/// 进资产合计、构成和排行，走势不含它，走势卡片下面有一句说明。走势用 `BalanceHistoryStore` 汇总好的材料，
/// 构成和排行按各账户当前余额算，这一页都不读流水。
struct AssetAnalysisView: View {
    @Environment(\.locale) private var locale
    @Environment(\.ledgerCurrencyCode) private var currencyCode
    @Environment(\.calendar) private var calendar
    @Query private var accounts: [Account]
    /// 各账户每天余额变化的缓存。
    @Environment(BalanceHistoryStore.self) private var balanceHistory
    /// 数据联动状态：计入净资产的物品估值；预览中没有注入时为 nil。
    @Environment(DataLinkStore.self) private var dataLinks: DataLinkStore?

    /// 当前看的 tab，默认净资产。
    @State private var tab: NetWorthTrendMetric = .netAssets

    /// 走势的时间范围，默认最近三个月；三个 tab 共用。
    @State private var range: BalanceTrendRange = .threeMonths

    var body: some View {
        let activeAccounts = accounts.filter(\.isActive)
        let itemValuation = dataLinks?.netWorthValuation
        let analysis = AssetAnalysisPresentation(
            accounts: activeAccounts,
            itemValuation: itemValuation,
            locale: locale,
            currencyCode: currencyCode
        )

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                tabSwitch

                trendCard(activeAccounts: activeAccounts, excludesItemValuation: itemValuation != nil)

                switch tab {
                case .netAssets:
                    DebtRatioCard(analysis: analysis)
                case .assets, .liabilities:
                    let composition = analysis.composition(for: tab)
                    // 只有一类时环形图就是一整圈，没有信息量，交给下面的排行
                    if composition.segments.count >= 2 {
                        AssetCompositionCard(metric: tab, composition: composition)
                    }
                    AssetRankingSection(metric: tab, rows: analysis.ranking(for: tab))
                }

                Text(AccountLocalization.string("account.trend.footnote", locale: locale))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .paperPage()
        .refreshesBalanceHistory()
        .navigationTitle(AccountLocalization.string("account.analysis.title", locale: locale))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 顶部的「净资产 / 资产 / 负债」切换。
    private var tabSwitch: some View {
        LedgerSwitch(
            label: AccountLocalization.string("account.analysis.tab.accessibility", locale: locale),
            selection: $tab,
            options: NetWorthTrendMetric.allCases.map {
                .init(
                    value: $0,
                    title: $0.title(locale: locale),
                    identifier: "asset-analysis-tab-\($0.rawValue)"
                )
            }
        )
    }

    /// 当前 tab 的走势卡片，右上角切换三个月、一年、全部。
    ///
    /// - Parameters:
    ///   - activeAccounts: 启用中的账户，走势只算它们。
    ///   - excludesItemValuation: 物品估值已计入资产合计时为 true：走势不含它，卡片底部补一句说明。
    private func trendCard(activeAccounts: [Account], excludesItemValuation: Bool) -> some View {
        let ledgers = balanceHistory.ledgers
        let history = AccountBalanceHistory(
            ledgers: ledgers ?? [:],
            accountIDs: Set(activeAccounts.map(\.id)),
            calendar: calendar
        )
        let series = history.netWorthSeries(tab, range: range)

        return VStack(alignment: .leading, spacing: 14) {
            if ledgers == nil {
                // 第一次汇总流水还没完成：先占住图表的位置，不闪出「记录不够」的说明
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else if series.canDraw {
                BalanceTrendPanel(title: tab.title(locale: locale), series: series, chartHeight: 200) {
                    BalanceTrendRangePicker(selection: $range, identifier: "asset-analysis-trend-range")
                }
            } else {
                // 账户都是今天才建的：还画不出线，说明一下什么时候会有
                Text(AccountLocalization.string("account.trend.not_enough", locale: locale))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("asset-analysis-trend-not-enough")
            }

            if excludesItemValuation {
                Text(AccountLocalization.string("dataLink.trend.excludes_item_value", locale: locale))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("asset-analysis-trend-excludes-item-value")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .analysisCardBorder(seed: 41)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("asset-analysis-trend")
    }
}

// MARK: - 资产负债率

/// 净资产 tab 的资产负债率卡片：大字写比率，下面一道「负债 | 净资产」的比例条和图例，再配一句大白话。
///
/// 资产不为正时比率没有意义，写成「—」，也不画比例条。说明只陈述事实，不评价好坏。
private struct DebtRatioCard: View {
    @Environment(\.locale) private var locale
    @Environment(\.ledgerCurrencyCode) private var currencyCode
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    /// 当前账户的分析数据。
    let analysis: AssetAnalysisPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(AccountLocalization.string("account.analysis.debt_ratio.title", locale: locale))
                .font(.system(.headline, design: .serif))
                .accessibilityAddTraits(.isHeader)

            Text(ratioText)
                .font(.system(.largeTitle, design: .serif, weight: .medium).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .accessibilityIdentifier("asset-analysis-debt-ratio")

            if let ratio = analysis.debtRatio {
                proportionBar(liabilityFraction: min(max(ratio.doubleValue, 0), 1))
                    .accessibilityHidden(true)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { legendItems }
                VStack(alignment: .leading, spacing: 8) { legendItems }
            }

            Text(explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("asset-analysis-debt-ratio-explanation")

            Text(AccountLocalization.string("account.analysis.debt_ratio.formula", locale: locale))
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .analysisCardBorder(seed: 43)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("asset-analysis-debt-ratio-card")
    }

    /// 负债和净资产两项图例：色块只负责对上比例条，名称和金额用墨色写清楚。
    @ViewBuilder
    private var legendItems: some View {
        legendItem(
            color: liabilityColor,
            title: AccountLocalization.string("account.summary.liabilities", locale: locale),
            amount: analysis.liabilities,
            tone: analysis.liabilities > 0 ? .negative : .neutral
        )
        legendItem(
            color: netAssetsColor,
            title: AccountLocalization.string("account.summary.net_assets", locale: locale),
            amount: analysis.netAssets,
            tone: analysis.netAssets < 0 ? .negative : .neutral
        )
    }

    /// 一项图例：色块、名称、金额。
    private func legendItem(color: Color, title: String, amount: Decimal, tone: AmountTone) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(amount.formattedCurrency(locale: locale, currencyCode: currencyCode))
                .font(.system(.subheadline, design: .serif).monospacedDigit())
                .amountTone(tone)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    /// 「负债 | 净资产」比例条，两段合起来是全部资产；负债超过资产时整条都是负债。
    ///
    /// - Parameter liabilityFraction: 负债占资产的比例，已限制在 0...1。
    private func proportionBar(liabilityFraction: Double) -> some View {
        GeometryReader { geometry in
            let hasBoth = liabilityFraction > 0 && liabilityFraction < 1
            // 两段之间留 2pt 纸色缝隙；很小的一段也至少留 3pt，看得见
            let available = geometry.size.width - (hasBoth ? 2 : 0)
            let liabilityWidth = liabilityFraction > 0 ? max(available * liabilityFraction, 3) : 0
            HStack(spacing: hasBoth ? 2 : 0) {
                if liabilityFraction > 0 {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(liabilityColor)
                        .frame(width: hasBoth ? min(liabilityWidth, available - 3) : available)
                }
                if liabilityFraction < 1 {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(netAssetsColor)
                }
            }
        }
        .frame(height: 12)
    }

    /// 比例条和图例里负债的颜色；开启「区分时不仅仅依赖颜色」时用灰色，靠图例文字和固定的左右位置区分。
    private var liabilityColor: Color {
        differentiateWithoutColor ? ChartPalette.neutral : ChartPalette.color(slot: 1, colorScheme: colorScheme)
    }

    /// 比例条和图例里净资产的颜色。
    private var netAssetsColor: Color {
        differentiateWithoutColor ? Color.primary.opacity(0.75) : ChartPalette.color(slot: 0, colorScheme: colorScheme)
    }

    /// 大字比率，例如「23.5%」；资产不为正时为「—」。
    private var ratioText: String {
        guard let ratio = analysis.debtRatio else { return "—" }
        return ratio.doubleValue.formatted(.percent.precision(.fractionLength(1)).locale(locale))
    }

    /// 比率下面的一句大白话。
    private var explanation: String {
        switch analysis.debtRatioLevel {
        case .noDebt:
            AccountLocalization.string("account.analysis.debt_ratio.none", locale: locale)
        case .negligible:
            AccountLocalization.string("account.analysis.debt_ratio.negligible", locale: locale)
        case let .partial(perHundred):
            AccountLocalization.formatted(
                "account.analysis.debt_ratio.partial_format",
                value: perHundred.formatted(.number.locale(locale)),
                locale: locale
            )
        case .exceedsAssets:
            AccountLocalization.string("account.analysis.debt_ratio.exceeds", locale: locale)
        }
    }
}

// MARK: - 构成

/// 资产或负债按账户类型的构成：环形图加可点选的图例，最多三类单独着色，其余合并成「其他」。
private struct AssetCompositionCard: View {
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    /// 资产或负债。
    let metric: NetWorthTrendMetric

    /// 这一侧按类型的构成，至少两块。
    let composition: CategoryBreakdownPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(AccountLocalization.string(
                metric == .liabilities
                    ? "account.analysis.composition.liabilities"
                    : "account.analysis.composition.assets",
                locale: locale
            ))
            .font(.system(.headline, design: .serif))
            .accessibilityAddTraits(.isHeader)

            ShareDonutBreakdown(
                breakdown: composition,
                totalTitle: metric.title(locale: locale),
                color: color(for:),
                identifierPrefix: "asset-analysis-composition"
            )
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .analysisCardBorder(seed: 45)
    }

    /// 按从大到小的位置取色：前三位用分类配色，合并的「其他」用灰色；扇区上的图标和图例文字一起区分类型。
    private func color(for segment: CategoryRankingItem) -> Color {
        guard !differentiateWithoutColor,
              segment.id != CategoryBreakdownPresentation.remainingID,
              let index = composition.segments.firstIndex(where: { $0.id == segment.id })
        else { return ChartPalette.neutral }
        return ChartPalette.color(slot: index, colorScheme: colorScheme)
    }
}

// MARK: - 排行

/// 资产或负债按账户的排行，与图表页的分类排行同一种写法：直接写在纸面上，每行一道比例线；点一行进账户详情，物品估值那一行进估值详情。
private struct AssetRankingSection: View {
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 资产或负债。
    let metric: NetWorthTrendMetric

    /// 从多到少排好的账户。
    let rows: [AssetRankingRow]

    var body: some View {
        // 比例线相对第一名画，第一名满格，与分类排行一致
        let maximum = rows.first?.share ?? 0

        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Text(AccountLocalization.string(
                    metric == .liabilities
                        ? "account.analysis.ranking.liabilities"
                        : "account.analysis.ranking.assets",
                    locale: locale
                ))
                .font(.system(.headline, design: .serif))
                .accessibilityAddTraits(.isHeader)
                HandDrawnRule(seed: 47)
                    .stroke(Color.primary.opacity(0.6), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                    .frame(height: 3)
                    .accessibilityHidden(true)
            }

            if rows.isEmpty {
                Text(AccountLocalization.string(
                    metric == .liabilities
                        ? "account.analysis.ranking.empty.liabilities"
                        : "account.analysis.ranking.empty.assets",
                    locale: locale
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 64)
                .accessibilityIdentifier("asset-analysis-ranking-empty")
            } else {
                ForEach(rows) { row in
                    NavigationLink(value: row.destination) {
                        rankingRow(row, maximum: maximum)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("asset-analysis-ranking-\(row.id.uuidString)")
                }
            }
        }
        .padding(.horizontal, 2)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 一行账户：图标、名称和占比、金额，下面是类型与尾号和比例线；大字号下金额移到下一行。
    ///
    /// - Parameters:
    ///   - item: 这一行的账户。
    ///   - maximum: 第一名的占比，比例线相对它画。
    private func rankingRow(_ item: AssetRankingRow, maximum: Double) -> some View {
        let percentage = item.share?.formatted(.percent.precision(.fractionLength(1)).locale(locale))

        return HStack(alignment: .top, spacing: 12) {
            AccountIconView(presentation: item.row.icon)

            VStack(alignment: .leading, spacing: 6) {
                if dynamicTypeSize.isAccessibilitySize {
                    nameLabel(item, percentage: percentage)
                    amountLabel(item)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            nameLabel(item, percentage: percentage)
                            Spacer(minLength: 0)
                            amountLabel(item)
                                .fixedSize()
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            nameLabel(item, percentage: percentage)
                            amountLabel(item)
                        }
                    }
                }

                Text(item.row.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // 透支、多还这类不为正的金额不算占比，不画比例线
                if let share = item.share, maximum > 0 {
                    LedgerRankingBar(value: min(share / maximum, 1), seed: item.id.handDrawnSeed)
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(item.row.name), \(item.row.detail)"))
        .accessibilityValue(Text([item.row.formattedAmount, percentage].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityHint(AccountLocalization.string(
            item.destination == .itemValuation ? "itemValuation.ranking.open_hint" : "account.analysis.ranking.open_hint",
            locale: locale
        ))
    }

    /// 账户名称和占比。
    private func nameLabel(_ item: AssetRankingRow, percentage: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(item.row.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
            if let percentage {
                Text(percentage)
                    .font(.system(.caption, design: .serif).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }

    /// 账户金额；欠款、透支用负向色，与账户列表一致。
    private func amountLabel(_ item: AssetRankingRow) -> some View {
        Text(item.row.formattedAmount)
            .font(.system(.subheadline, design: .serif).monospacedDigit())
            .amountTone(item.row.amountTone)
    }
}

// MARK: - 卡片边框

private extension View {
    /// 分析页各张卡片共用的手绘方框。
    ///
    /// - Parameter seed: 笔迹种子，同一页的几张卡片各用一个。
    func analysisCardBorder(seed: UInt64) -> some View {
        background {
            HandDrawnBox(cornerRadius: 22, seed: seed)
                .stroke(
                    Color.primary.opacity(0.85),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                )
        }
    }
}

#Preview {
    NavigationStack {
        AssetAnalysisView()
    }
    .environment(BalanceHistoryStore())
    .modelContainer(
        for: [Account.self, AccountTransaction.self, BookkeepingPreference.self],
        inMemory: true
    )
}

#if DEBUG
#Preview("Asset analysis · populated") {
    if let container = try? HomeDesignPreviewData.makeContainer() {
        NavigationStack {
            AssetAnalysisView()
        }
        .environment(BalanceHistoryStore())
        .modelContainer(container)
        .environment(\.locale, Locale(identifier: "zh-Hans"))
    }
}
#endif
