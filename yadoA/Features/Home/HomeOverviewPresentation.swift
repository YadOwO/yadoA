import Foundation
import SwiftData

/// 首页使用的自然年月值，独立于具体流水日期和保存时间。
struct HomeMonth: Comparable, Hashable, Sendable {
    /// 自然年的四位数值。
    let year: Int

    /// 自然月，取值范围为 1 到 12。
    let month: Int

    /// 创建有效的自然年月值。
    ///
    /// - Parameters:
    ///   - year: 大于零的公历年份。
    ///   - month: 1 到 12 之间的公历月份。
    init?(year: Int, month: Int) {
        guard year > 0, (1...12).contains(month) else { return nil }
        self.year = year
        self.month = month
    }

    /// 从 `YYYYMM` 整数创建自然年月值。
    ///
    /// - Parameter value: 使用公历年月编码的整数。
    init?(value: Int) {
        self.init(year: value / 100, month: value % 100)
    }

    /// 适合持久化或测试断言的 `YYYYMM` 整数。
    var value: Int { year * 100 + month }

    /// 比较两个自然年月的先后顺序。
    static func < (lhs: HomeMonth, rhs: HomeMonth) -> Bool {
        lhs.year == rhs.year ? lhs.month < rhs.month : lhs.year < rhs.year
    }

    /// 从注入的日期和日历提取自然年月。
    ///
    /// - Parameters:
    ///   - date: 需要转换的日期。
    ///   - calendar: 提供时区的日历。
    ///   - locale: 仅用于保持日期转换的本地化语义。
    /// - Returns: 日期所在的自然年月；无法取得年月时返回 `nil`。
    static func from(
        date: Date,
        calendar sourceCalendar: Calendar,
        locale: Locale = .current
    ) -> HomeMonth? {
        let calendar = TransactionDay.gregorianCalendar(
            basedOn: sourceCalendar,
            locale: locale
        )
        let components = calendar.dateComponents([.year, .month], from: date)
        guard let year = components.year, let month = components.month else { return nil }
        return HomeMonth(year: year, month: month)
    }

    /// 返回该月份在注入日历中的第一天。
    ///
    /// - Parameter calendar: 提供时区和公历规则的日历。
    /// - Returns: 月初日期；年月无法构造时返回 `nil`。
    func firstDate(calendar sourceCalendar: Calendar) -> Date? {
        let calendar = TransactionDay.gregorianCalendar(basedOn: sourceCalendar)
        return calendar.date(from: DateComponents(year: year, month: month, day: 1))
    }

    /// 按自然月移动当前年月，不从业务日或保存时间推断月份。
    ///
    /// - Parameters:
    ///   - count: 要移动的月份数，可为负数。
    ///   - calendar: 提供时区和公历规则的日历。
    /// - Returns: 移动后的年月；无法构造日期时返回 `nil`。
    func adding(months count: Int, calendar: Calendar) -> HomeMonth? {
        guard let date = firstDate(calendar: calendar),
              let shiftedDate = calendar.date(byAdding: .month, value: count, to: date)
        else {
            return nil
        }
        return HomeMonth.from(date: shiftedDate, calendar: calendar)
    }

    /// 使用当前语言环境展示年月标题。
    ///
    /// - Parameters:
    ///   - locale: 月份标题使用的语言环境。
    ///   - calendar: 月份标题使用的公历及时区。
    /// - Returns: 本地化的年月标题；日期格式化失败时返回安全的数字形式。
    func formatted(locale: Locale, calendar sourceCalendar: Calendar) -> String {
        guard let date = firstDate(calendar: sourceCalendar) else {
            return String(format: "%04d-%02d", year, month)
        }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = TransactionDay.gregorianCalendar(
            basedOn: sourceCalendar,
            locale: locale
        )
        formatter.timeZone = sourceCalendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter.string(from: date)
    }
}

/// 首页单条真实支出流水的本地化展示数据。
struct HomeOverviewRowPresentation: Identifiable, Equatable {
    /// 流水稳定标识。
    let id: UUID

    /// 当前语言环境下的流水分类标题。
    let title: String

    /// 使用负向金额表示支出的本地化金额。
    let formattedAmount: String

    /// 当前语言环境下的公历业务日期。
    let formattedDate: String

    /// 已清理的可选备注。
    let note: String?

    /// 包含分类、金额、日期和备注的完整播报文本。
    let accessibilityLabel: String
}

/// 首页按业务日分组的明细展示数据。
struct HomeOverviewDayPresentation: Identifiable, Equatable {
    /// 分组使用的 `YYYYMMDD` 业务日。
    let transactionDay: Int

    /// 当前语言环境下的短日期。
    let formattedDate: String

    /// 当前语言环境下的星期标题。
    let formattedWeekday: String

    /// 当前分组的真实收入总额；当前数据模型固定为零。
    let incomeTotal: Decimal

    /// 当前分组的真实支出总额。
    let expenseTotal: Decimal

    /// 按稳定流水顺序排列的明细行。
    let rows: [HomeOverviewRowPresentation]

    /// 使用业务日作为 SwiftUI 分组标识。
    var id: Int { transactionDay }
}

/// 首页单个月份的收入、支出和按日明细展示数据。
struct HomeOverviewMonthPresentation: Equatable {
    /// 当前投影对应的自然年月。
    let month: HomeMonth

    /// 当前语言环境下的月份标题。
    let formattedMonth: String

    /// 当前月份的真实收入总额；当前数据模型固定为零。
    let incomeTotal: Decimal

    /// 当前月份的真实支出总额。
    let expenseTotal: Decimal

    /// 按业务日倒序排列的日期分组。
    let dayGroups: [HomeOverviewDayPresentation]

    /// 当前月份是否没有可展示的真实流水。
    var isEmpty: Bool { dayGroups.isEmpty }
}

/// 在可用真实数据月份中进行双向最近月份查找的纯导航器。
struct HomeMonthNavigator: Equatable {
    /// 去重后按自然年月升序排列的真实数据月份。
    let availableMonths: [HomeMonth]

    /// 创建一个只依赖真实数据月份集合的导航器。
    ///
    /// - Parameter availableMonths: 有真实收入或支出的月份集合。
    init(availableMonths: some Sequence<HomeMonth>) {
        self.availableMonths = Array(Set(availableMonths)).sorted()
    }

    /// 查找当前月份之前最近的有数据月份。
    ///
    /// - Parameter month: 当前选中的自然月。
    /// - Returns: 更早方向最近的有数据月份；没有匹配项时返回 `nil`。
    func earlierMonth(from month: HomeMonth) -> HomeMonth? {
        availableMonths.last(where: { $0 < month })
    }

    /// 查找当前月份之后最近的有数据月份。
    ///
    /// - Parameter month: 当前选中的自然月。
    /// - Returns: 更晚方向最近的有数据月份；没有匹配项时返回 `nil`。
    func laterMonth(from month: HomeMonth) -> HomeMonth? {
        availableMonths.first(where: { $0 > month })
    }

    /// `earlierMonth(from:)` 的语义别名，便于边界事件调用。
    ///
    /// - Parameter month: 当前选中的自然月。
    /// - Returns: 更早方向最近的有数据月份或 `nil`。
    func nearestEarlierMonth(from month: HomeMonth) -> HomeMonth? {
        earlierMonth(from: month)
    }

    /// `laterMonth(from:)` 的语义别名，便于边界事件调用。
    ///
    /// - Parameter month: 当前选中的自然月。
    /// - Returns: 更晚方向最近的有数据月份或 `nil`。
    func nearestLaterMonth(from month: HomeMonth) -> HomeMonth? {
        laterMonth(from: month)
    }
}

/// 首页跨账户流水的纯展示投影与月份浏览边界。
struct HomeOverviewPresentation {
    /// 跨账户查询所有流水，并保持首页所需的稳定排序。
    ///
    /// - Returns: 可直接提供给 SwiftData `@Query` 或查询上下文的描述符。
    static func descriptor() -> FetchDescriptor<AccountTransaction> {
        FetchDescriptor(
            sortBy: [
                SortDescriptor(\AccountTransaction.transactionDay, order: .reverse),
                SortDescriptor(\AccountTransaction.savedAt, order: .reverse),
                SortDescriptor(\AccountTransaction.id, order: .forward)
            ]
        )
    }

    /// 经过校验并按展示顺序保存的首页真实流水。
    private let validTransactions: [ValidatedTransaction]

    /// 所有包含真实收入或支出的自然月份，按年月升序排列。
    let availableMonths: [HomeMonth]

    /// 注入日期所在月份对应的初始展示月份。
    let initialMonth: HomeMonth

    /// 创建跨账户首页投影。
    ///
    /// 只有 `validatedPayload()` 成功解码出的餐饮支出才会进入首页；余额调整、
    /// 未知类型、损坏字段和无效业务日都会被安全排除。
    ///
    /// - Parameters:
    ///   - transactions: 跨账户查询得到的原始流水。
    ///   - now: 用于选择初始月份的注入日期。
    ///   - calendar: 提供时区和公历规则的日历。
    ///   - locale: 用于月份、日期、星期和行展示的语言环境。
    init(
        transactions: [AccountTransaction],
        now: Date = .now,
        calendar sourceCalendar: Calendar = .current,
        locale: Locale = .current
    ) {
        let calendar = TransactionDay.gregorianCalendar(
            basedOn: sourceCalendar,
            locale: locale
        )
        let sortedTransactions = transactions.sorted(by: Self.isOrderedBefore)
        let validTransactions = sortedTransactions.compactMap { transaction -> ValidatedTransaction? in
            guard let transactionDate = TransactionDay.date(
                from: transaction.transactionDay,
                calendar: calendar,
                locale: locale
            ),
            let month = HomeMonth.from(
                date: transactionDate,
                calendar: calendar,
                locale: locale
            ),
            let payload = try? transaction.validatedPayload()
            else {
                return nil
            }

            guard case let .diningExpense(amount) = payload else { return nil }
            return ValidatedTransaction(
                transaction: transaction,
                month: month,
                amount: amount
            )
        }
        self.validTransactions = validTransactions
        self.availableMonths = Array(Set(validTransactions.map(\.month))).sorted()
        self.initialMonth = Self.initialMonth(
            now: now,
            calendar: calendar,
            availableMonths: self.availableMonths
        )
        self.locale = locale
        self.calendar = calendar
    }

    /// 生成指定月份的完整展示投影；空月份也会返回可渲染的空状态数据。
    ///
    /// - Parameter month: 要展示的自然年月，可以是任意有效月份。
    /// - Returns: 月份标题、精确汇总和按日明细。
    func presentation(for month: HomeMonth) -> HomeOverviewMonthPresentation {
        let monthTransactions = validTransactions.filter { $0.month == month }
        let groupedTransactions = Dictionary(grouping: monthTransactions, by: \.transaction.transactionDay)
        let dayGroups = groupedTransactions.keys.sorted(by: >).compactMap { transactionDay in
            guard let date = TransactionDay.date(
                from: transactionDay,
                calendar: calendar,
                locale: locale
            ) else {
                return nil
            }

            let transactions = groupedTransactions[transactionDay, default: []]
            let rows = transactions.compactMap { Self.row(
                for: $0.transaction,
                locale: locale,
                calendar: calendar
            ) }
            let expenseTotal = transactions.reduce(into: Decimal.zero) { total, transaction in
                total += transaction.amount
            }
            return HomeOverviewDayPresentation(
                transactionDay: transactionDay,
                formattedDate: Self.formattedDate(date, locale: locale, calendar: calendar),
                formattedWeekday: Self.formattedWeekday(date, locale: locale, calendar: calendar),
                incomeTotal: .zero,
                expenseTotal: expenseTotal,
                rows: rows
            )
        }

        let expenseTotal = dayGroups.reduce(into: Decimal.zero) { total, day in
            total += day.expenseTotal
        }
        return HomeOverviewMonthPresentation(
            month: month,
            formattedMonth: month.formatted(locale: locale, calendar: calendar),
            incomeTotal: .zero,
            expenseTotal: expenseTotal,
            dayGroups: dayGroups
        )
    }

    /// 将一笔有效餐饮流水转换为首页本地化明细行。
    ///
    /// - Parameters:
    ///   - transaction: 需要转换的原始流水。
    ///   - locale: 标题、金额和日期使用的语言环境。
    ///   - calendar: 日期使用的公历及时区。
    /// - Returns: 可展示的首页行；无效日期、损坏载荷和非真实支出返回 `nil`。
    static func row(
        for transaction: AccountTransaction,
        locale: Locale = .current,
        calendar sourceCalendar: Calendar = .current
    ) -> HomeOverviewRowPresentation? {
        guard let payload = try? transaction.validatedPayload(),
              case .diningExpense = payload,
              let date = TransactionDay.date(
                  from: transaction.transactionDay,
                  calendar: sourceCalendar,
                  locale: locale
              ),
              let historyRow = AccountTransactionHistoryPresentation.row(
                  for: transaction,
                  locale: locale,
                  calendar: sourceCalendar
              )
        else {
            return nil
        }

        return HomeOverviewRowPresentation(
            id: historyRow.id,
            title: historyRow.title,
            formattedAmount: historyRow.formattedAmount,
            formattedDate: Self.formattedDate(date, locale: locale, calendar: sourceCalendar),
            note: historyRow.note,
            accessibilityLabel: historyRow.accessibilityLabel
        )
    }

    /// 根据当前日期和真实数据月份选择首页首次展示月份。
    ///
    /// 当前月有数据时优先当前月；当前月为空时优先最近历史月份，若没有历史数据
    /// 则选择最早未来数据月份；完全没有数据时保留当前月。
    ///
    /// - Parameters:
    ///   - now: 注入的当前日期。
    ///   - calendar: 提供时区和公历规则的日历。
    ///   - availableMonths: 已确认包含真实流水的月份集合。
    /// - Returns: 符合首页初始规则的月份。
    static func initialMonth(
        now: Date,
        calendar sourceCalendar: Calendar,
        availableMonths: some Sequence<HomeMonth>
    ) -> HomeMonth {
        let calendar = TransactionDay.gregorianCalendar(basedOn: sourceCalendar)
        let currentMonth = HomeMonth.from(date: now, calendar: calendar)
            ?? HomeMonth(year: 1970, month: 1)!
        let months = Array(Set(availableMonths)).sorted()
        guard !months.contains(currentMonth) else { return currentMonth }
        if let previousMonth = months.last(where: { $0 < currentMonth }) {
            return previousMonth
        }
        return months.first(where: { $0 > currentMonth }) ?? currentMonth
    }

    /// 供 SwiftData 查询结果和纯数组投影共用的稳定流水排序。
    private static func isOrderedBefore(
        _ lhs: AccountTransaction,
        _ rhs: AccountTransaction
    ) -> Bool {
        if lhs.transactionDay != rhs.transactionDay {
            return lhs.transactionDay > rhs.transactionDay
        }
        if lhs.savedAt != rhs.savedAt {
            return lhs.savedAt > rhs.savedAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// 已完成有效日期、载荷和自然月份解码的餐饮流水。
    private struct ValidatedTransaction {
        /// 原始流水，供本地化行展示使用。
        let transaction: AccountTransaction

        /// 由业务日解析出的自然月份。
        let month: HomeMonth

        /// 经 `validatedPayload()` 确认的精确餐饮金额。
        let amount: Decimal
    }

    /// 首页投影使用的固定语言环境。
    private let locale: Locale

    /// 首页投影使用的固定公历及时区。
    private let calendar: Calendar

    /// 格式化短日期，失败时回退到公历数字日期。
    private static func formattedDate(
        _ date: Date,
        locale: Locale,
        calendar: Calendar
    ) -> String {
        date.formatted(
            Date.FormatStyle(
                date: .numeric,
                time: .omitted,
                locale: locale,
                calendar: calendar,
                timeZone: calendar.timeZone
            )
        )
    }

    /// 格式化本地化星期标题。
    private static func formattedWeekday(
        _ date: Date,
        locale: Locale,
        calendar sourceCalendar: Calendar
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = sourceCalendar
        formatter.timeZone = sourceCalendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter.string(from: date)
    }
}
