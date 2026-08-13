import Foundation

enum AccountAmountParser {
    static func amount(from text: String, locale: Locale = .current) -> Decimal? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.first != "-" else { return nil }

        let decimalSeparator = locale.decimalSeparator ?? "."
        let parts = value.components(separatedBy: decimalSeparator)
        guard parts.count <= 2,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isWholeNumber) })
        else { return nil }

        return Decimal(
            string: canonicalized(value, decimalSeparator: decimalSeparator),
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    /// 把区域化小数分隔符转换为持久化金额统一使用的英文句点。
    ///
    /// - Parameters:
    ///   - text: 尚未解析的金额字符。
    ///   - decimalSeparator: 当前系统区域使用的小数分隔符。
    /// - Returns: 使用英文句点的小数金额字符。
    static func canonicalized(_ text: String, decimalSeparator: String) -> String {
        decimalSeparator == "."
            ? text
            : text.replacingOccurrences(of: decimalSeparator, with: ".")
    }

    /// 归一系统数字键盘的实时输入，并限制为 CNY 支持的两位小数。
    ///
    /// 空字符和末尾小数点属于合法的编辑中状态，但仍需由最终金额解析拒绝。
    ///
    /// - Parameters:
    ///   - text: 文本框当前尝试写入的金额字符。
    ///   - decimalSeparator: 当前系统区域使用的小数分隔符。
    /// - Returns: 使用英文句点的非负金额字符；非法输入返回 `nil`。
    static func normalizedCNYAmountText(
        _ text: String,
        decimalSeparator: String
    ) -> String? {
        guard !decimalSeparator.isEmpty else { return nil }

        var normalizedText = canonicalized(
            text,
            decimalSeparator: decimalSeparator
        )
        if normalizedText.hasPrefix(".") {
            normalizedText = "0" + normalizedText
        }

        guard normalizedText.allSatisfy({ character in
            character == "." || (character >= "0" && character <= "9")
        }),
        normalizedText.filter({ $0 == "." }).count <= 1
        else { return nil }

        if let decimalPoint = normalizedText.firstIndex(of: ".") {
            let fractionalDigits = normalizedText.distance(
                from: normalizedText.index(after: decimalPoint),
                to: normalizedText.endIndex
            )
            guard fractionalDigits <= 2 else { return nil }
        }

        return normalizedText
    }

    /// 把已经归一的非负 CNY 金额字符解析为精确十进制数。
    ///
    /// - Parameter text: 使用英文句点、最多两位小数的金额字符。
    /// - Returns: 可持久化的非负金额；编辑中或非法字符返回 `nil`。
    static func cnyAmount(fromNormalized text: String) -> Decimal? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !text.isEmpty,
              parts.count <= 2,
              !parts[0].isEmpty,
              parts.allSatisfy({ part in
                  !part.isEmpty && part.allSatisfy { character in
                      character >= "0" && character <= "9"
                  }
              }),
              parts.count == 1 || parts[1].count <= 2,
              let amount = Decimal(
                  string: text,
                  locale: Locale(identifier: "en_US_POSIX")
              ),
              amount >= 0
        else { return nil }

        return amount
    }

    /// 判断精确十进制金额是否能在 CNY 两位小数内无损表示。
    static func hasCNYPrecision(_ amount: Decimal) -> Bool {
        var source = amount
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, 2, .plain)
        return rounded == amount
    }
}
