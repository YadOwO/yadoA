import Foundation
import SwiftData
import SwiftUI

/// 账户列表顶部的资产汇总卡片，突出净资产并并列展示资产和负债；首次引导的示例也用它。
///
/// 账户页传入净资产走势时，净资产下面多一条迷你走势和「较某天」的变化；账户页上整张卡片点进资产分析页。
/// 走势不含芽豆有物物品估值；估值计入净资产时，账户页用 `trendFootnote` 在走势下面补一句说明。
struct AccountSummaryCard: View {
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    /// 用户选择的启动页面；账户页是启动页时汇总卡片才带装饰。
    @AppStorage(AppStartPage.storageKey) private var startPage: AppStartPage = .home

    let presentation: AccountSummaryPresentation

    /// 净资产近三个月的走势；为空或画不成线时不显示迷你走势，例如首次引导的示例和还没记过账时。
    var trend: BalanceTrendSeries?

    /// 卡片能点进资产分析页时为 true：显示一个向右的箭头，读屏提示点按打开；首次引导的示例不能点，保持默认 false。
    var showsDisclosure = false

    /// 迷你走势下面的一句说明，例如「趋势不含芽豆有物物品估值」；只在画了迷你走势时显示，读屏也会带上。
    var trendFootnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(
                        AccountLocalization.string(
                            "account.summary.net_assets",
                            locale: locale
                        )
                    )
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                    // 有迷你走势时箭头跟在「较某天」那一行后面；没有走势时放在标题这一行，提示整张卡片能点进去
                    if showsDisclosure, !showsSparkline {
                        Spacer(minLength: 8)
                        disclosureChevron
                    }
                }

                Text(presentation.formattedNetAssets)
                    .font(.system(.largeTitle, design: .serif, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .amountTone(presentation.netAssetsTone)
            }

            if showsSparkline, let trend, let first = trend.points.first {
                sparkline(trend, since: first.date)
            }

            HStack(alignment: .top, spacing: 16) {
                AccountSummaryMetric(
                    title: AccountLocalization.string("account.summary.assets", locale: locale),
                    amount: presentation.formattedAssets
                )

                AccountSummaryMetric(
                    title: AccountLocalization.string(
                        "account.summary.liabilities",
                        locale: locale
                    ),
                    amount: presentation.formattedLiabilities,
                    tone: presentation.liabilitiesTone
                )
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // 框内铺纸色，启动页装饰的垫纸只从框的右下边缘露出来。
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(.paperBackground))
            HandDrawnBox(cornerRadius: 22, seed: 21)
                .stroke(
                    Color.primary.opacity(0.85),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                )
        }
        .startPageDecoration(isEnabled: startPage == .accounts, cornerRadius: 22, seed: 21)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(trendAccessibilityValue)
        .accessibilityHint(
            showsDisclosure
                ? AccountLocalization.string("account.trend.open_hint", locale: locale)
                : ""
        )
        .accessibilityIdentifier("account-list-summary-card")
    }

    /// 是否在净资产下面画迷你走势：传了走势且至少两个点。
    private var showsSparkline: Bool {
        trend?.canDraw == true
    }

    /// 向右的箭头，提示整张卡片能点进资产分析页。
    private var disclosureChevron: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
    }

    /// 迷你走势的播报：「较 2026/8/17，+¥1,234.00」；没有走势时为空。
    private var trendAccessibilityValue: String {
        guard let trend, trend.canDraw, let first = trend.points.first else { return "" }
        return [
            BalanceTrendChangeLine.sinceText(first.date, locale: locale, calendar: calendar),
            BalanceTrendChangeLine.changeText(trend, locale: locale),
            trendFootnote
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    /// 净资产下的迷你走势：一条没有坐标轴的线，下面写「较某天」的变化；能点进去时后面跟一个箭头。
    ///
    /// - Parameters:
    ///   - trend: 净资产走势。
    ///   - since: 走势的第一天。
    private func sparkline(_ trend: BalanceTrendSeries, since: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            BalanceTrendChart(series: trend, style: .sparkline)
                .frame(height: 44)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                BalanceTrendChangeLine(series: trend, since: since)
                if showsDisclosure {
                    Spacer(minLength: 8)
                    disclosureChevron
                }
            }

            if let trendFootnote {
                Text(trendFootnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 汇总卡片中资产或负债的次级金额指标。
private struct AccountSummaryMetric: View {
    let title: String
    let amount: String

    /// 金额的上色语义；资产保持墨色，有欠款的负债用负向色。
    var tone: AmountTone = .neutral

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(amount)
                .font(.system(.title3, design: .serif, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .amountTone(tone)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
