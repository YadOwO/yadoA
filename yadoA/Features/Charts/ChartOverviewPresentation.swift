import Foundation
import SwiftData

/// 图表页支持的时间聚合周期。
enum ChartPeriod: String, CaseIterable, Identifiable, Hashable {
    /// 按自然周查看每日收支。
    case week

    /// 按自然月查看每日收支。
    case month

    /// 按自然年查看每月收支。
    case year

    /// 分段选择器使用的稳定标识。
    var id: Self { self }

    /// 周、月、年标题对应的稳定本地化键。
    var titleLocalizationKey: String {
        "chart.period.\(rawValue)"
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

/// 图表页单个时间桶的收支展示数据。
struct ChartPointPresentation: Identifiable, Equatable {
    /// 日使用 `YYYYMMDD`、月使用 `YYYYMM` 的稳定时间桶标识。
    let bucketValue: Int

    /// 当前语言环境下的横轴标题。
    let formattedLabel: String

    /// 当前时间桶内所选类型的有效流水的精确金额。
    let amount: Decimal

    /// 当前语言环境下的货币金额，用于辅助功能播报。
    let formattedAmount: String

    /// 图表点使用的稳定标识。
    var id: Int { bucketValue }
}

/// 图表页当前周期的纯展示投影。
struct ChartOverviewPresentation: Equatable {
    /// 读取支出和收入；余额调整不参与图表统计，聚合不依赖持久化排序。
    static func descriptor() -> FetchDescriptor<AccountTransaction> {
        let expenseType = AccountTransactionType.expense.rawValue
        let incomeType = AccountTransactionType.income.rawValue
        return FetchDescriptor(
            predicate: #Predicate<AccountTransaction> { transaction in
                transaction.typeRawValue == expenseType || transaction.typeRawValue == incomeType
            }
        )
    }

    /// 当前展示的收支类型。
    let entryType: BookkeepingEntryType

    /// 当前使用的周、月或年周期。
    let period: ChartPeriod

    /// 当前周期定位使用的日期。
    let anchorDate: Date

    /// 当前语言环境下的周期范围标题。
    let formattedPeriod: String

    /// 当前周期所选类型的有效流水的精确总额。
    let totalAmount: Decimal

    /// 当前周期所选类型的有效流水的数量。
    let transactionCount: Int

    /// 按时间正序排列的图表点。
    let points: [ChartPointPresentation]

    /// 与趋势图使用同一周期、收支类型和校验规则的分类排行。
    let categoryRanking: [CategoryRankingItem]

    /// 概览卡片根据收支类型选择标题。
    var summaryTitleLocalizationKey: String {
        entryType == .expense ? "chart.summary.title" : "chart.income.summary.title"
    }

    /// 总额标签根据收支类型选择标题。
    var totalTitleLocalizationKey: String {
        entryType == .expense ? "chart.summary.total" : "chart.income.summary.total"
    }

    /// 趋势图根据收支类型和周期选择标题。
    var chartTitleLocalizationKey: String {
        switch (entryType, period) {
        case (.expense, .week), (.expense, .month): "chart.daily.title"
        case (.expense, .year): "chart.monthly.title"
        case (.income, .week), (.income, .month): "chart.income.daily.title"
        case (.income, .year): "chart.income.monthly.title"
        }
    }

    /// 月视图每隔五天显示日期并保留月末；与月末不足五天的刻度省略，避免短月份尾部拥挤。
    var monthlyXAxisLabelValues: [String] {
        guard period == .month,
              let firstPoint = points.first,
              let lastPoint = points.last
        else {
            return []
        }

        let firstDay = firstPoint.bucketValue % 100
        let lastDay = lastPoint.bucketValue % 100
        return points.compactMap { point in
            let day = point.bucketValue % 100
            guard point.id == lastPoint.id
                    || ((day - firstDay).isMultiple(of: 5) && lastDay - day >= 5)
            else {
                return nil
            }
            return point.formattedLabel
        }
    }

    /// 从原始账户流水生成周、月或年的收支展示数据。
    ///
    /// 只有通过 `validatedPayload()` 校验且匹配所选收支类型的流水会进入图表；余额调整、
    /// 未知类型、损坏字段和无效业务日都会被安全排除。
    ///
    /// - Parameters:
    ///   - period: 当前周、月或年周期。
    ///   - entryType: 要统计的收支类型，默认支出。
    ///   - anchorDate: 定位当前周期的日期；为空时根据所选类型的真实流水自动选择。
    ///   - transactions: 跨账户查询得到的原始流水。
    ///   - now: 没有显式锚点时用于选择初始周期的当前日期。
    ///   - calendar: 提供时区和周起始规则的日历。
    ///   - locale: 用于周期、横轴和金额展示的语言环境。
    init(
        period: ChartPeriod,
        entryType: BookkeepingEntryType = .expense,
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
        let validTransactions = transactions.compactMap {
            Self.validTransaction(for: $0, entryType: entryType, calendar: calendar, locale: locale)
        }
        let resolvedAnchorDate = anchorDate ?? Self.initialAnchorDate(
            dates: validTransactions.map(\.date),
            now: now,
            calendar: calendar
        )
        let interval = Self.interval(
            for: period,
            containing: resolvedAnchorDate,
            calendar: calendar
        )
        let periodTransactions = validTransactions.filter { transaction in
            transaction.date >= interval.start && transaction.date < interval.end
        }
        let groupedTransactions = Dictionary(grouping: periodTransactions) { transaction in
            Self.bucketStart(for: transaction.date, period: period, calendar: calendar)
        }
        let bucketDates = Self.bucketDates(
            for: period,
            interval: interval,
            calendar: calendar
        )

        self.entryType = entryType
        self.period = period
        self.anchorDate = resolvedAnchorDate
        self.formattedPeriod = Self.formattedPeriod(
            interval,
            period: period,
            locale: locale,
            calendar: calendar
        )
        self.totalAmount = periodTransactions.reduce(into: Decimal.zero) { total, transaction in
            total += transaction.amount
        }
        self.transactionCount = periodTransactions.count
        self.categoryRanking = Dictionary(grouping: periodTransactions, by: \.categoryID)
            .compactMap { categoryID, transactions in
                guard let first = transactions.first else { return nil }
                return CategoryRankingItem(
                    id: categoryID,
                    title: first.categoryTitle,
                    symbolName: first.categorySymbol,
                    amount: transactions.reduce(Decimal.zero) { $0 + $1.amount }
                )
            }
            .sorted {
                $0.amount == $1.amount ? $0.id < $1.id : $0.amount > $1.amount
            }
        let pointFormatter = Self.pointFormatter(
            for: period,
            locale: locale,
            calendar: calendar
        )
        self.points = bucketDates.map { bucketDate in
            let amount = groupedTransactions[bucketDate, default: []].reduce(
                into: Decimal.zero
            ) { total, transaction in
                total += transaction.amount
            }
            return ChartPointPresentation(
                bucketValue: Self.bucketValue(
                    for: bucketDate,
                    period: period,
                    calendar: calendar
                ),
                formattedLabel: pointFormatter.string(from: bucketDate),
                amount: amount,
                formattedAmount: amount.formatted(
                    .currency(code: "CNY").locale(locale)
                )
            )
        }
    }

    /// 根据所选类型的真实流水选择首次进入图表时的日期锚点。
    ///
    /// 当前月有数据时保留当前日期；否则优先最近历史流水，再选择最早未来流水，
    /// 完全没有所选类型的有效流水时仍使用当前日期。
    static func initialAnchorDate(
        transactions: [AccountTransaction],
        entryType: BookkeepingEntryType = .expense,
        now: Date = .now,
        calendar sourceCalendar: Calendar = .current,
        locale: Locale = .current
    ) -> Date {
        let calendar = chartCalendar(basedOn: sourceCalendar, locale: locale)
        let dates = transactions.compactMap {
            validTransaction(for: $0, entryType: entryType, calendar: calendar, locale: locale)?.date
        }
        return initialAnchorDate(dates: dates, now: now, calendar: calendar)
    }

    /// 从已校验流水选择首次进入图表时的日期锚点。
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

    /// 已完成有效日期和载荷解码的流水。
    private struct ValidTransaction {
        /// 当前时区下的业务日日期。
        let date: Date

        /// 经领域模型确认的精确金额。
        let amount: Decimal

        /// 含收支方向前缀的分类标识，避免两种“其他”分类冲突。
        let categoryID: String

        /// 当前语言环境下的分类名称。
        let categoryTitle: String

        /// 复用记账分类的系统图标。
        let categorySymbol: String
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

    /// 严格解码单笔所选类型的真实流水。
    private static func validTransaction(
        for transaction: AccountTransaction,
        entryType: BookkeepingEntryType,
        calendar: Calendar,
        locale: Locale
    ) -> ValidTransaction? {
        guard let date = TransactionDay.date(
            from: transaction.transactionDay,
            calendar: calendar,
            locale: locale
        ),
        let payload = try? transaction.validatedPayload()
        else {
            return nil
        }
        switch (entryType, payload) {
        case let (.expense, .expense(category, amount)):
            return ValidTransaction(
                date: date, amount: amount,
                categoryID: "expense.\(category.rawValue)",
                categoryTitle: category.localizedTitle(locale: locale),
                categorySymbol: category.symbolName
            )
        case let (.income, .income(category, amount)):
            return ValidTransaction(
                date: date, amount: amount,
                categoryID: "income.\(category.rawValue)",
                categoryTitle: category.localizedTitle(locale: locale),
                categorySymbol: category.symbolName
            )
        default:
            return nil
        }
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

    /// 返回流水在当前周期下所属的日或月起点。
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
