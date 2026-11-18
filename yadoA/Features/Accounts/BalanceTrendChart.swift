import Charts
import SwiftUI

/// 余额走势折线：账户页汇总卡片、资产趋势页和账户详情共用。
///
/// 资产从零往上画，欠款取负从零往下画；零上的线用正向色、零下的用负向色，跟随「正负颜色」设置。
/// 完整走势总把零画进纵轴，并画出零线；可以点按选中某一天（点已选中的那天收起），也可以左右滑动逐日查看。
struct BalanceTrendChart: View {
    /// 走势的两种画法。
    enum Style {
        /// 带坐标轴、可点按和滑动查看的完整走势。
        case full

        /// 汇总卡片里的迷你走势：没有坐标轴和铺色，纵轴只框住线本身，不响应手势。
        case sparkline
    }

    /// 点按已选中那天附近多远算「点在它上面」：手指宽度左右，点中就收起选中。
    private static let deselectTolerance: CGFloat = 22

    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var environmentCalendar
    @AppStorage(AmountColorConvention.storageKey) private var convention: AmountColorConvention = .positiveRed

    /// 要画的走势。
    let series: BalanceTrendSeries

    /// 选中的业务日；迷你走势传 `.constant(nil)`。
    @Binding var selectedDay: Int?

    /// 画法。
    var style: Style = .full

    /// 是否正在左右滑动查看；滑动中逐日切换不震动，只在开始滑动时震一下。
    @State private var isScrubbing = false

    var body: some View {
        switch style {
        case .sparkline:
            chart(yDomain: series.fittedDomain)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .accessibilityHidden(true)
        case .full:
            chart(yDomain: series.valueDomain)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        // 网格线压到和账本横线一样淡，让走势成为唯一的重笔
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 1, lineCap: .round))
                            .foregroundStyle(Color.primary.opacity(0.12))
                        AxisValueLabel {
                            if let amount = value.as(Double.self) {
                                Text(amount.formatted(.number.notation(.compactName).locale(locale)))
                                    .font(.system(.caption2, design: .serif).monospacedDigit())
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisValueLabel(centered: false, collisionResolution: .greedy(minimumSpacing: 8)) {
                            if let date = value.as(Date.self) {
                                Text(date, format: xAxisFormat)
                                    .font(.system(.caption2, design: .serif).monospacedDigit())
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        selectionSurface(proxy: proxy, plotOrigin: proxy.plotFrame.map { geometry[$0].origin } ?? .zero)
                    }
                }
                // 点按换一天震一下；滑动时只在开始那一下震，逐日划过不震
                .appHaptic(.selection, trigger: selectedDay) { _, day in day != nil && !isScrubbing }
                .appHaptic(.selection, trigger: isScrubbing) { _, scrubbing in scrubbing }
        }
    }

    /// 折线本身：按零上、零下分段上色，完整走势在线和零之间铺一层同色。
    ///
    /// - Parameter yDomain: 纵轴范围。
    private func chart(yDomain: ClosedRange<Double>) -> some View {
        let segments = series.segments
        return Chart {
            ForEach(segments) { segment in
                segmentMarks(segment)
            }

            // 完整走势总画零线，作为资产往上、欠款往下的基准；迷你走势只在跨过零时画
            if style == .full || series.crossesZero {
                RuleMark(y: .value(amountAxisTitle, 0.0))
                    .foregroundStyle(Color.primary.opacity(style == .full ? 0.35 : 0.3))
                    .lineStyle(
                        style == .full
                            ? StrokeStyle(lineWidth: 1, lineCap: .round)
                            : StrokeStyle(lineWidth: 1, lineCap: .round, dash: [3, 4])
                    )
                    .accessibilityHidden(true)
            }

            if let selected = selectedPoint {
                let value = series.plotValue(of: selected.amount).doubleValue
                RuleMark(x: .value(dateAxisTitle, selected.date))
                    .foregroundStyle(Color.primary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, lineCap: .round))
                    .accessibilityHidden(true)
                PointMark(
                    x: .value(dateAxisTitle, selected.date),
                    y: .value(amountAxisTitle, value)
                )
                .foregroundStyle(lineColor(isBelowZero: value < 0))
                .symbolSize(56)
                .accessibilityHidden(true)
            }
        }
        .chartXScale(domain: dateDomain)
        .chartYScale(domain: yDomain)
    }

    /// 一段同在零上或零下的线；完整走势再从零铺一层同色到线，离零越远越实，一眼看出是撑起还是拉低净资产。
    ///
    /// - Parameter segment: 要画的一段。
    @ChartContentBuilder
    private func segmentMarks(_ segment: BalanceTrendSegment) -> some ChartContent {
        let color = lineColor(isBelowZero: segment.isBelowZero)
        let seriesName = "\(segment.id)"
        ForEach(segment.points, id: \.date) { point in
            if style == .full {
                AreaMark(
                    x: .value(dateAxisTitle, point.date),
                    yStart: .value(amountAxisTitle, 0.0),
                    yEnd: .value(amountAxisTitle, point.value),
                    series: .value(amountAxisTitle, seriesName)
                )
                .foregroundStyle(areaFill(color, isBelowZero: segment.isBelowZero))
                .accessibilityHidden(true)
            }

            LineMark(
                x: .value(dateAxisTitle, point.date),
                y: .value(amountAxisTitle, point.value),
                series: .value(amountAxisTitle, seriesName)
            )
            .foregroundStyle(color)
            .lineStyle(StrokeStyle(lineWidth: style == .full ? 2 : 1.5, lineCap: .round, lineJoin: .round))
            .accessibilityLabel(BalanceTrendFormatting.date(point.date, locale: locale, calendar: environmentCalendar))
            .accessibilityValue(point.amount?.formattedCurrency(locale: locale) ?? "")
            // 跨零处补的点不是某一天，不播报
            .accessibilityHidden(point.amount == nil)
        }
    }

    /// 盖在完整走势上的透明手势层：点按选中或收起某一天，左右滑动逐日查看。
    ///
    /// - Parameters:
    ///   - proxy: 图表坐标换算。
    ///   - plotOrigin: 绘图区左上角在手势层里的位置；手势位置减去它才是绘图区里的位置。
    private func selectionSurface(proxy: ChartProxy, plotOrigin: CGPoint) -> some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture().onEnded { value in
                    toggleSelection(atPlotX: value.location.x - plotOrigin.x, proxy: proxy)
                }
            )
            .gesture(
                HorizontalScrubGesture(
                    onChanged: { location in
                        if !isScrubbing { isScrubbing = true }
                        select(atPlotX: location.x - plotOrigin.x, proxy: proxy)
                    },
                    // 松手后停在最后看的那天，金额留在上方方便细看；点一下那天收起
                    onEnded: { isScrubbing = false }
                )
            )
    }

    /// 当前选中的点；选中的业务日已不在走势里时为 `nil`。
    private var selectedPoint: BalanceTrendPoint? {
        guard let selectedDay else { return nil }
        return series.points.first { $0.day == selectedDay }
    }

    /// 点按：点在已选中那天上收起选中，点别处换成离点按处最近的一天。
    ///
    /// - Parameters:
    ///   - x: 点按处在绘图区里的横坐标。
    ///   - proxy: 图表坐标换算。
    private func toggleSelection(atPlotX x: CGFloat, proxy: ChartProxy) {
        if let selected = selectedPoint,
           let selectedX = proxy.position(forX: selected.date),
           abs(selectedX - x) <= Self.deselectTolerance {
            selectedDay = nil
            return
        }
        select(atPlotX: x, proxy: proxy)
    }

    /// 选中横坐标处最近的一天；手指滑出绘图区两端时停在第一天或最后一天。
    ///
    /// - Parameters:
    ///   - x: 在绘图区里的横坐标。
    ///   - proxy: 图表坐标换算。
    private func select(atPlotX x: CGFloat, proxy: ChartProxy) {
        let clampedX = min(max(x, 0), proxy.plotSize.width)
        guard let date = proxy.value(atX: clampedX, as: Date.self),
              let point = series.point(nearest: date),
              point.day != selectedDay
        else { return }
        selectedDay = point.day
    }

    /// 横轴从第一天到最后一天，不在两端留空。
    private var dateDomain: ClosedRange<Date> {
        guard let first = series.points.first?.date, let last = series.points.last?.date, first < last else {
            let now = Date.now
            return now...now.addingTimeInterval(86_400)
        }
        return first...last
    }

    /// 横轴日期的写法：三四个月内写到日，一年左右只写月，更长写年和月。
    private var xAxisFormat: Date.FormatStyle {
        let calendar = TransactionDay.gregorianCalendar(basedOn: environmentCalendar, locale: locale)
        let format = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let span = dateDomain.upperBound.timeIntervalSince(dateDomain.lowerBound) / 86_400
        if span <= 120 {
            return format.month(.defaultDigits).day()
        }
        if span <= 400 {
            return format.month(.abbreviated)
        }
        return format.year().month(.defaultDigits)
    }

    /// 线的颜色：零上用正向色，零下用负向色。
    ///
    /// - Parameter isBelowZero: 是否在零下方。
    private func lineColor(isBelowZero: Bool) -> Color {
        convention.color(for: isBelowZero ? .negative : .positive) ?? Color.accentColor
    }

    /// 线和零之间的铺色：离零越远越实，零上一段上实下虚，零下一段反过来。
    ///
    /// - Parameters:
    ///   - color: 这一段线的颜色。
    ///   - isBelowZero: 是否在零下方。
    private func areaFill(_ color: Color, isBelowZero: Bool) -> LinearGradient {
        let strong = color.opacity(0.18)
        let faint = color.opacity(0.02)
        return LinearGradient(
            colors: isBelowZero ? [faint, strong] : [strong, faint],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// 横轴的无障碍名称。
    private var dateAxisTitle: String {
        AccountLocalization.string("account.trend.axis.date", locale: locale)
    }

    /// 纵轴的无障碍名称。
    private var amountAxisTitle: String {
        AccountLocalization.string("account.trend.axis.amount", locale: locale)
    }
}

/// 走势卡片的上半部分加折线：左上写金额，右上可放范围切换，下面是走势。
///
/// 没选中时金额是最后一天的，下面一行写「较某天」的变化；点按或滑动选中某天后，金额和日期换成那一天的。
struct BalanceTrendPanel<Accessory: View>: View {
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    /// 金额上方的小标题，例如「净资产」「余额」「欠款」。
    let title: String

    /// 要展示的走势。
    let series: BalanceTrendSeries

    /// 折线区域的高度。
    var chartHeight: CGFloat = 180

    /// 标题右侧的附加内容，例如范围切换。
    @ViewBuilder var accessory: () -> Accessory

    /// 选中的业务日。
    @State private var selectedDay: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                header
                    .frame(maxWidth: .infinity, alignment: .leading)
                accessory()
            }

            BalanceTrendChart(series: series, selectedDay: $selectedDay)
                .frame(height: chartHeight)
                .accessibilityIdentifier("balance-trend-chart")
        }
        // 换了范围或金额种类后旧的选中日可能不在新走势里，统一清掉
        .onChange(of: series) { _, _ in
            selectedDay = nil
        }
    }

    /// 金额与变化说明。
    private var header: some View {
        let selected = selectedDay.flatMap { day in series.points.first { $0.day == day } }
        let shown = selected ?? series.points.last
        let amount = shown?.amount ?? .zero

        return VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(amount.formattedCurrency(locale: locale))
                .font(.system(.title, design: .serif, weight: .medium).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .amountTone(series.amountTone(for: amount))
                .contentTransition(.numericText())

            if let selected {
                Text(BalanceTrendFormatting.date(selected.date, locale: locale, calendar: calendar))
                    .font(.system(.footnote, design: .serif).monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if let first = series.points.first, series.canDraw {
                BalanceTrendChangeLine(series: series, since: first.date)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("balance-trend-header")
    }
}

extension BalanceTrendPanel where Accessory == EmptyView {
    /// 不带附加内容的走势卡片。
    ///
    /// - Parameters:
    ///   - title: 金额上方的小标题。
    ///   - series: 要展示的走势。
    ///   - chartHeight: 折线区域的高度。
    init(title: String, series: BalanceTrendSeries, chartHeight: CGFloat = 180) {
        self.init(title: title, series: series, chartHeight: chartHeight) { EmptyView() }
    }
}

/// 「较 2026/8/17 +¥1,234.00」：起点日期加带符号的变化，变化按对净资产的好坏上色。
struct BalanceTrendChangeLine: View {
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    /// 走势；变化取它的第一点到最后一点。
    let series: BalanceTrendSeries

    /// 起点日期。
    let since: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Self.sinceText(since, locale: locale, calendar: calendar))
                .foregroundStyle(.secondary)

            Text(Self.changeText(series, locale: locale))
                .amountTone(series.tone(forChange: series.change))
        }
        .font(.system(.footnote, design: .serif).monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    /// 「较 2026/8/17」。
    ///
    /// - Parameters:
    ///   - since: 起点日期。
    ///   - locale: 语言环境。
    ///   - calendar: 提供时区的日历。
    static func sinceText(_ since: Date, locale: Locale, calendar: Calendar) -> String {
        AccountLocalization.formatted(
            "account.trend.since_format",
            value: BalanceTrendFormatting.date(since, locale: locale, calendar: calendar),
            locale: locale
        )
    }

    /// 带符号的变化金额，例如「+¥1,234.00」。
    ///
    /// - Parameters:
    ///   - series: 走势；变化取第一点到最后一点。
    ///   - locale: 语言环境。
    static func changeText(_ series: BalanceTrendSeries, locale: Locale) -> String {
        AccountTransactionHistoryPresentation.formattedSignedCurrency(
            series.change,
            code: BookkeepingCurrency.code,
            locale: locale
        )
    }
}

/// 余额走势里的日期写法：与流水列表一致的数字短日期。
enum BalanceTrendFormatting {
    /// 把走势上的日期写成当前语言环境的短日期。
    ///
    /// - Parameters:
    ///   - date: 业务日零点。
    ///   - locale: 语言环境。
    ///   - calendar: 提供时区的日历，内部统一换成公历。
    static func date(_ date: Date, locale: Locale, calendar: Calendar) -> String {
        BookkeepingDateFormatting.shortDate(
            date,
            locale: locale,
            calendar: TransactionDay.gregorianCalendar(basedOn: calendar, locale: locale)
        )
    }
}

/// 三个月、一年、全部的范围切换，资产趋势页和账户详情共用。
struct BalanceTrendRangePicker: View {
    @Environment(\.locale) private var locale

    /// 当前选中的范围。
    @Binding var selection: BalanceTrendRange

    /// 自动化标识前缀。
    let identifier: String

    var body: some View {
        LedgerSwitch(
            label: AccountLocalization.string("account.trend.range.accessibility", locale: locale),
            selection: $selection,
            options: BalanceTrendRange.allCases.map {
                .init(
                    value: $0,
                    title: $0.title(locale: locale),
                    identifier: "\(identifier)-\($0.rawValue)"
                )
            },
            size: .compact
        )
    }
}
