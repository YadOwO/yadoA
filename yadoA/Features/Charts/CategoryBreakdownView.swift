import Charts
import SwiftData
import SwiftUI

/// 分类统计二级页面；继承图表页筛选，并独立切换收支和周期。
struct CategoryBreakdownView: View {
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale
    @Query private var transactions: [AccountTransaction]
    @Query private var categories: [BookkeepingCategory]

    /// 当前收支类型、周期与业务日锚点。
    @State private var entryType: BookkeepingEntryType
    @State private var period: ChartPeriod
    @State private var anchorDay: Int
    /// 月份选择器的展示状态。
    @State private var isMonthPickerPresented = false

    /// 以父页面当前实际展示的筛选条件初始化，避免进入后跳到其他日期。
    init(entryType: BookkeepingEntryType, period: ChartPeriod, anchorDay: Int) {
        _entryType = State(initialValue: entryType)
        _period = State(initialValue: period)
        _anchorDay = State(initialValue: anchorDay)
        _transactions = Query(ChartOverviewPresentation.descriptor())
        _categories = Query()
    }

    var body: some View {
        let chart = ChartOverviewPresentation(
            period: period,
            entryType: entryType,
            anchorDate: TransactionDay.date(from: anchorDay, calendar: calendar, locale: locale),
            transactions: transactions,
            calendar: calendar,
            locale: locale,
            catalog: BookkeepingCategoryCatalog(categories: categories)
        )

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ChartFilterSwitches(entryType: $entryType, period: $period)
                ChartTimeSelector(
                    chart: chart,
                    onSelectPrevious: { shiftPeriod(by: -1, chart: chart) },
                    onSelectNext: { shiftPeriod(by: 1, chart: chart) },
                    onSelectMonth: { isMonthPickerPresented = true }
                )

                CategoryBreakdownCard(chart: chart)

                CategoryRankingView(
                    title: AccountLocalization.string(
                        entryType == .expense
                            ? "category.ranking.expense.title"
                            : "category.ranking.income.title",
                        locale: locale
                    ),
                    items: chart.categoryRanking
                )
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .paperPage()
        .navigationTitle(AccountLocalization.string("chart.category.title", locale: locale))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isMonthPickerPresented) {
            NavigationStack {
                HomeMonthPickerView(
                    initialMonth: HomeMonth.containing(chart.anchorDate, calendar: calendar, locale: locale),
                    onCancel: { isMonthPickerPresented = false },
                    onConfirm: { month in
                        if let date = month.firstDate(calendar: calendar) {
                            anchorDay = TransactionDay.encode(date, calendar: calendar)
                        }
                        isMonthPickerPresented = false
                    }
                )
            }
        }
    }

    /// 按当前周期移动业务日，沿用图表页的日历和时区规则。
    private func shiftPeriod(by value: Int, chart: ChartOverviewPresentation) {
        if let date = ChartOverviewPresentation.shiftedAnchorDate(
            chart.anchorDate, period: period, by: value, calendar: calendar
        ) {
            anchorDay = TransactionDay.encode(date, calendar: calendar)
        }
    }
}

/// 原生环形图和可点选的图例；完整金额同时由下方排行榜提供。
private struct CategoryBreakdownCard: View {
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    /// 与排行榜使用相同筛选条件的统计结果。
    let chart: ChartOverviewPresentation

    var body: some View {
        let breakdown = CategoryBreakdownPresentation(items: chart.categoryRanking, locale: locale)
        let totalTitle = AccountLocalization.string(chart.totalTitleLocalizationKey, locale: locale)
        VStack(alignment: .leading, spacing: 18) {
            Text(AccountLocalization.string("chart.category.share", locale: locale))
                .font(.system(.headline, design: .serif))
                .accessibilityAddTraits(.isHeader)

            if breakdown.segments.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "chart.pie")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    ShareDonutTotalLabel(
                        title: totalTitle,
                        amount: breakdown.totalAmount,
                        identifier: "category-breakdown-total"
                    )
                    Text(AccountLocalization.string("category.ranking.empty", locale: locale))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("category-breakdown-empty")
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ShareDonutBreakdown(
                    breakdown: breakdown,
                    totalTitle: totalTitle,
                    color: color(for:),
                    identifierPrefix: "category-breakdown"
                )
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            HandDrawnBox(cornerRadius: 22, seed: 9)
                .stroke(
                    Color.primary.opacity(0.85),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                )
        }
    }

    /// 固定分类映射的三色组合与分类图标共同编码，筛选或排行变化不重新分配颜色。
    /// 浅深色分别使用经过验证的色阶（见 `ChartPalette`）；合并项用语义灰色，与账本“其他”分类区分。
    private func color(for segment: CategoryRankingItem) -> Color {
        if differentiateWithoutColor || segment.id == CategoryBreakdownPresentation.remainingID {
            return ChartPalette.neutral
        }
        let slot = switch segment.id {
        case "expense.shopping", "expense.clothing", "expense.household", "expense.socialGifts",
             "income.bonus", "income.reimbursement", "income.gifts":
            1
        case "expense.entertainment", "expense.transportation", "expense.travel", "expense.pets",
             "expense.other", "income.investment", "income.refund", "income.other":
            2
        default:
            0
        }
        return ChartPalette.color(slot: slot, colorScheme: colorScheme)
    }
}

#if DEBUG
#Preview("分类统计 · 浅色") {
    NavigationStack {
        CategoryBreakdownView(
            entryType: .expense, period: .month,
            anchorDay: TransactionDay.encode(.now, calendar: .current)
        )
    }
    .modelContainer(try! HomeDesignPreviewData.makeContainer())
    .environment(\.locale, Locale(identifier: "zh-Hans"))
}

#Preview("Category breakdown · Dark") {
    NavigationStack {
        CategoryBreakdownView(
            entryType: .expense, period: .month,
            anchorDay: TransactionDay.encode(.now, calendar: .current)
        )
    }
    .modelContainer(try! HomeDesignPreviewData.makeContainer())
    .environment(\.locale, Locale(identifier: "en"))
    .preferredColorScheme(.dark)
}
#endif
