import Foundation
import Testing
@testable import yadoA

/// 金额算式与每日提醒的排期。
@Suite("金额算式")
@MainActor
struct AmountExpressionTests {
    @Test("加减乘除，先乘除后加减")
    func calculates() {
        #expect(AmountExpression.result(of: "28+15") == 43)
        #expect(AmountExpression.result(of: "100−30") == 70)
        #expect(AmountExpression.result(of: "12.5×2") == 25)
        #expect(AmountExpression.result(of: "120÷3") == 40)
        #expect(AmountExpression.result(of: "10−3×2") == 4)
        #expect(AmountExpression.result(of: "2+6÷3×2") == 6)
    }

    @Test("结果四舍五入到两位小数，小数相加不失精度")
    func roundsToCents() {
        #expect(AmountExpression.result(of: "10÷3") == Decimal(string: "3.33"))
        #expect(AmountExpression.result(of: "20÷3") == Decimal(string: "6.67"))
        #expect(AmountExpression.result(of: "0.1+0.2") == Decimal(string: "0.3"))
    }

    @Test("末尾多余的运算符忽略，编辑中也能看到结果")
    func ignoresTrailingOperator() {
        #expect(AmountExpression.result(of: "28+") == 28)
        #expect(AmountExpression.result(of: "28+15×") == 43)
    }

    @Test("结果不大于零、除以零、算式不完整时没有结果")
    func rejectsInvalidResults() {
        #expect(AmountExpression.result(of: "5−5") == nil)
        #expect(AmountExpression.result(of: "5−9") == nil)
        #expect(AmountExpression.result(of: "5÷0") == nil)
        #expect(AmountExpression.result(of: "") == nil)
        #expect(AmountExpression.result(of: "+5") == nil)
        #expect(AmountExpression.result(of: "2+×3") == nil)
        #expect(AmountExpression.result(of: "0.001×1") == nil)
    }

    @Test("输入校验：每个数字最多两位小数，不能以运算符开头或连续运算符")
    func validatesInput() {
        #expect(AmountExpression.isValidInput("28+15.5"))
        #expect(AmountExpression.isValidInput("28+"))
        #expect(AmountExpression.isValidInput("1.25×2.50"))
        #expect(!AmountExpression.isValidInput("+5"))
        #expect(!AmountExpression.isValidInput("5+×3"))
        #expect(!AmountExpression.isValidInput("1.234+1"))
        #expect(!AmountExpression.isValidInput("1.2.3+1"))
        #expect(!AmountExpression.isValidInput("5+a"))
    }

    @Test("追加运算符：末尾已是运算符时替换，没有数字时不能追加")
    func appendsOperator() {
        #expect(AmountExpression.appending(.add, to: "28") == "28+")
        #expect(AmountExpression.appending(.multiply, to: "28+") == "28×")
        #expect(AmountExpression.appending(.add, to: "") == nil)
        #expect(AmountExpression.appending(.add, to: "5.") == nil)
    }

    @Test("金额文字使用英文句点，没有多余的零")
    func formatsAmountText() {
        #expect(AmountExpression.amountText(43) == "43")
        #expect(AmountExpression.amountText(Decimal(string: "3.5")!) == "3.5")
        #expect(AmountExpression.amountText(Decimal(string: "3.33")!) == "3.33")
    }

    @Test("算式结果写入草稿后能提交")
    func resultFitsDraft() {
        let flow = DiningExpenseEntryFlow(
            initialAccountID: UUID(),
            now: Date(timeIntervalSince1970: 0),
            saveAction: { _ in }
        )
        flow.selectCategory(key: ExpenseCategory.dining.rawValue)

        flow.updateAmountText(AmountExpression.amountText(AmountExpression.result(of: "10÷3")!), decimalSeparator: ".")

        #expect(flow.draft.amount == Decimal(string: "3.33"))
        #expect(flow.canSubmit)
    }

    // MARK: - 每日提醒

    /// 固定在 UTC 的公历，排期结果与运行环境无关。
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    /// 某天某时的时刻。
    private func date(day: Int, hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    @Test("今天还没到提醒时间且没记账时，从今天开始排")
    func remindsTodayWhenNotRecorded() {
        let fires = BookkeepingReminder.fireComponents(
            now: date(day: 1, hour: 10), minutes: 21 * 60, hasEntryToday: false, calendar: calendar
        )
        #expect(fires.count == BookkeepingReminder.scheduledDays)
        #expect(fires.first?.day == 1)
        #expect(fires.first?.hour == 21)
        #expect(fires.first?.minute == 0)
    }

    @Test("今天记过账就不提醒，从明天开始")
    func skipsTodayWhenRecorded() {
        let fires = BookkeepingReminder.fireComponents(
            now: date(day: 1, hour: 10), minutes: 21 * 60, hasEntryToday: true, calendar: calendar
        )
        #expect(fires.count == BookkeepingReminder.scheduledDays)
        #expect(fires.first?.day == 2)
    }

    @Test("今天已过提醒时间，从明天开始")
    func skipsTodayWhenPassed() {
        let fires = BookkeepingReminder.fireComponents(
            now: date(day: 1, hour: 22), minutes: 21 * 60 + 30, hasEntryToday: false, calendar: calendar
        )
        #expect(fires.first?.day == 2)
        #expect(fires.first?.minute == 30)
    }
}
