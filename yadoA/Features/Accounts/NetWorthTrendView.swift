import SwiftData
import SwiftUI

/// 资产趋势页：从账户页的汇总卡片点进来，看净资产、资产、负债逐日怎么变过来的。
///
/// 与汇总卡片同一口径：只算启用中的账户，未知类型按资产算；金额由当前余额和流水倒推，最后一天总等于汇总卡片上的数。
struct NetWorthTrendView: View {
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Query private var accounts: [Account]
    @Query private var transactions: [AccountTransaction]

    /// 当前看的金额种类，默认净资产。
    @State private var metric: NetWorthTrendMetric = .netAssets

    /// 当前的时间范围，默认最近三个月。
    @State private var range: BalanceTrendRange = .threeMonths

    var body: some View {
        let activeAccounts = accounts.filter(\.isActive)
        let history = AccountBalanceHistory(
            accounts: activeAccounts,
            transactions: transactions,
            calendar: calendar
        )
        let series = history.netWorthSeries(metric, range: range)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                filters

                VStack(alignment: .leading, spacing: 14) {
                    if series.canDraw {
                        BalanceTrendPanel(title: metric.title(locale: locale), series: series, chartHeight: 200)
                    } else {
                        // 账户都是今天才建的：还画不出线，说明一下什么时候会有
                        Text(AccountLocalization.string("account.trend.not_enough", locale: locale))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 200)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("net-worth-trend-not-enough")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    HandDrawnBox(cornerRadius: 22, seed: 41)
                        .stroke(
                            Color.primary.opacity(0.85),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                        )
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
        .navigationTitle(AccountLocalization.string("account.trend.net_worth.title", locale: locale))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 顶部两组切换：左边较大的「净资产 / 资产 / 负债」，右边较小的「三个月 / 一年 / 全部」，放不下时上下两行。
    private var filters: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                metricPicker
                Spacer(minLength: 12)
                BalanceTrendRangePicker(selection: $range, identifier: "net-worth-trend-range")
            }
            VStack(alignment: .leading, spacing: 0) {
                metricPicker
                BalanceTrendRangePicker(selection: $range, identifier: "net-worth-trend-range")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 净资产、资产、负债切换。
    private var metricPicker: some View {
        LedgerSwitch(
            label: AccountLocalization.string("account.trend.metric.accessibility", locale: locale),
            selection: $metric,
            options: NetWorthTrendMetric.allCases.map {
                .init(
                    value: $0,
                    title: $0.title(locale: locale),
                    identifier: "net-worth-trend-metric-\($0.rawValue)"
                )
            }
        )
    }
}

#Preview {
    NavigationStack {
        NetWorthTrendView()
    }
    .modelContainer(
        for: [Account.self, AccountTransaction.self, BookkeepingPreference.self],
        inMemory: true
    )
}

#if DEBUG
#Preview("Net worth trend · populated") {
    if let container = try? HomeDesignPreviewData.makeContainer() {
        NavigationStack {
            NetWorthTrendView()
        }
        .modelContainer(container)
        .environment(\.locale, Locale(identifier: "zh-Hans"))
    }
}
#endif
