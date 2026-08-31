import Foundation
import SwiftData

/// 图表页支持的时间聚合周期。
enum ChartPeriod: String, CaseIterable, Identifiable, Hashable {
    /// 按自然周查看每日支出。
    case week

    /// 按自然月查看每日支出。
    case month

    /// 按自然年查看每月支出。
    case year

    /// 分段选择器使用的稳定标识。
    var id: Self { self }

    /// 周、月、年标题对应的稳定本地化键。
    var titleLocalizationKey: String {
        "chart.period.\(rawValue)"
    }

    /// 当前周期下图表标题对应的稳定本地化键。
    var chartTitleLocalizationKey: String {
        switch self {
        case .week, .month:
            "chart.daily.title"
        case .year:
            "chart.monthly.title"
        }
    }

    /// 日历移动和区间计算使用的组件。
    var calendarComponent: Calendar.Component {
        switch self {
        case .week:
            .weekOfYear
        case .month:
            .month
        case .year:
            .year
        }
    }

    /// 当前语言环境下的周期标题。
    func title(locale: Locale = .current) -> String {
        AccountLocalization.string(titleLocalizationKey, locale: locale)
    }
}

/// 图表页单个时间桶的支出展示数据。
struct ChartPointPresentation: Identifiable, Equatable {
    /// 日使用 `YYYYMMDD`、月使用 `YYYYMM` 的稳定时间桶标识。
    let bucketValue: Int

    /// 当前语言环境下的横轴标题。
    let formattedLabel: String

    /// 当前时间桶内有效支出的精确金额。
    let expenseTotal: Decimal

    /// 当前语言环境下的货币金额，用于辅助功能播报。
    let formattedExpense: String

    /// 图表点使用的稳定标识。
    var id: Int { bucketValue }
}

/// 图表页当前周期的纯展示投影。
struct ChartOverviewPresentation: Equatable {
    /// 只读取图表需要的支出；聚合不依赖持久化排序。
    static func descriptor() -> FetchDescriptor<AccountTransaction> {
        let expenseType = AccountTransactionType.expense.rawValue
        return FetchDescriptor(
            predicate: #Predicate<AccountTransaction> { transaction in
                transaction.typeRawValue == expenseType
            }
        )
    }

    /// 当前使用的周、月或年周期。
    let period: ChartPeriod

    /// 当前周期定位使用的日期。
    let anchorDate: Date

    /// 当前语言环境下的周期范围标题。
    let formattedPeriod: String

    /// 当前周期有效支出的精确总额。
    let totalExpense: Decimal

    /// 当前周期有效支出流水的数量。
    let transactionCount: Int

    /// 按时间正序排列的图表点。
    let points: [ChartPointPresentation]

    /// 月视图横轴只展示首日、从首日起每隔五天和末日，避免整月标签相互重叠。
    var monthlyXAxisLabelValues: [String] {
        guard period == .month,
              let firstPoint = points.first,
              let lastPoint = points.last
        else {
            return []
        }

        let firstDay = firstPoint.bucketValue % 100
        return points.compactMap { point in
            let day = point.bucketValue % 100
            guard point.id == lastPoint.id
                    || (day - firstDay).isMultiple(of: 5)
            else {
                return nil
            }
            return point.formattedLabel
        }
    }

    /// 从原始账户流水生成周、月或年的支出展示数据。
    ///
    /// 只有通过 `validatedPayload()` 校验的支出会进入图表；余额调整、
    /// 未知类型、损坏字段和无效业务日都会被安全排除。
    ///
    /// - Parameters:
    ///   - period: 当前周、月或年周期。
    ///   - anchorDate: 定位当前周期的日期；为空时根据真实支出自动选择。
    ///   - transactions: 跨账户查询得到的原始流水。
    ///   - now: 没有显式锚点时用于选择初始周期的当前日期。
    ///   - calendar: 提供时区和周起始规则的日历。
    ///   - locale: 用于周期、横轴和金额展示的语言环境。
    init(
        period: ChartPeriod,
        anchorDate: Date? = nil,
        transactions: [AccountTransaction],
        now: Date = .now,
        calendar sourceCalendar: Calendar = .current,
        locale: Locale = .current
    ) {
        let calendar = Self.chartCalendar(
            basedOn: sourceCalendar,
            locale: locale
        )
        let validExpenses = transactions.compactMap {
            Self.validExpense(for: $0, calendar: calendar, locale: locale)
        }
        let resolvedAnchorDate = anchorDate ?? Self.initialAnchorDate(
            dates: validExpenses.map(\.date),
            now: now,
            calendar: calendar
        )
        let interval = Self.interval(
            for: period,
            containing: resolvedAnchorDate,
            calendar: calendar
        )
        let periodExpenses = validExpenses.filter { expense in
            expense.date >= interval.start && expense.date < interval.end
        }
        let groupedExpenses = Dictionary(grouping: periodExpenses) { expense in
            Self.bucketStart(for: expense.date, period: period, calendar: calendar)
        }
        let bucketDates = Self.bucketDates(
            for: period,
            interval: interval,
            calendar: calendar
        )

        self.period = period
        self.anchorDate = resolvedAnchorDate
        self.formattedPeriod = Self.formattedPeriod(
            interval,
            period: period,
            locale: locale,
            calendar: calendar
        )
        self.totalExpense = periodExpenses.reduce(into: Decimal.zero) { total, expense in
            total += expense.amount
        }
        self.transactionCount = periodExpenses.count
        let pointFormatter = Self.pointFormatter(
            for: period,
            locale: locale,
            calendar: calendar
        )
        self.points = bucketDates.map { bucketDate in
            let expenseTotal = groupedExpenses[bucketDate, default: []].reduce(
                into: Decimal.zero
            ) { total, expense in
                total += expense.amount
            }
            return ChartPointPresentation(
                bucketValue: Self.bucketValue(
                    for: bucketDate,
                    period: period,
                    calendar: calendar
                ),
                formattedLabel: pointFormatter.string(from: bucketDate),
                expenseTotal: expenseTotal,
                formattedExpense: expenseTotal.formatted(
                    .currency(code: "CNY").locale(locale)
                )
            )
        }
    }

    /// 根据真实支出选择首次进入图表时的日期锚点。
    ///
    /// 当前月有数据时保留当前日期；否则优先最近历史支出，再选择最早未来支出，
    /// 完全没有有效支出时仍使用当前日期。
    static func initialAnchorDate(
        transactions: [AccountTransaction],
        now: Date = .now,
        calendar sourceCalendar: Calendar = .current,
        locale: Locale = .current
    ) -> Date {
        let calendar = chartCalendar(basedOn: sourceCalendar, locale: locale)
        let dates = transactions.compactMap {
            validExpense(for: $0, calendar: calendar, locale: locale)?.date
        }
        return initialAnchorDate(dates: dates, now: now, calendar: calendar)
    }

    /// 从已校验支出选择首次进入图表时的日期锚点。
    private static func initialAnchorDate(
        dates: [Date],
        now: Date,
        calendar: Calendar
    ) -> Date {
        let currentMonth = interval(for: .month, containing: now, calendar: calendar)

        if dates.contains(where: { $0 >= currentMonth.start && $0 < currentMonth.end }) {
            return now
        }
        if let previousDate = dates.filter({ $0 < currentMonth.start }).max() {
            return previousDate
        }
        return dates.filter({ $0 >= currentMonth.end }).min() ?? now
    }

    /// 按当前周期向前或向后移动日期锚点。
    ///
    /// - Parameters:
    ///   - anchorDate: 当前周期定位日期。
    ///   - period: 当前周、月或年周期。
    ///   - value: 移动数量，负数向前、正数向后。
    ///   - calendar: 提供时区和周起始规则的日历。
    /// - Returns: 移动后的日期；日历无法表示时返回 `nil`。
    static func shiftedAnchorDate(
        _ anchorDate: Date,
        period: ChartPeriod,
        by value: Int,
        calendar sourceCalendar: Calendar
    ) -> Date? {
        let calendar = chartCalendar(basedOn: sourceCalendar, locale: sourceCalendar.locale)
        return calendar.date(
            byAdding: period.calendarComponent,
            value: value,
            to: anchorDate
        )
    }

    /// 已完成有效日期和载荷解码的支出。
    private struct ValidExpense {
        /// 当前时区下的业务日日期。
        let date: Date

        /// 经领域模型确认的精确支出金额。
        let amount: Decimal
    }

    /// 保留来源日历的时区与周规则，并统一使用公历。
    private static func chartCalendar(
        basedOn sourceCalendar: Calendar,
        locale: Locale?
    ) -> Calendar {
        var calendar = TransactionDay.gregorianCalendar(
            basedOn: sourceCalendar,
            locale: locale
        )
        calendar.firstWeekday = sourceCalendar.firstWeekday
        calendar.minimumDaysInFirstWeek = sourceCalendar.minimumDaysInFirstWeek
        return calendar
    }

    /// 严格解码单笔真实支出。
    private static func validExpense(
        for transaction: AccountTransaction,
        calendar: Calendar,
        locale: Locale
    ) -> ValidExpense? {
        guard let date = TransactionDay.date(
            from: transaction.transactionDay,
            calendar: calendar,
            locale: locale
        ),
        let payload = try? transaction.validatedPayload(),
        case let .expense(_, amount) = payload
        else {
            return nil
        }
        return ValidExpense(date: date, amount: amount)
    }

    /// 返回日期所在周、月或年的半开区间。
    private static func interval(
        for period: ChartPeriod,
        containing date: Date,
        calendar: Calendar
    ) -> DateInterval {
        calendar.dateInterval(of: period.calendarComponent, for: date)
            ?? DateInterval(
                start: calendar.startOfDay(for: date),
                duration: 24 * 60 * 60
            )
    }

    /// 返回支出在当前周期下所属的日或月起点。
    private static func bucketStart(
        for date: Date,
        period: ChartPeriod,
        calendar: Calendar
    ) -> Date {
        switch period {
        case .week, .month:
            calendar.startOfDay(for: date)
        case .year:
            calendar.dateInterval(of: .month, for: date)?.start
                ?? calendar.startOfDay(for: date)
        }
    }

    /// 生成当前周期实际需要绘制的时间桶。
    private static func bucketDates(
        for period: ChartPeriod,
        interval: DateInterval,
        calendar: Calendar
    ) -> [Date] {
        switch period {
        case .week, .month:
            dates(in: interval, advancing: .day, calendar: calendar)
        case .year:
            dates(in: interval, advancing: .month, calendar: calendar)
        }
    }

    /// 从区间起点按指定日历组件生成有序时间桶。
    private static func dates(
        in interval: DateInterval,
        advancing component: Calendar.Component,
        calendar: Calendar
    ) -> [Date] {
        var result: [Date] = []
        var date = interval.start
        while date < interval.end {
            result.append(date)
            guard let nextDate = calendar.date(
                byAdding: component,
                value: 1,
                to: date
            ), nextDate > date else {
                break
            }
            date = nextDate
        }
        return result
    }

    /// 生成日或月时间桶的稳定整数标识。
    private static func bucketValue(
        for date: Date,
        period: ChartPeriod,
        calendar: Calendar
    ) -> Int {
        switch period {
        case .week, .month:
            return TransactionDay.encode(date, calendar: calendar)
        case .year:
            let components = calendar.dateComponents([.year, .month], from: date)
            return (components.year ?? 1970) * 100 + (components.month ?? 1)
        }
    }

    /// 本地化当前周范围、月份或年份标题。
    private static func formattedPeriod(
        _ interval: DateInterval,
        period: ChartPeriod,
        locale: Locale,
        calendar: Calendar
    ) -> String {
        switch period {
        case .week:
            let formatter = DateIntervalFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            let inclusiveEnd = calendar.date(
                byAdding: .day,
                value: -1,
                to: interval.end
            ) ?? interval.end
            return formatter.string(from: interval.start, to: inclusiveEnd)
        case .month:
            return formattedDate(
                interval.start,
                template: "MMMM yyyy",
                locale: locale,
                calendar: calendar
            )
        case .year:
            return formattedDate(
                interval.start,
                template: "yyyy",
                locale: locale,
                calendar: calendar
            )
        }
    }

    /// 创建单次投影内复用的横轴日期格式器。
    private static func pointFormatter(
        for period: ChartPeriod,
        locale: Locale,
        calendar: Calendar
    ) -> DateFormatter {
        let template: String
        switch period {
        case .week:
            template = "EEE"
        case .month:
            template = "d"
        case .year:
            template = "MMM"
        }
        return dateFormatter(template: template, locale: locale, calendar: calendar)
    }

    /// 使用明确日历、时区和语言环境格式化日期。
    private static func formattedDate(
        _ date: Date,
        template: String,
        locale: Locale,
        calendar: Calendar
    ) -> String {
        dateFormatter(template: template, locale: locale, calendar: calendar)
            .string(from: date)
    }

    /// 创建使用明确日历、时区和语言环境的日期格式器。
    private static func dateFormatter(
        template: String,
        locale: Locale,
        calendar: Calendar
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }
}
