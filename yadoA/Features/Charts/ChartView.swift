import Charts
import Observation
import SwiftData
import SwiftUI

/// 图表 Tab，按周、月或年展示真实收支趋势。
struct ChartView: View {
    @Environment(\.calendar) private var environmentCalendar
    @Environment(\.locale) private var locale
    @Query private var transactions: [AccountTransaction]
    @Query private var categories: [BookkeepingCategory]

    /// 当前展示的收支类型，默认支出。
    @State private var selectedEntryType: BookkeepingEntryType = .expense

    /// 当前使用的周、月或年周期，默认保持原有月视图。
    @State private var selectedPeriod: ChartPeriod = .month

    /// 当前周期定位使用的业务日编码；首次展示时由真实流水决定。
    @State private var selectedAnchorDay: Int?

    /// 月视图下是否展示月份滚轮选择器。
    @State private var isMonthPickerPresented = false

    /// 账本完全没有收支时空状态里的"记一笔"操作，由根导航切到首页的记账页。
    private let onAddEntry: () -> Void

    /// - Parameter onAddEntry: 用户在空状态点击"记一笔"时的回调。
    init(onAddEntry: @escaping () -> Void = {}) {
        self.onAddEntry = onAddEntry
        _transactions = Query(ChartOverviewPresentation.descriptor())
        _categories = Query()
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
            locale: locale,
            catalog: BookkeepingCategoryCatalog(categories: categories)
        )

        Group {
            if transactions.isEmpty {
                // 账本里一笔收支都没有：筛选和空坐标轴没有意义，整页换成引导。
                ChartEmptyState(onAddEntry: onAddEntry)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ChartFilterSwitches(
                            entryType: Binding(
                                get: { selectedEntryType },
                                set: { entryType in
                                    // 切换收支时保留当前显示日期，便于比较同一周期。
                                    selectAnchorDate(chart.anchorDate)
                                    selectedEntryType = entryType
                                }
                            ),
                            period: $selectedPeriod
                        )

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

                        ChartTrendCard(chart: chart)

                        // 当前周期没有记录时趋势卡已经给出提示，不再重复一段空的分类排行。
                        if chart.transactionCount > 0 {
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
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
            }
        }
        .paperPage()
        .navigationTitle(AppTab.charts.title(locale: locale))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 空账本没有可统计的分类，分类统计入口随空状态一起隐藏。
            if !transactions.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(
                        value: ChartsRoute.categoryBreakdown(
                            entryType: selectedEntryType,
                            period: selectedPeriod,
                            anchorDay: TransactionDay.encode(chart.anchorDate, calendar: environmentCalendar)
                        )
                    ) {
                        Label(
                            AccountLocalization.string("chart.category.title", locale: locale),
                            systemImage: "chart.pie"
                        )
                    }
                    .accessibilityIdentifier("chart-category-breakdown-entry")
                }
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
        HomeMonth.containing(date, calendar: environmentCalendar, locale: locale)
    }

    /// 将绝对日期保存为业务日，避免运行期间切换时区后周期漂移。
    private func selectAnchorDate(_ date: Date?) {
        selectedAnchorDay = date.map {
            TransactionDay.encode($0, calendar: environmentCalendar)
        }
    }
}

/// 账本里还没有任何收支时的图表空状态，引导用户去记第一笔。
private struct ChartEmptyState: View {
    @Environment(\.locale) private var locale

    /// 点击"记一笔"的回调。
    let onAddEntry: () -> Void

    var body: some View {
        ContentUnavailableView {
            // 与首页、账单空状态一致的排版，图标换成手绘趋势图。
            Label {
                Text(AccountLocalization.string("chart.empty.title", locale: locale))
            } icon: {
                HandDrawnTrendIllustration()
            }
        } description: {
            Text(AccountLocalization.string("chart.empty.message", locale: locale))
        } actions: {
            Button(action: onAddEntry) {
                Label(AccountLocalization.string("expense.entry.action", locale: locale), systemImage: "plus")
            }
            .accessibilityIdentifier("chart-empty-add")
        }
        // 先声明为容器，空状态的标识才不会覆盖内部「记一笔」按钮的标识。
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chart-empty")
    }
}

/// 图表页顶部的两组切换：左边是较大的"支出 / 收入"，右边是较小的"周 / 月 / 年"。
///
/// 两组用字号区分主次并排成一行；辅助功能字号等放不下的情况改为上下两行。
struct ChartFilterSwitches: View {
    /// 当前选中的收支类型。
    @Binding var entryType: BookkeepingEntryType

    /// 当前选中的图表周期。
    @Binding var period: ChartPeriod

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                ChartEntryTypePicker(selection: $entryType)
                Spacer(minLength: 12)
                ChartPeriodPicker(selection: $period)
            }
            VStack(alignment: .leading, spacing: 0) {
                ChartEntryTypePicker(selection: $entryType)
                ChartPeriodPicker(selection: $period)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 图表页顶部的支出、收入切换。
struct ChartEntryTypePicker: View {
    @Environment(\.locale) private var locale

    /// 当前选中的收支类型。
    @Binding var selection: BookkeepingEntryType

    var body: some View {
        LedgerSwitch(
            label: AccountLocalization.string("bookkeeping.entry.type", locale: locale),
            selection: $selection,
            options: BookkeepingEntryType.ledgerSwitchOptions(
                identifier: "chart-entry-type-picker",
                locale: locale
            )
        )
    }
}

/// 图表页顶部的周、月、年切换。
struct ChartPeriodPicker: View {
    @Environment(\.locale) private var locale

    /// 当前选中的图表周期。
    @Binding var selection: ChartPeriod

    var body: some View {
        LedgerSwitch(
            label: AccountLocalization.string("chart.period.accessibility", locale: locale),
            selection: $selection,
            options: ChartPeriod.allCases.map {
                .init(
                    value: $0,
                    title: $0.title(locale: locale),
                    identifier: "chart-period-picker-\($0.rawValue)"
                )
            },
            size: .compact
        )
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
            .font(.system(.headline, design: .serif))
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

/// 趋势卡片顶部的收支摘要，突出总额，笔数作为次级信息。
///
/// 没选中时写整个周期的总额和笔数；在趋势图上点按或滑动选中某一天（年视图为某个月）后，
/// 标题换成那天的完整日期，金额和笔数换成那天的，与余额走势选中某天时换掉上方金额一致。
private struct ChartSummaryHeader: View {
    @Environment(\.locale) private var locale

    /// 当前周期的完整展示投影。
    let chart: ChartOverviewPresentation

    /// 趋势图上的选中状态；只有这里和选中层读它，选中变化时折线不重画。
    let selection: ChartTrendSelection

    var body: some View {
        let selected = chart.point(bucketValue: selection.bucketValue)
        let title = selected?.formattedDetailLabel
            ?? AccountLocalization.string(chart.totalTitleLocalizationKey, locale: locale)
        let amount = selected?.formattedAmount ?? formattedTotal
        let count = (selected?.transactionCount ?? chart.transactionCount).formatted(.number.locale(locale))
        let recordsTitle = AccountLocalization.string("chart.summary.records", locale: locale)

        // 总额在左、笔数在右写成一行，把高度留给下面的折线。
        HStack(alignment: .lastTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                // 标题和金额都压在一行内，选中前后卡片高度不变
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(amount)
                    .font(.system(.title, design: .serif, weight: .medium).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Text(recordsTitle)
                Text(count)
            }
            .font(.system(.footnote, design: .serif).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text([
            AccountLocalization.string(chart.summaryTitleLocalizationKey, locale: locale),
            title,
            amount,
            recordsTitle,
            count
        ].joined(separator: ", ")))
        .accessibilityIdentifier("chart-summary-card")
    }

    /// 当前周期收支总额的本地化货币金额。
    private var formattedTotal: String {
        chart.totalAmount.formattedCurrency(locale: locale)
    }
}

/// 将当前周期总额与收支趋势合并展示；没有对应流水的时间桶仍按零绘制。
private struct ChartTrendCard: View {
    @Environment(\.locale) private var locale

    /// 当前周期的完整展示投影。
    let chart: ChartOverviewPresentation

    /// 趋势图上选中的时间桶；这一层只把它交给摘要和选中层，自己不读，选中变化时整张卡片不用重算。
    @State private var selection = ChartTrendSelection()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ChartSummaryHeader(chart: chart, selection: selection)

            HandDrawnRule(seed: 13)
                .stroke(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                .frame(height: 3)
                .accessibilityHidden(true)

            Text(
                AccountLocalization.string(
                    chart.chartTitleLocalizationKey,
                    locale: locale
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if chart.transactionCount == 0 {
                // 当前周期没有记录：不画一张全是零的折线，保留同样的高度避免切换周期时卡片跳动。
                Text(AccountLocalization.string("category.ranking.empty", locale: locale))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 150)
                    .accessibilityIdentifier("chart-period-empty")
            } else {
                trendChart
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            HandDrawnBox(cornerRadius: 22, seed: 5)
                .stroke(
                    Color.primary.opacity(0.85),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                )
        }
        // 换了周期、时间、收支类型或流水变了以后，旧的选中点可能不在新的折线上，统一清掉。
        // 时间桶和金额都在 points 里，周期和时间变了桶就变，流水变了金额就变；
        // 收支两边金额恰好相同（例如全是零）时 points 不变，所以收支类型单独看。
        .onChange(of: chart.points) { _, _ in
            selection.bucketValue = nil
        }
        .onChange(of: chart.entryType) { _, _ in
            selection.bucketValue = nil
        }
    }

    /// 当前周期的收支折线。
    ///
    /// 折线和数据点不读选中状态；选中的竖线和圆点画在单独的一层（`ChartTrendSelectionLayer`），换一个点时只重画那一层。
    private var trendChart: some View {
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
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.linear)
            .accessibilityHidden(true)

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
            .symbolSize(16)
            // 读屏改由选中层整体播报，上下轻扫逐点查看，不再一个点一个元素
            .accessibilityHidden(true)
        }
        .chartYScale(domain: .automatic(includesZero: true))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                // 网格线压到和账本横线一样淡，让墨色折线成为唯一的重笔。
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1, lineCap: .round))
                    .foregroundStyle(Color.primary.opacity(0.12))
                AxisValueLabel()
                    .font(.system(.caption2, design: .serif).monospacedDigit())
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
                            .font(.system(.caption2, design: .serif).monospacedDigit())
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let plotFrame = proxy.plotFrame.map({ geometry[$0] }) {
                    ChartTrendSelectionLayer(
                        chart: chart,
                        proxy: proxy,
                        plotFrame: plotFrame,
                        selection: selection,
                        accessibilityTitle: AccountLocalization.string(
                            chart.chartTitleLocalizationKey,
                            locale: locale
                        )
                    )
                }
            }
        }
        // 趋势只需看出起伏，矮一些让下面的分类排行在首屏露出来。
        .frame(height: 150)
        // 图里有可调节的读屏元素，先声明为容器再加标识，避免标识盖掉里面的元素
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chart-\(chart.entryType.rawValue)-\(chart.period.rawValue)")
    }

    /// 月视图先减少日期刻度，其余周期由系统按实际标签宽度避让；折线仍使用全部数据点。
    private var xAxisLabelValues: [String] {
        chart.period == .month
            ? chart.monthlyXAxisLabelValues
            : chart.points.map(\.formattedLabel)
    }

}

/// 收支趋势图上选中的那一天（年视图为那个月）。
///
/// 放在可观察对象里而不是 `@State` 绑定：只有读了它的摘要和选中层会跟着刷新，折线本身不受影响。
@Observable
final class ChartTrendSelection {
    /// 选中的时间桶，日为 `YYYYMMDD`、月为 `YYYYMM`；没选中时为 `nil`。
    var bucketValue: Int?

    /// 是否正在左右滑动查看；滑动中逐点切换不震动。
    var isScrubbing = false
}

/// 盖在收支趋势图上的一层：画选中点的竖线和圆点，接点按、左右滑动和读屏的上下轻扫。
///
/// 手势和画法与余额走势的选中层（`BalanceTrendSelectionLayer`）一致；
/// 不同的是横轴是按标题排开的分类轴，找最近的点时比较每个点在屏幕上的横坐标。
private struct ChartTrendSelectionLayer: View {
    /// 点按已选中的点附近多远算「点在它上面」：手指宽度左右，点中就收起选中。
    private static let deselectTolerance: CGFloat = 22

    /// 当前周期的完整展示投影。
    let chart: ChartOverviewPresentation

    /// 图表坐标换算。
    let proxy: ChartProxy

    /// 绘图区在这一层里的位置和大小。
    let plotFrame: CGRect

    /// 选中状态。
    let selection: ChartTrendSelection

    /// 读屏念的图表名称，例如「每日支出」「每月收入」。
    let accessibilityTitle: String

    var body: some View {
        let selected = chart.point(bucketValue: selection.bucketValue)

        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture().onEnded { value in
                    toggleSelection(atPlotX: value.location.x - plotFrame.minX)
                }
            )
            .gesture(
                HorizontalScrubGesture(
                    onChanged: { location in
                        if !selection.isScrubbing { selection.isScrubbing = true }
                        select(atPlotX: location.x - plotFrame.minX)
                    },
                    // 松手后停在最后看的那个点，金额留在上方方便细看；点一下那个点收起
                    onEnded: { selection.isScrubbing = false }
                )
            )
            .overlay {
                if let selected {
                    marker(for: selected)
                        .allowsHitTesting(false)
                }
            }
            // 点按换一个点震一下；滑动时只在开始那一下震，逐点划过不震
            .appHaptic(.selection, trigger: selection.bucketValue) { _, bucketValue in
                bucketValue != nil && !selection.isScrubbing
            }
            .appHaptic(.selection, trigger: selection.isScrubbing) { _, isScrubbing in isScrubbing }
            // 读屏：整张图是一个可调节的元素，上下轻扫逐点查看，上方摘要跟着变
            .accessibilityElement()
            .accessibilityLabel(accessibilityTitle)
            .accessibilityValue(spokenValue(for: selected))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    selection.bucketValue = chart.point(steppingFrom: selection.bucketValue, by: 1)?.bucketValue
                case .decrement:
                    selection.bucketValue = chart.point(steppingFrom: selection.bucketValue, by: -1)?.bucketValue
                @unknown default:
                    break
                }
            }
    }

    /// 选中点的竖线和圆点，样式与余额走势相同。
    ///
    /// - Parameter point: 选中的点。
    @ViewBuilder
    private func marker(for point: ChartPointPresentation) -> some View {
        if let x = plotX(of: point), let y = proxy.position(forY: point.amount.doubleValue) {
            let center = CGPoint(x: plotFrame.minX + x, y: plotFrame.minY + y)
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: center.x, y: plotFrame.minY))
                    path.addLine(to: CGPoint(x: center.x, y: plotFrame.maxY))
                }
                .stroke(Color.primary.opacity(0.35), style: StrokeStyle(lineWidth: 1, lineCap: .round))

                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .position(center)
            }
        }
    }

    /// 点按：点在已选中的点上收起选中，点别处换成离点按处最近的点。
    ///
    /// - Parameter x: 点按处在绘图区里的横坐标。
    private func toggleSelection(atPlotX x: CGFloat) {
        let bucketValue = chart.bucketValue(
            afterTapAtX: x,
            selectedBucketValue: selection.bucketValue,
            tolerance: Self.deselectTolerance,
            position: { plotX(of: $0) }
        )
        if bucketValue != selection.bucketValue {
            selection.bucketValue = bucketValue
        }
    }

    /// 选中横坐标处最近的点；手指滑出绘图区两端时停在第一个或最后一个点。
    ///
    /// - Parameter x: 在绘图区里的横坐标。
    private func select(atPlotX x: CGFloat) {
        guard let point = chart.point(nearestX: x, position: { plotX(of: $0) }),
              point.bucketValue != selection.bucketValue
        else { return }
        selection.bucketValue = point.bucketValue
    }

    /// 某个点在绘图区里的横坐标；分类轴上是这个点所在那一格的中线。
    ///
    /// - Parameter point: 图表上的点。
    private func plotX(of point: ChartPointPresentation) -> CGFloat? {
        proxy.position(forX: point.formattedLabel)
    }

    /// 读屏念的当前值：选中时念完整日期和金额，没选中时念当前周期。
    ///
    /// - Parameter point: 选中的点；没选中时为 `nil`。
    private func spokenValue(for point: ChartPointPresentation?) -> String {
        guard let point else { return chart.formattedPeriod }
        return [point.formattedDetailLabel, point.formattedAmount].joined(separator: ", ")
    }
}

extension Decimal {
    /// 将精确金额转换为图表绘制所需的 Double；金额本身仍以 Decimal 保存和展示。收支趋势和余额走势共用。
    var doubleValue: Double {
        NSDecimalNumber(decimal: self).doubleValue
    }
}

#Preview {
    NavigationStack {
        ChartView()
            .navigationDestination(for: ChartsRoute.self) { $0.destination }
    }
    .modelContainer(
        for: [Account.self, AccountTransaction.self, BookkeepingPreference.self],
        inMemory: true
    )
}

#if DEBUG
#Preview("Spending trend · populated") {
    if let container = try? HomeDesignPreviewData.makeContainer() {
        NavigationStack {
            ChartView()
                .navigationDestination(for: ChartsRoute.self) { $0.destination }
        }
        .modelContainer(container)
        .environment(\.locale, Locale(identifier: "zh-Hans"))
    }
}
#endif
