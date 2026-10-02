import Charts
import SwiftData
import SwiftUI

/// 图表 Tab，按周、月或年展示真实收支趋势。
struct ChartView: View {
    @Environment(\.calendar) private var environmentCalendar
    @Environment(\.locale) private var locale
    @Query private var transactions: [AccountTransaction]

    /// 当前展示的收支类型，默认支出。
    @State private var selectedEntryType: BookkeepingEntryType = .expense

    /// 当前使用的周、月或年周期，默认保持原有月视图。
    @State private var selectedPeriod: ChartPeriod = .month

    /// 当前周期定位使用的业务日编码；首次展示时由真实流水决定。
    @State private var selectedAnchorDay: Int?

    /// 月视图下是否展示月份滚轮选择器。
    @State private var isMonthPickerPresented = false

    init() {
        _transactions = Query(ChartOverviewPresentation.descriptor())
    }

    var body: some View {
        let selectedAnchorDate = selectedAnchorDay.flatMap {
            TransactionDay.date(
                from: $0,
                calendar: environmentCalendar,
                locale: locale
            )
        }
        let chart = ChartOverviewPresentation(
            period: selectedPeriod,
            entryType: selectedEntryType,
            anchorDate: selectedAnchorDate,
            transactions: transactions,
            calendar: environmentCalendar,
            locale: locale
        )

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ChartEntryTypePicker(selection: Binding(
                    get: { selectedEntryType },
                    set: { entryType in
                        // 切换收支时保留当前显示日期，便于比较同一周期。
                        selectAnchorDate(chart.anchorDate)
                        selectedEntryType = entryType
                    }
                ))

                ChartPeriodPicker(selection: $selectedPeriod)

                ChartTimeSelector(
                    chart: chart,
                    onSelectPrevious: {
                        selectAnchorDate(ChartOverviewPresentation.shiftedAnchorDate(
                            chart.anchorDate,
                            period: selectedPeriod,
                            by: -1,
                            calendar: environmentCalendar
                        ))
                    },
                    onSelectNext: {
                        selectAnchorDate(ChartOverviewPresentation.shiftedAnchorDate(
                            chart.anchorDate,
                            period: selectedPeriod,
                            by: 1,
                            calendar: environmentCalendar
                        ))
                    },
                    onSelectMonth: {
                        isMonthPickerPresented = true
                    }
                )

                ChartSummaryCard(chart: chart)

                ChartTrendCard(chart: chart)

                CategoryRankingView(
                    title: AccountLocalization.string(
                        selectedEntryType == .expense
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
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(AppTab.charts.title(locale: locale))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    CategoryBreakdownView(
                        entryType: selectedEntryType,
                        period: selectedPeriod,
                        anchorDay: TransactionDay.encode(chart.anchorDate, calendar: environmentCalendar)
                    )
                } label: {
                    Label(
                        AccountLocalization.string("chart.category.title", locale: locale),
                        systemImage: "chart.pie"
                    )
                }
                .accessibilityIdentifier("chart-category-breakdown-entry")
            }
        }
        .sheet(isPresented: $isMonthPickerPresented) {
            NavigationStack {
                HomeMonthPickerView(
                    initialMonth: activeMonth(for: chart.anchorDate),
                    onCancel: {
                        isMonthPickerPresented = false
                    },
                    onConfirm: { month in
                        selectAnchorDate(
                            month.firstDate(calendar: environmentCalendar)
                                ?? chart.anchorDate
                        )
                        isMonthPickerPresented = false
                    }
                )
            }
        }
    }

    /// 将日期转换为月份滚轮需要的有效自然年月。
    private func activeMonth(for date: Date) -> HomeMonth {
        HomeMonth.from(date: date, calendar: environmentCalendar, locale: locale)
            ?? HomeMonth(year: 1970, month: 1)!
    }

    /// 将绝对日期保存为业务日，避免运行期间切换时区后周期漂移。
    private func selectAnchorDate(_ date: Date?) {
        selectedAnchorDay = date.map {
            TransactionDay.encode($0, calendar: environmentCalendar)
        }
    }
}

/// 图表页顶部的支出、收入分段选择器。
struct ChartEntryTypePicker: View {
    @Environment(\.locale) private var locale

    /// 当前选中的收支类型。
    @Binding var selection: BookkeepingEntryType

    var body: some View {
        Picker(
            AccountLocalization.string("bookkeeping.entry.type", locale: locale),
            selection: $selection
        ) {
            ForEach(BookkeepingEntryType.allCases) { entryType in
                Text(entryType.localizedTitle(locale: locale))
                    .tag(entryType)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("chart-entry-type-picker")
    }
}

/// 图表页顶部的周、月、年分段选择器。
struct ChartPeriodPicker: View {
    @Environment(\.locale) private var locale

    /// 当前选中的图表周期。
    @Binding var selection: ChartPeriod

    var body: some View {
        Picker(
            AccountLocalization.string("chart.period.accessibility", locale: locale),
            selection: $selection
        ) {
            ForEach(ChartPeriod.allCases) { period in
                Text(period.title(locale: locale))
                    .tag(period)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("chart-period-picker")
    }
}

/// 图表时间切换控制，左右按钮按当前周、月或年移动。
struct ChartTimeSelector: View {
    @Environment(\.locale) private var locale

    /// 当前周期的完整展示投影。
    let chart: ChartOverviewPresentation

    /// 向前移动一个周期的回调。
    let onSelectPrevious: () -> Void

    /// 向后移动一个周期的回调。
    let onSelectNext: () -> Void

    /// 月视图下直接打开月份选择器的回调。
    let onSelectMonth: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSelectPrevious) {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                Text(AccountLocalization.string("chart.time.previous", locale: locale))
            )

            timeLabel

            Button(action: onSelectNext) {
                Image(systemName: "chevron.right")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                Text(AccountLocalization.string("chart.time.next", locale: locale))
            )
        }
        .foregroundStyle(.primary)
    }

    /// 月视图允许直接选择月份，周和年保持只读范围标题。
    @ViewBuilder
    private var timeLabel: some View {
        if chart.period == .month {
            Button(action: onSelectMonth) {
                HStack(spacing: 6) {
                    periodTitle
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(periodAccessibilityLabel))
            .accessibilityIdentifier("chart-time-selector")
        } else {
            periodTitle
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .accessibilityLabel(Text(periodAccessibilityLabel))
                .accessibilityIdentifier("chart-time-selector")
        }
    }

    /// 当前周范围、月份或年份标题。
    private var periodTitle: some View {
        Text(chart.formattedPeriod)
            .font(.headline)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }

    /// 当前周期标题的完整辅助功能播报文本。
    private var periodAccessibilityLabel: String {
        AccountLocalization.formatted(
            "chart.time.selector.accessibility",
            value: chart.formattedPeriod,
            locale: locale
        )
    }
}

/// 图表页顶部的周期收支总额与记录数量摘要。
private struct ChartSummaryCard: View {
    @Environment(\.locale) private var locale

    /// 当前周期的完整展示投影。
    let chart: ChartOverviewPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AccountLocalization.string(chart.summaryTitleLocalizationKey, locale: locale))
                .font(.headline)

            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(AccountLocalization.string(chart.totalTitleLocalizationKey, locale: locale))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(formattedTotal)
                        .font(.title3.weight(.semibold).monospacedDigit())
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(AccountLocalization.string("chart.summary.records", locale: locale))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(chart.transactionCount.formatted(.number.locale(locale)))
                        .font(.title3.weight(.semibold).monospacedDigit())
                }

                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chart-summary-card")
    }

    /// 当前周期收支总额的本地化货币金额。
    private var formattedTotal: String {
        chart.totalAmount.formatted(.currency(code: "CNY").locale(locale))
    }
}

/// 图表页当前周期的收支折线图；没有对应流水的时间桶按零展示。
private struct ChartTrendCard: View {
    @Environment(\.locale) private var locale

    /// 当前周期的完整展示投影。
    let chart: ChartOverviewPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                AccountLocalization.string(
                    chart.chartTitleLocalizationKey,
                    locale: locale
                )
            )
            .font(.headline)

            Chart(chart.points) { point in
                LineMark(
                    x: .value(
                        AccountLocalization.string("chart.axis.period", locale: locale),
                        point.formattedLabel
                    ),
                    y: .value(
                        chart.entryType.localizedTitle(locale: locale),
                        point.amount.doubleValue
                    )
                )
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.linear)

                PointMark(
                    x: .value(
                        AccountLocalization.string("chart.axis.period", locale: locale),
                        point.formattedLabel
                    ),
                    y: .value(
                        chart.entryType.localizedTitle(locale: locale),
                        point.amount.doubleValue
                    )
                )
                .foregroundStyle(Color.accentColor)
                .symbolSize(24)
                .accessibilityLabel(point.formattedLabel)
                .accessibilityValue(point.formattedAmount)
            }
            .chartYScale(domain: .automatic(includesZero: true))
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .chartXAxis {
                AxisMarks(values: xAxisLabelValues) { value in
                    AxisValueLabel(
                        centered: false,
                        collisionResolution: .greedy(minimumSpacing: 8)
                    ) {
                        if let label = value.as(String.self) {
                            Text(label)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                }
            }
            .frame(height: 240)
            .accessibilityIdentifier("chart-\(chart.entryType.rawValue)-\(chart.period.rawValue)")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// 月视图先减少日期刻度，其余周期由系统按实际标签宽度避让；折线仍使用全部数据点。
    private var xAxisLabelValues: [String] {
        chart.period == .month
            ? chart.monthlyXAxisLabelValues
            : chart.points.map(\.formattedLabel)
    }

}

private extension Decimal {
    /// 将精确金额转换为图表绘制所需的 Double；金额本身仍以 Decimal 保存和展示。
    var doubleValue: Double {
        NSDecimalNumber(decimal: self).doubleValue
    }
}

#Preview {
    NavigationStack {
        ChartView()
    }
    .modelContainer(
        for: [Account.self, AccountTransaction.self, BookkeepingPreference.self],
        inMemory: true
    )
}
