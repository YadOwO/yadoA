import Foundation

/// 账户流水公历 `YYYYMMDD` 业务日的统一转换边界。
enum TransactionDay {
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
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return date(from: value, calendar: calendar) != nil
    }
}
