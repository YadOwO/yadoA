import SwiftData
import SwiftUI

/// 导航栏中部的月份入口，点击后打开月份选择。
struct HomeMonthSelectorButton: View {
    @Environment(\.locale) private var locale

    /// 当前语言环境下的月份标题。
    let formattedMonth: String

    /// 用户点击月份入口后的回调。
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(formattedMonth)
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            Text(
                AccountLocalization.formatted(
                    "home.month.selector.accessibility",
                    value: formattedMonth,
                    locale: locale
                )
            )
        )
        .accessibilityIdentifier("home-month-selector")
    }
}

/// 首页固定头部：单行展示月度支出、收入和金额显隐控制，尽量把空间留给明细。
struct HomeOverviewHeader: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 用户选择的启动页面；记账页是启动页时汇总框才带装饰。
    @AppStorage(AppStartPage.storageKey) private var startPage: AppStartPage = .home

    /// 当前月份的已本地化展示数据。
    let monthPresentation: HomeOverviewMonthPresentation

    /// 是否展示收入和支出的实际金额。
    @Binding var areAmountsVisible: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            let summaryLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
            summaryLayout {
                HomeSummaryColumn(
                    title: AccountLocalization.string("home.summary.expense", locale: locale),
                    amount: monthPresentation.expenseTotal,
                    isVisible: areAmountsVisible,
                    isIncome: false,
                    locale: locale
                )

                HomeSummaryColumn(
                    title: AccountLocalization.string("home.summary.income", locale: locale),
                    amount: monthPresentation.incomeTotal,
                    isVisible: areAmountsVisible,
                    isIncome: true,
                    locale: locale
                )
            }

            visibilityButton
        }
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .padding(.vertical, 14)
        // 汇总不垫灰色卡片，用一笔画成的墨线框圈出来；框内铺纸色，流水从下方滑过时不会透上来。
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(.paperBackground))
            HandDrawnBox(cornerRadius: 22, seed: 7)
                .stroke(
                    Color.primary.opacity(0.85),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                )
        }
        .startPageDecoration(isEnabled: startPage == .home, cornerRadius: 22, seed: 7)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-fixed-header")
    }

    /// 金额显隐开关；只保留图标本身，点击区域保持 44pt。
    private var visibilityButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                areAmountsVisible.toggle()
            }
        } label: {
            Image(systemName: areAmountsVisible ? "eye" : "eye.slash")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            Text(
                AccountLocalization.string(
                    areAmountsVisible
                        ? "home.summary.hide"
                        : "home.summary.show",
                    locale: locale
                )
            )
        )
        .accessibilityValue(
            Text(
                AccountLocalization.string(
                    areAmountsVisible
                        ? "home.summary.visible"
                        : "home.summary.hidden",
                    locale: locale
                )
            )
        )
        .accessibilityIdentifier("home-summary-visibility")
    }
}

/// 首页顶部单个收入或支出汇总列。
private struct HomeSummaryColumn: View {
    /// 汇总标题。
    let title: String

    /// 精确的月度金额。
    let amount: Decimal

    /// 是否显示实际金额。
    let isVisible: Bool

    /// 是否为收入列，用于稳定生成自动化标识。
    let isIncome: Bool

    /// 当前语言环境。
    let locale: Locale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: isIncome ? "arrow.down.left" : "arrow.up.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(isVisible ? formattedAmount : AccountLocalization.string("home.summary.mask", locale: locale))
                // 金额用衬线数字，像账本上写下的数目。
                .font(.system(.title, design: .serif, weight: .medium).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
                .accessibilityLabel(Text(title))
                .accessibilityValue(
                    Text(
                        isVisible
                            ? formattedAmount
                            : AccountLocalization.string("home.summary.hidden", locale: locale)
                    )
                )
                .accessibilityIdentifier(isIncome ? "home-summary-income" : "home-summary-expense")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 使用应用当前固定的 CNY 货币格式化金额。
    private var formattedAmount: String {
        amount.formattedCurrency(locale: locale)
    }
}
