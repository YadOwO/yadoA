import Foundation

/// 账单按月查看指定年份，或按年查看全部历史。
enum BillPeriod: String, CaseIterable, Identifiable {
    /// 指定年份内的月账单。
    case monthly
    /// 全部年份的年账单。
    case yearly

    /// 分段选择器的稳定标识。
    var id: String { rawValue }

    /// 当前模式的本地化标题。
    func title(locale: Locale) -> String {
        AccountLocalization.string("bill.period.\(rawValue)", locale: locale)
    }
}

/// 账单的精确收支汇总；结余表示收支差额，并非账户余额。
struct BillTotals: Equatable {
    /// 真实收入的正数合计。
    var income: Decimal = 0
    /// 真实支出的正数合计。
    var expense: Decimal = 0
    /// 有效流水笔数，用于区分空账单与收支相抵。
    var transactionCount = 0

    /// 当前周期的收入减去支出。
    var balance: Decimal { income - expense }

    /// 累加一个周期的收支与笔数。
    mutating func add(_ other: BillTotals) {
        income += other.income
        expense += other.expense
        transactionCount += other.transactionCount
    }
}

/// 单个月份或年份的账单行。
struct BillRowPresentation: Identifiable {
    /// 自然年月编码或自然年，保证同一列表中的标识稳定。
    let id: Int
    /// 本地化的月份或年份标题。
    let title: String
    /// 该周期的收支和结余。
    let totals: BillTotals
}

/// 跨账户账单投影，仅按业务日聚合有效收支，不依赖账户当前是否启用。
struct BillOverviewPresentation {
    /// 当前日期所在的自然年月。
    let currentMonth: HomeMonth
    /// 有流水的年份和当前年，按最新年份优先排列。
    let availableYears: [Int]
    /// 全部有效流水的累计收支。
    let total: BillTotals
    /// 月份对应的精确汇总。
    private let monthlyTotals: [HomeMonth: BillTotals]
    /// 年份对应的精确汇总。
    private let yearlyTotals: [Int: BillTotals]
    /// 标题格式化使用的公历。
    private let calendar: Calendar
    /// 单次投影内复用的月份标题格式器。
    private let monthFormatter: DateFormatter
    /// 单次投影内复用的年份标题格式器。
    private let yearFormatter: DateFormatter

    /// 单次遍历按业务年月汇总，排除余额调整、无效日期与损坏载荷。
    init(
        transactions: [AccountTransaction],
        now: Date = .now,
        calendar sourceCalendar: Calendar = .current,
        locale: Locale = .current
    ) {
        let calendar = TransactionDay.gregorianCalendar(basedOn: sourceCalendar, locale: locale)
        let currentMonth = HomeMonth.from(date: now, calendar: calendar)
            ?? HomeMonth(year: 1970, month: 1)!
        var monthly: [HomeMonth: BillTotals] = [:]
        var yearly: [Int: BillTotals] = [:]
        var total = BillTotals()
        var dayCache = TransactionDay.DateCache(calendar: calendar)

        for transaction in transactions {
            guard dayCache.date(for: transaction.transactionDay) != nil,
                  let month = HomeMonth(value: transaction.transactionDay / 100),
                  let bookkeeping = try? transaction.validatedPayload().bookkeepingAmount
            else { continue }

            let entry = switch bookkeeping.entryType {
            case .income: BillTotals(income: bookkeeping.amount, transactionCount: 1)
            case .expense: BillTotals(expense: bookkeeping.amount, transactionCount: 1)
            }
            monthly[month, default: BillTotals()].add(entry)
            yearly[month.year, default: BillTotals()].add(entry)
            total.add(entry)
        }

        self.currentMonth = currentMonth
        self.availableYears = Set(yearly.keys).union([currentMonth.year]).sorted(by: >)
        self.monthlyTotals = monthly
        self.yearlyTotals = yearly
        self.total = total
        self.calendar = calendar
        self.monthFormatter = BookkeepingDateFormatting.formatter(
            template: "MMM",
            locale: locale,
            calendar: calendar
        )
        self.yearFormatter = BookkeepingDateFormatting.formatter(
            template: "yyyy",
            locale: locale,
            calendar: calendar
        )
    }

    /// 指定年份的全年收支，空年份返回零值。
    func totals(for year: Int) -> BillTotals {
        yearlyTotals[year, default: BillTotals()]
    }

    /// 月账单倒序展示；历史年展示全年，当前年截至当前月，并保留已记录的未来月份。
    func monthlyRows(for year: Int) -> [BillRowPresentation] {
        let latestRecordedMonth = monthlyTotals.keys.filter { $0.year == year }.map(\.month).max() ?? 1
        let lastMonth = year < currentMonth.year ? 12
            : max(year == currentMonth.year ? currentMonth.month : 1, latestRecordedMonth)
        return (1...lastMonth).reversed().compactMap { number in
            guard let month = HomeMonth(year: year, month: number) else { return nil }
            return BillRowPresentation(
                id: month.value,
                title: formattedDate(year: year, month: number, formatter: monthFormatter),
                totals: monthlyTotals[month, default: BillTotals()]
            )
        }
    }

    /// 年账单直接列出全部年份，不受月账单年份筛选影响。
    var yearlyRows: [BillRowPresentation] {
        availableYears.map { year in
            BillRowPresentation(id: year, title: yearTitle(year), totals: totals(for: year))
        }
    }

    /// 不使用数字分组符的本地化公历年标题。
    func yearTitle(_ year: Int) -> String {
        formattedDate(year: year, month: 1, formatter: yearFormatter)
    }

    /// 使用统一的公历及时区格式化周期标题。
    private func formattedDate(year: Int, month: Int, formatter: DateFormatter) -> String {
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else {
            return String(year)
        }
        return formatter.string(from: date)
    }
}
