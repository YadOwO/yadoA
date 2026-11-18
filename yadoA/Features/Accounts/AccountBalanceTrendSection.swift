import SwiftUI

/// 账户详情里流水上方的一段走势：资产类叫「余额走势」，信用卡、负债叫「欠款走势」。
///
/// 欠款走势画的是欠了多少（正数），与详情卡片上「欠款」的写法一致；线的颜色看这段时间变好还是变坏：欠款变多用负向色。
/// 账户还没记过流水、或者只有一天的数据时整段不显示。
/// 材料来自 `BalanceHistoryStore` 的缓存，详情页要挂 `refreshesBalanceHistory()` 让它在数据变化后重算。
struct AccountBalanceTrendSection: View {
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    /// 各账户每天余额变化的缓存。
    @Environment(BalanceHistoryStore.self) private var balanceHistory

    /// 当前详情页的账户。
    let account: Account

    /// 当前的时间范围，默认最近三个月。
    @State private var range: BalanceTrendRange = .threeMonths

    var body: some View {
        let history = AccountBalanceHistory(
            ledgers: balanceHistory.ledgers ?? [:],
            accountIDs: [account.id],
            calendar: calendar
        )
        let series = history.accountSeries(account.id, range: range)

        if history.hasHistory(), series.canDraw {
            Section {
                BalanceTrendPanel(title: amountLabel, series: series, chartHeight: 150) {
                    BalanceTrendRangePicker(selection: $range, identifier: "account-detail-trend-range")
                }
                .ledgerRow(seed: 38, showsRule: false)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("account-detail-trend")
            } header: {
                Text(AccountLocalization.string(
                    series.direction == .debt ? "account.trend.title.debt" : "account.trend.title.balance",
                    locale: locale
                ))
                .font(.system(.callout, design: .serif, weight: .medium))
                // 分组标题里的 `.primary` 会被系统解析成灰色，这里指定墨色本身。
                .foregroundStyle(Color.primary)
                .accessibilityAddTraits(.isHeader)
                .ledgerHeadingRule(seed: 39)
            }
        }
    }

    /// 金额上方的小标题，与详情卡片一致：余额、欠款或金额。
    private var amountLabel: String {
        account.accountType?.amountLabel(locale: locale)
            ?? AccountLocalization.string("account.amount.value", locale: locale)
    }
}
