import Foundation

/// 账户流水公历 `YYYYMMDD` 业务日的统一转换边界。
enum TransactionDay {
    /// 校验历史年份时复用的 UTC 公历，避免每次校验重新创建日历。
    private static let utcGregorianCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    /// 平年各月天数，闰年二月由 `isValid` 单独处理。
    private static let daysInMonth = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

    /// 保留调用方时区，并把日历标识统一为公历。
    static func gregorianCalendar(
        basedOn source: Calendar,
        locale: Locale? = nil
    ) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale ?? source.locale
        calendar.timeZone = source.timeZone
        return calendar
    }

    /// 把日期转换为当前时区下的 `YYYYMMDD` 整数。
    static func encode(_ date: Date, calendar source: Calendar) -> Int {
        let calendar = gregorianCalendar(basedOn: source)
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return (components.year ?? 1970) * 10_000
            + (components.month ?? 1) * 100
            + (components.day ?? 1)
    }

    /// 把 `YYYYMMDD` 整数解析为调用方时区下的真实公历日期。
    static func date(
        from value: Int,
        calendar source: Calendar,
        locale: Locale? = nil
    ) -> Date? {
        let year = value / 10_000
        let month = value / 100 % 100
        let day = value % 100
        guard year > 0, month > 0, day > 0 else { return nil }

        let calendar = gregorianCalendar(basedOn: source, locale: locale)
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day
        )
        guard let date = calendar.date(from: components) else { return nil }
        let normalized = calendar.dateComponents([.year, .month, .day], from: date)
        guard normalized.year == year,
              normalized.month == month,
              normalized.day == day
        else { return nil }
        return date
    }

    /// 判断整数是否表示真实的公历业务日。
    static func isValid(_ value: Int) -> Bool {
        let year = value / 10_000
        let month = value / 100 % 100
        let day = value % 100
        // Foundation 公历在 1582 年改历前按儒略历计算，历史与超大年份仍交给日历判断。
        guard (1583...9999).contains(year) else {
            return date(from: value, calendar: utcGregorianCalendar) != nil
        }
        guard (1...12).contains(month), day >= 1 else { return false }
        let isLeapYear = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        let lastDay = month == 2 && isLeapYear ? 29 : daysInMonth[month - 1]
        return day <= lastDay
    }

    /// 单次投影内按业务日缓存日期解析结果。
    ///
    /// 流水数量远多于不同业务日的数量，批量投影通过它把日历计算从“每笔流水一次”
    /// 降为“每个业务日一次”，解析语义与 `TransactionDay.date(from:calendar:locale:)` 完全一致。
    struct DateCache {
        /// 解析业务日使用的日历。
        private let calendar: Calendar

        /// 解析业务日使用的语言环境；为空时沿用日历自身的语言环境。
        private let locale: Locale?

        /// 已解析的业务日；无效业务日同样缓存为 `nil`。
        private var dates: [Int: Date?] = [:]

        /// 创建绑定固定日历和语言环境的缓存。
        init(calendar: Calendar, locale: Locale? = nil) {
            self.calendar = calendar
            self.locale = locale
        }

        /// 返回业务日对应的日期；无效业务日返回 `nil`。
        mutating func date(for value: Int) -> Date? {
            if let cached = dates[value] { return cached }
            let date = TransactionDay.date(from: value, calendar: calendar, locale: locale)
            dates.updateValue(date, forKey: value)
            return date
        }
    }
}
