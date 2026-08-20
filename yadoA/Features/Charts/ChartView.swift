import Charts
import SwiftData
import SwiftUI

/// 图表 Tab，按周、月或年展示真实支出趋势。
struct ChartView: View {
    @Environment(\.calendar) private var environmentCalendar
    @Environment(\.locale) private var locale
    @Query private var transactions: [AccountTransaction]

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
            anchorDate: selectedAnchorDate,
            transactions: transactions,
            calendar: environmentCalendar,
            locale: locale
        )

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
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

                    ChartExpenseCard(chart: chart)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(AppTab.charts.title(locale: locale))
            .navigationBarTitleDisplayMode(.inline)
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

/// 图表页顶部的周、月、年分段选择器。
private struct ChartPeriodPicker: View {
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
private struct ChartTimeSelector: View {
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

/// 图表页顶部的周期总支出与记录数量摘要。
private struct ChartSummaryCard: View {
    @Environment(\.locale) private var locale

    /// 当前周期的完整展示投影。
    let chart: ChartOverviewPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AccountLocalization.string("chart.summary.title", locale: locale))
                .font(.headline)

            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(AccountLocalization.string("chart.summary.total", locale: locale))
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

    /// 当前周期总支出的本地化货币金额。
    private var formattedTotal: String {
        chart.totalExpense.formatted(.currency(code: "CNY").locale(locale))
    }
}

/// 图表页当前周期的支出折线图；没有支出的时间桶按零展示。
private struct ChartExpenseCard: View {
    @Environment(\.locale) private var locale

    /// 当前周期的完整展示投影。
    let chart: ChartOverviewPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                AccountLocalization.string(
                    chart.period.chartTitleLocalizationKey,
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
                        AccountLocalization.string("chart.axis.expense", locale: locale),
                        point.expenseTotal.doubleValue
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
                        AccountLocalization.string("chart.axis.expense", locale: locale),
                        point.expenseTotal.doubleValue
                    )
                )
                .foregroundStyle(Color.accentColor)
                .symbolSize(24)
                .accessibilityLabel(point.formattedLabel)
                .accessibilityValue(point.formattedExpense)
            }
            .chartYScale(domain: .automatic(includesZero: true))
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .chartXAxis {
                if chart.period == .month {
                    AxisMarks(values: chart.monthlyXAxisLabelValues) { _ in
                        AxisValueLabel()
                    }
                } else {
                    AxisMarks { _ in
                        AxisValueLabel()
                    }
                }
            }
            .frame(height: 240)
            .accessibilityIdentifier("chart-expense-\(chart.period.rawValue)")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

}

private extension Decimal {
    /// 将精确金额转换为图表绘制所需的 Double；金额本身仍以 Decimal 保存和展示。
    var doubleValue: Double {
        NSDecimalNumber(decimal: self).doubleValue
    }
}

#Preview {
    ChartView()
        .modelContainer(
            for: [Account.self, AccountTransaction.self],
            inMemory: true
        )
}
