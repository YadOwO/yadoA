import Foundation

/// 各记账投影共用的业务日期格式化入口，保证短日期与模板日期的口径一致。
enum BookkeepingDateFormatting {
    /// 把业务日期格式化为当前语言环境下不含时间的短日期。
    ///
    /// - Parameters:
    ///   - date: 已解析的业务日期。
    ///   - locale: 日期使用的语言环境。
    ///   - calendar: 提供公历规则与时区的日历。
    /// - Returns: 本地化的数字短日期。
    static func shortDate(_ date: Date, locale: Locale, calendar: Calendar) -> String {
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

    /// 创建使用明确日历、时区和语言环境的模板日期格式器。
    ///
    /// 格式器创建成本较高，调用方应在单次投影内创建一次并复用。
    ///
    /// - Parameters:
    ///   - template: `setLocalizedDateFormatFromTemplate` 使用的日期模板。
    ///   - locale: 日期使用的语言环境。
    ///   - calendar: 提供公历规则与时区的日历。
    /// - Returns: 已配置完成的日期格式器。
    static func formatter(template: String, locale: Locale, calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }
}
