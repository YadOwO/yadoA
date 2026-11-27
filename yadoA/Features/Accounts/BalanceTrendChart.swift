import Charts
import Observation
import SwiftUI

/// 余额走势折线：账户页汇总卡片、资产分析页和账户详情共用，用系统的 Swift Charts 画。
///
/// 纵轴只框住线本身，起伏看得清；欠款按欠了多少（正数）画，金额有正有负时在零处画一道虚线。
/// 整条线一个颜色，与「较某天」那一行相同：资产变多、欠款变少用正向色，反过来用负向色，跟随「正负颜色」设置；没有变化时用墨色。
///
/// 为了几百个点也滑得跟手：线和铺色用 iOS 18 的 `LinePlot`、`AreaPlot` 一次画完整组数据；
/// 选中的竖线和圆点画在单独的一层（`BalanceTrendSelectionLayer`），换一天时只重画那一层，折线不动。
struct BalanceTrendChart: View {
    /// 走势的两种画法。
    enum Style {
        /// 带坐标轴、可点按和滑动查看的完整走势。
        case full

        /// 汇总卡片里的迷你走势：没有坐标轴，不响应手势。
        case sparkline
    }

    /// 画进图里的一个点：日期、金额和铺色的下沿，供 `LinePlot`、`AreaPlot` 按键路径读取。
    struct PlotPoint {
        /// 横轴日期。
        let date: Date

        /// 纵轴金额。
        let value: Double

        /// 铺色的下沿，即纵轴的下沿。
        let baseline: Double
    }

    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var environmentCalendar
    @AppStorage(AmountColorConvention.storageKey) private var convention: AmountColorConvention = .regionDefault()

    /// 要画的走势。
    let series: BalanceTrendSeries

    /// 选中状态；迷你走势不需要，传 `nil`。
    var selection: BalanceTrendSelection?

    /// 画法。
    var style: Style = .full

    /// 读屏念的图表名称，例如「净资产」「余额」。
    var accessibilityTitle = ""

    var body: some View {
        let domain = series.amountDomain
        let color = lineColor
        let chart = Chart {
            plots(domain: domain, color: color)
        }
        .chartXScale(domain: dateDomain)
        .chartYScale(domain: domain)

        switch style {
        case .sparkline:
            chart
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .accessibilityHidden(true)
        case .full:
            chart
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
                        if let selection, let plotFrame = proxy.plotFrame.map({ geometry[$0] }) {
                            BalanceTrendSelectionLayer(
                                series: series,
                                proxy: proxy,
                                plotFrame: plotFrame,
                                selection: selection,
                                color: color,
                                accessibilityTitle: accessibilityTitle
                            )
                        }
                    }
                }
        }
    }

    /// 折线、线下铺色和零线；不读选中状态，换一天时不重画。
    ///
    /// - Parameters:
    ///   - domain: 纵轴范围，铺色从它的下沿铺到线。
    ///   - color: 线的颜色。
    @ChartContentBuilder
    private func plots(domain: ClosedRange<Double>, color: Color) -> some ChartContent {
        let points = series.points.map {
            PlotPoint(date: $0.date, value: $0.amount.doubleValue, baseline: domain.lowerBound)
        }

        // 线下铺一层很淡的同色，让走势在纸面上更容易看出起伏
        AreaPlot(
            points,
            x: .value(dateAxisTitle, \.date),
            yStart: .value(amountAxisTitle, \.baseline),
            yEnd: .value(amountAxisTitle, \.value)
        )
        .foregroundStyle(
            LinearGradient(
                colors: [color.opacity(style == .full ? 0.16 : 0.12), color.opacity(0.01)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .accessibilityHidden(true)

        LinePlot(
            points,
            x: .value(dateAxisTitle, \.date),
            y: .value(amountAxisTitle, \.value)
        )
        .foregroundStyle(color)
        .lineStyle(StrokeStyle(lineWidth: style == .full ? 2 : 1.5, lineCap: .round, lineJoin: .round))
        .accessibilityHidden(true)

        if series.crossesZero {
            RuleMark(y: .value(amountAxisTitle, 0.0))
                .foregroundStyle(Color.primary.opacity(0.3))
                .lineStyle(StrokeStyle(lineWidth: 1, lineCap: .round, dash: [3, 4]))
                .accessibilityHidden(true)
        }
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

    /// 线的颜色：这段时间变好用正向色，变坏用负向色，没有变化用墨色。
    private var lineColor: Color {
        convention.color(for: series.changeTone) ?? Color.accentColor
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

/// 走势卡片里选中的那一天。
///
/// 放在可观察对象里而不是 `@State` 绑定：只有读了它的金额标题和选中层会跟着刷新，折线本身不受影响。
@Observable
final class BalanceTrendSelection {
    /// 选中的业务日；没选中时为 `nil`。
    var day: Int?

    /// 是否正在左右滑动查看；滑动中逐日切换不震动。
    var isScrubbing = false
}

/// 盖在完整走势上的一层：画选中那天的竖线和圆点，接点按、左右滑动和读屏的上下轻扫。
private struct BalanceTrendSelectionLayer: View {
    @Environment(\.ledgerCurrencyCode) private var currencyCode
    /// 点按已选中那天附近多远算「点在它上面」：手指宽度左右，点中就收起选中。
    private static let deselectTolerance: CGFloat = 22

    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    /// 当前走势。
    let series: BalanceTrendSeries

    /// 图表坐标换算。
    let proxy: ChartProxy

    /// 绘图区在这一层里的位置和大小。
    let plotFrame: CGRect

    /// 选中状态。
    let selection: BalanceTrendSelection

    /// 线的颜色，圆点用同色。
    let color: Color

    /// 读屏念的图表名称。
    let accessibilityTitle: String

    var body: some View {
        let selected = series.point(day: selection.day)

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
                    // 松手后停在最后看的那天，金额留在上方方便细看；点一下那天收起
                    onEnded: { selection.isScrubbing = false }
                )
            )
            .overlay {
                if let selected {
                    marker(for: selected)
                        .allowsHitTesting(false)
                }
            }
            // 点按换一天震一下；滑动时只在开始那一下震，逐日划过不震
            .appHaptic(.selection, trigger: selection.day) { _, day in day != nil && !selection.isScrubbing }
            .appHaptic(.selection, trigger: selection.isScrubbing) { _, isScrubbing in isScrubbing }
            // 读屏：整张图是一个可调节的元素，上下轻扫逐日查看，上方金额跟着变
            .accessibilityElement()
            .accessibilityLabel(accessibilityTitle)
            .accessibilityValue(spokenValue(for: selected ?? series.points.last))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    selection.day = series.point(steppingFrom: selection.day, by: 1)?.day
                case .decrement:
                    selection.day = series.point(steppingFrom: selection.day, by: -1)?.day
                @unknown default:
                    break
                }
            }
    }

    /// 选中那天的竖线和圆点。
    ///
    /// - Parameter point: 选中的点。
    @ViewBuilder
    private func marker(for point: BalanceTrendPoint) -> some View {
        if let x = proxy.position(forX: point.date), let y = proxy.position(forY: point.amount.doubleValue) {
            let center = CGPoint(x: plotFrame.minX + x, y: plotFrame.minY + y)
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: center.x, y: plotFrame.minY))
                    path.addLine(to: CGPoint(x: center.x, y: plotFrame.maxY))
                }
                .stroke(Color.primary.opacity(0.35), style: StrokeStyle(lineWidth: 1, lineCap: .round))

                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .position(center)
            }
        }
    }

    /// 点按：点在已选中那天上收起选中，点别处换成离点按处最近的一天。
    ///
    /// - Parameter x: 点按处在绘图区里的横坐标。
    private func toggleSelection(atPlotX x: CGFloat) {
        if let selected = series.point(day: selection.day),
           let selectedX = proxy.position(forX: selected.date),
           abs(selectedX - x) <= Self.deselectTolerance {
            selection.day = nil
            return
        }
        select(atPlotX: x)
    }

    /// 选中横坐标处最近的一天；手指滑出绘图区两端时停在第一天或最后一天。
    ///
    /// - Parameter x: 在绘图区里的横坐标。
    private func select(atPlotX x: CGFloat) {
        let clampedX = min(max(x, 0), plotFrame.width)
        guard let date = proxy.value(atX: clampedX, as: Date.self),
              let point = series.point(nearest: date),
              point.day != selection.day
        else { return }
        selection.day = point.day
    }

    /// 读屏念的当前值：日期和金额。
    ///
    /// - Parameter point: 选中的点；没选中时为最后一天。
    private func spokenValue(for point: BalanceTrendPoint?) -> String {
        guard let point else { return "" }
        return [
            BalanceTrendFormatting.date(point.date, locale: locale, calendar: calendar),
            point.amount.formattedCurrency(locale: locale, currencyCode: currencyCode)
        ].joined(separator: ", ")
    }
}

/// 走势卡片的上半部分加折线：左上写金额，右上可放范围切换，下面是走势。
///
/// 没选中时金额是最后一天的，下面一行写「较某天」的变化；点按或滑动选中某天后，金额和日期换成那一天的。
struct BalanceTrendPanel<Accessory: View>: View {
    /// 金额上方的小标题，例如「净资产」「余额」「欠款」。
    let title: String

    /// 要展示的走势。
    let series: BalanceTrendSeries

    /// 折线区域的高度。
    var chartHeight: CGFloat = 180

    /// 标题右侧的附加内容，例如范围切换。
    @ViewBuilder var accessory: () -> Accessory

    /// 选中的那一天；这一层只把它交给金额标题和折线，自己不读，选中变化时整张卡片不用重算。
    @State private var selection = BalanceTrendSelection()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                BalanceTrendHeader(title: title, series: series, selection: selection)
                    .frame(maxWidth: .infinity, alignment: .leading)
                accessory()
            }

            BalanceTrendChart(series: series, selection: selection, accessibilityTitle: title)
                .frame(height: chartHeight)
                // 图里有可调节的读屏元素，先声明为容器再加标识，避免标识盖掉里面的元素
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("balance-trend-chart")
        }
        // 换了范围或金额种类后旧的选中日可能不在新走势里，统一清掉
        .onChange(of: series) { _, _ in
            selection.day = nil
        }
    }
}

/// 走势卡片左上的金额与变化说明，选中某天时换成那天的金额和日期。
private struct BalanceTrendHeader: View {
    @Environment(\.locale) private var locale
    @Environment(\.ledgerCurrencyCode) private var currencyCode
    @Environment(\.calendar) private var calendar

    /// 金额上方的小标题。
    let title: String

    /// 当前走势。
    let series: BalanceTrendSeries

    /// 选中状态。
    let selection: BalanceTrendSelection

    var body: some View {
        let selected = series.point(day: selection.day)
        let amount = (selected ?? series.points.last)?.amount ?? .zero

        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(amount.formattedCurrency(locale: locale, currencyCode: currencyCode))
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
    @Environment(\.ledgerCurrencyCode) private var currencyCode
    @Environment(\.calendar) private var calendar

    /// 走势；变化取它的第一点到最后一点。
    let series: BalanceTrendSeries

    /// 起点日期。
    let since: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Self.sinceText(since, locale: locale, calendar: calendar))
                .foregroundStyle(.secondary)

            Text(Self.changeText(series, locale: locale, currencyCode: currencyCode))
                .amountTone(series.changeTone)
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
    ///   - currencyCode: 金额使用的账本币种。
    static func changeText(_ series: BalanceTrendSeries, locale: Locale, currencyCode: String) -> String {
        AccountTransactionHistoryPresentation.formattedSignedCurrency(
            series.change,
            code: currencyCode,
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

/// 三个月、一年、全部的范围切换，资产分析页和账户详情共用。
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
