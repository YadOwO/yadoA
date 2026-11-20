import Foundation

/// 签到日历里的一个月：只做日历日运算，与时区无关。
///
/// 签到日期由服务端按北京时间算好、以 `YYYY-MM-DD` 文本返回，客户端不再按本机时区换算；
/// 这里借 GMT 的公历计算每月天数和 1 号是星期几，结果只取决于年月本身。
nonisolated struct CheckInCalendarMonth: Hashable, Comparable, Identifiable, Sendable {
    /// 公历年份。
    let year: Int

    /// 月份，1 到 12。
    let month: Int

    /// 计算星期和天数用的公历，固定 GMT，避免本机时区让日期前后错一天。
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    /// 用年月创建；月份不在 1 到 12 之间时为 nil。
    ///
    /// - Parameters:
    ///   - year: 公历年份。
    ///   - month: 月份，1 到 12。
    init?(year: Int, month: Int) {
        guard (1...12).contains(month) else { return nil }
        self.year = year
        self.month = month
    }

    /// 由 `YYYY-MM` 或 `YYYY-MM-DD` 文本取出所在的月份；格式不对时为 nil。
    ///
    /// - Parameter text: 月份或日期文本，例如 `2026-11`、`2026-11-05`。
    init?(_ text: String) {
        let parts = text.split(separator: "-")
        guard parts.count == 2 || parts.count == 3,
              parts[0].count == 4, parts[1].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1])
        else { return nil }
        self.init(year: year, month: month)
    }

    /// 稳定标识，即 `YYYY-MM`。
    var id: String { text }

    /// 接口用的月份文本，`YYYY-MM`。
    var text: String {
        String(format: "%04d-%02d", year, month)
    }

    /// 上个月。
    var previous: CheckInCalendarMonth {
        month == 1 ? CheckInCalendarMonth(uncheckedYear: year - 1, month: 12) : CheckInCalendarMonth(uncheckedYear: year, month: month - 1)
    }

    /// 下个月。
    var next: CheckInCalendarMonth {
        month == 12 ? CheckInCalendarMonth(uncheckedYear: year + 1, month: 1) : CheckInCalendarMonth(uncheckedYear: year, month: month + 1)
    }

    /// 这个月有几天。
    var dayCount: Int {
        Self.calendar.range(of: .day, in: .month, for: firstDay)?.count ?? 30
    }

    /// 这个月 1 号 GMT 零点，只用来取星期和格式化月份标题。
    var firstDay: Date {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? .distantPast
    }

    /// 1 号前面要空几格。
    ///
    /// - Parameter firstWeekday: 每周从星期几开始，1 为星期日、2 为星期一，与 `Calendar.firstWeekday` 一致。
    /// - Returns: 0 到 6。
    func leadingBlankCount(firstWeekday: Int) -> Int {
        let weekday = Self.calendar.component(.weekday, from: firstDay)
        return ((weekday - firstWeekday) % 7 + 7) % 7
    }

    /// 某一天的日期文本，`YYYY-MM-DD`，与服务端返回的签到日一致。
    ///
    /// - Parameter day: 几号，从 1 开始。
    func dateText(day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// 某一天 GMT 零点，只用来格式化无障碍朗读的日期。
    ///
    /// - Parameter day: 几号，从 1 开始。
    func date(day: Int) -> Date {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? firstDay
    }

    /// 月份标题，例如“2026年11月”“November 2026”。
    ///
    /// - Parameter locale: 文案使用的语言环境。
    func title(locale: Locale) -> String {
        firstDay.formatted(Self.formatStyle(locale: locale).year().month(.wide))
    }

    /// 某一天的完整日期朗读文本，例如“2026年11月5日”。
    ///
    /// - Parameters:
    ///   - day: 几号。
    ///   - locale: 文案使用的语言环境。
    func spokenDate(day: Int, locale: Locale) -> String {
        date(day: day).formatted(Self.formatStyle(locale: locale).year().month(.wide).day())
    }

    /// 按某周起始日排好的星期简写，例如“日 一 二 …”。
    ///
    /// - Parameters:
    ///   - firstWeekday: 每周从星期几开始，1 为星期日。
    ///   - locale: 文案使用的语言环境。
    static func weekdaySymbols(firstWeekday: Int, locale: Locale) -> [String] {
        var localized = Self.calendar
        localized.locale = locale
        let symbols = localized.veryShortStandaloneWeekdaySymbols
        let start = (firstWeekday - 1 + 7) % 7
        return Array(symbols[start...] + symbols[..<start])
    }

    /// 在 `lower...upper` 之间夹住；`lower` 比 `upper` 晚时取 `upper`。
    ///
    /// - Parameters:
    ///   - lower: 最早能翻到的月份。
    ///   - upper: 最晚能翻到的月份。
    func clamped(lower: CheckInCalendarMonth, upper: CheckInCalendarMonth) -> CheckInCalendarMonth {
        let lower = Swift.min(lower, upper)
        return Swift.max(lower, Swift.min(self, upper))
    }

    static func < (lhs: CheckInCalendarMonth, rhs: CheckInCalendarMonth) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }

    /// GMT 公历、指定语言的日期格式。
    private static func formatStyle(locale: Locale) -> Date.FormatStyle {
        Date.FormatStyle(locale: locale, calendar: calendar, timeZone: .gmt)
    }

    /// 内部用：已知月份合法时直接创建。
    private init(uncheckedYear year: Int, month: Int) {
        self.year = year
        self.month = month
    }
}
