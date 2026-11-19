import Foundation
import Testing
@testable import yadoA

/// 验证签到日历的月份运算：解析、前后翻月、每月天数、1 号前的空格、日期文本与翻月范围。
@Suite("签到日历月份")
struct CheckInCalendarMonthTests {
    @Test("从月份或日期文本解析，格式不对时为 nil")
    func parsesMonthText() throws {
        let november = try #require(CheckInCalendarMonth("2026-11"))
        #expect(november.year == 2026)
        #expect(november.month == 11)
        #expect(CheckInCalendarMonth("2026-11-18") == november)
        #expect(november.text == "2026-11")
        #expect(november.id == "2026-11")

        #expect(CheckInCalendarMonth("2026-13") == nil)
        #expect(CheckInCalendarMonth("2026-1") == nil)
        #expect(CheckInCalendarMonth("26-11") == nil)
        #expect(CheckInCalendarMonth("") == nil)
        #expect(CheckInCalendarMonth(year: 2026, month: 0) == nil)
    }

    @Test("前后翻月跨年")
    func movesAcrossYears() throws {
        let january = try #require(CheckInCalendarMonth("2027-01"))
        #expect(january.previous.text == "2026-12")
        #expect(january.previous.next == january)
        let december = try #require(CheckInCalendarMonth("2026-12"))
        #expect(december.next.text == "2027-01")
        #expect(december < january)
    }

    @Test("每月天数：闰年二月 29 天，平年 28 天，小月 30 天")
    func countsDays() throws {
        #expect(try #require(CheckInCalendarMonth("2028-02")).dayCount == 29)
        #expect(try #require(CheckInCalendarMonth("2026-02")).dayCount == 28)
        #expect(try #require(CheckInCalendarMonth("2026-11")).dayCount == 30)
        #expect(try #require(CheckInCalendarMonth("2026-12")).dayCount == 31)
    }

    @Test("1 号前的空格按每周起始日计算：2026 年 11 月 1 日是星期日")
    func countsLeadingBlanks() throws {
        let november = try #require(CheckInCalendarMonth("2026-11"))
        #expect(november.leadingBlankCount(firstWeekday: 1) == 0)
        #expect(november.leadingBlankCount(firstWeekday: 2) == 6)
        // 2028 年 2 月 1 日是星期二
        let february = try #require(CheckInCalendarMonth("2028-02"))
        #expect(february.leadingBlankCount(firstWeekday: 1) == 2)
        #expect(february.leadingBlankCount(firstWeekday: 2) == 1)
    }

    @Test("日期文本补零，与服务端的签到日一致")
    func formatsDateText() throws {
        let march = try #require(CheckInCalendarMonth("2027-03"))
        #expect(march.dateText(day: 5) == "2027-03-05")
        #expect(march.dateText(day: 31) == "2027-03-31")
    }

    @Test("星期简写按每周起始日排列")
    func ordersWeekdaySymbols() {
        let english = Locale(identifier: "en_US")
        let sundayFirst = CheckInCalendarMonth.weekdaySymbols(firstWeekday: 1, locale: english)
        let mondayFirst = CheckInCalendarMonth.weekdaySymbols(firstWeekday: 2, locale: english)
        #expect(sundayFirst.count == 7)
        #expect(mondayFirst.count == 7)
        #expect(Array(mondayFirst.prefix(6)) == Array(sundayFirst.suffix(6)))
        #expect(mondayFirst.last == sundayFirst.first)
    }

    @Test("翻月范围：夹在第一次签到的月份和当前月份之间；从没签过时两端相同")
    func clampsToRange() throws {
        let earliest = try #require(CheckInCalendarMonth("2026-09"))
        let latest = try #require(CheckInCalendarMonth("2026-11"))
        #expect(try #require(CheckInCalendarMonth("2026-12")).clamped(lower: earliest, upper: latest) == latest)
        #expect(try #require(CheckInCalendarMonth("2026-08")).clamped(lower: earliest, upper: latest) == earliest)
        #expect(try #require(CheckInCalendarMonth("2026-10")).clamped(lower: earliest, upper: latest).text == "2026-10")
        // 首签日期比今天还晚（时区或数据异常）时以当前月份为准
        #expect(earliest.clamped(lower: latest.next, upper: latest) == latest)
    }

    @Test("月份标题按语言格式化，不受本机时区影响")
    func formatsTitle() throws {
        let november = try #require(CheckInCalendarMonth("2026-11"))
        #expect(november.title(locale: Locale(identifier: "zh-Hans")).contains("11"))
        #expect(november.title(locale: Locale(identifier: "en_US")) == "November 2026")
    }
}
