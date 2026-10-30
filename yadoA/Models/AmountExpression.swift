import Foundation

/// 金额输入框里的简单算式，例如 `28+15` 或 `120÷3`；只在记账表单使用，不写入任何数据。
enum AmountExpression {
    /// 键盘上方提供的运算符。
    enum Operator: String, CaseIterable, Identifiable {
        /// 加。
        case add = "+"

        /// 减，显示用减号而不是连字符。
        case subtract = "−"

        /// 乘。
        case multiply = "×"

        /// 除。
        case divide = "÷"

        /// SwiftUI 列表使用符号作为标识。
        var id: String { rawValue }

        /// VoiceOver 朗读的本地化键。
        var accessibilityKey: String {
            switch self {
            case .add: "expense.entry.operator.add"
            case .subtract: "expense.entry.operator.subtract"
            case .multiply: "expense.entry.operator.multiply"
            case .divide: "expense.entry.operator.divide"
            }
        }
    }

    /// 算式里的一个词：数字或运算符。
    private enum Token: Equatable {
        case number(Decimal)
        case operation(Operator)
    }

    /// 文字里是否带运算符；不带时按普通金额处理。
    ///
    /// - Parameter text: 输入框的文字。
    static func containsOperator(_ text: String) -> Bool {
        text.contains { Operator(rawValue: String($0)) != nil }
    }

    /// 在算式末尾加一个运算符；末尾已经是运算符时替换它。
    ///
    /// - Parameters:
    ///   - operation: 要加的运算符。
    ///   - text: 当前文字，使用英文句点。
    /// - Returns: 新的文字；还没有输入数字时返回 `nil`，算式不能以运算符开头。
    static func appending(_ operation: Operator, to text: String) -> String? {
        var result = text
        if let last = result.last, Operator(rawValue: String(last)) != nil {
            result.removeLast()
        }
        guard let last = result.last, last.isNumber else { return nil }
        return result + operation.rawValue
    }

    /// 判断编辑中的文字能否继续作为算式：只有数字、小数点和运算符，每个数字最多两位小数。
    ///
    /// 末尾的运算符和小数点属于合法的编辑中状态。
    ///
    /// - Parameter text: 输入框的文字，使用英文句点。
    static func isValidInput(_ text: String) -> Bool {
        var fractionDigits: Int?
        var hasDigitInNumber = false
        for character in text {
            if character == "." {
                guard fractionDigits == nil else { return false }
                fractionDigits = 0
            } else if character >= "0", character <= "9" {
                hasDigitInNumber = true
                if let digits = fractionDigits {
                    guard digits < 2 else { return false }
                    fractionDigits = digits + 1
                }
            } else if Operator(rawValue: String(character)) != nil {
                guard hasDigitInNumber else { return false }
                fractionDigits = nil
                hasDigitInNumber = false
            } else {
                return false
            }
        }
        return true
    }

    /// 计算算式的结果：先乘除后加减，四舍五入到两位小数；末尾多余的运算符忽略。
    ///
    /// - Parameter text: 算式，使用英文句点。
    /// - Returns: 大于零的结果；算式不完整、除以零、溢出或结果不大于零时返回 `nil`。
    static func result(of text: String) -> Decimal? {
        guard var tokens = tokens(of: text) else { return nil }
        if case .operation? = tokens.last { tokens.removeLast() }
        guard !tokens.isEmpty else { return nil }

        // 先把乘除合并成项，剩下的项只需要加减
        var terms: [(sign: Operator, value: Decimal)] = []
        var pendingSign = Operator.add
        var index = 0
        while index < tokens.count {
            guard case let .number(number) = tokens[index] else { return nil }
            var value = number
            index += 1
            while index + 1 < tokens.count,
                  case let .operation(operation) = tokens[index],
                  operation == .multiply || operation == .divide,
                  case let .number(right) = tokens[index + 1] {
                guard let combined = calculate(value, operation, right) else { return nil }
                value = combined
                index += 2
            }
            terms.append((pendingSign, value))
            if index < tokens.count {
                guard case let .operation(operation) = tokens[index] else { return nil }
                pendingSign = operation
                index += 1
            }
        }

        var total = Decimal.zero
        for term in terms {
            guard let next = calculate(total, term.sign, term.value) else { return nil }
            total = next
        }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &total, 2, .plain)
        return rounded > 0 ? rounded : nil
    }

    /// 把结果写成金额字段使用的文字：英文句点、没有多余的零。
    ///
    /// - Parameter amount: 金额。
    static func amountText(_ amount: Decimal) -> String {
        var value = amount
        return NSDecimalString(&value, Locale(identifier: "en_US_POSIX"))
    }

    /// 把文字拆成数字和运算符；数字写法不合法时返回 `nil`。
    private static func tokens(of text: String) -> [Token]? {
        var tokens: [Token] = []
        var number = ""
        func flushNumber() -> Bool {
            guard !number.isEmpty else { return true }
            guard let value = Decimal(string: number, locale: Locale(identifier: "en_US_POSIX")) else { return false }
            tokens.append(.number(value))
            number = ""
            return true
        }
        for character in text {
            if let operation = Operator(rawValue: String(character)) {
                guard flushNumber() else { return nil }
                tokens.append(.operation(operation))
            } else {
                number.append(character)
            }
        }
        guard flushNumber() else { return nil }
        return tokens
    }

    /// 计算一步；除不尽时接受精度损失，最后统一四舍五入，溢出和除以零返回 `nil`。
    private static func calculate(_ lhs: Decimal, _ operation: Operator, _ rhs: Decimal) -> Decimal? {
        var left = lhs
        var right = rhs
        var result = Decimal()
        let error = switch operation {
        case .add: NSDecimalAdd(&result, &left, &right, .plain)
        case .subtract: NSDecimalSubtract(&result, &left, &right, .plain)
        case .multiply: NSDecimalMultiply(&result, &left, &right, .plain)
        case .divide: NSDecimalDivide(&result, &left, &right, .plain)
        }
        return error == .noError || error == .lossOfPrecision ? result : nil
    }
}
