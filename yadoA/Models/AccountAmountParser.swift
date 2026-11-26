import Foundation

/// 账户与金额查询共用的金额输入解析规则。
///
/// 金额的存储精度最多两位小数；输入框按账本币种限制的小数位通过 `fractionDigits` 传入，
/// 默认值 2 就是存储精度，持久化、导入和搜索的校验不传，保持不变。
enum AccountAmountParser {
    /// 解析区域化非负金额，拒绝超过 `fractionDigits` 位小数的输入，供表单和持久化边界共用。
    ///
    /// - Parameters:
    ///   - text: 用户输入的金额文本。
    ///   - locale: 决定小数分隔符的语言环境。
    ///   - fractionDigits: 允许的小数位数；为 0 时不接受小数点。
    static func amount(from text: String, locale: Locale = .current, fractionDigits: Int = 2) -> Decimal? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.first != "-" else { return nil }

        let decimalSeparator = locale.decimalSeparator ?? "."
        let parts = value.components(separatedBy: decimalSeparator)
        guard parts.count <= 2,
              parts.count == 1 || parts[1].count <= fractionDigits,
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

    /// 归一系统数字键盘的实时输入，并限制小数位数。
    ///
    /// 空字符和末尾小数点属于合法的编辑中状态，但仍需由最终金额解析拒绝；
    /// `fractionDigits` 为 0 时连小数点都不接受。
    ///
    /// - Parameters:
    ///   - text: 文本框当前尝试写入的金额字符。
    ///   - decimalSeparator: 当前系统区域使用的小数分隔符。
    ///   - fractionDigits: 允许的小数位数，取 `BookkeepingCurrency.inputFractionDigits(for:)`；默认是存储精度两位。
    /// - Returns: 使用英文句点的非负金额字符；非法输入返回 `nil`。
    static func normalizedCNYAmountText(
        _ text: String,
        decimalSeparator: String,
        fractionDigits: Int = 2
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
            // 没有小数的币种连小数点都不让输入
            guard fractionDigits > 0 else { return nil }
            let fractionalDigits = normalizedText.distance(
                from: normalizedText.index(after: decimalPoint),
                to: normalizedText.endIndex
            )
            guard fractionalDigits <= fractionDigits else { return nil }
        }

        return normalizedText
    }

    /// 归一文本框里的实时输入；没有小数的币种遇到小数点时，丢掉小数点和后面的小数再归一。
    ///
    /// 严格的 `normalizedCNYAmountText` 在 `fractionDigits` 为 0 时连末尾的小数点都拒绝，但账本改成 JPY、KRW 这类币种后，
    /// 打开一笔原来带小数的旧金额（例如 12.50）编辑，按退格会先退到「12.」，被拒绝就删不动了。
    /// 所以文本框的实时输入走这里：「12.5」「12.」都落成「12」，旧金额可以一位位删掉，也输不进新的小数；
    /// 币种有小数位（`fractionDigits` 大于 0）时与 `normalizedCNYAmountText` 完全一致。
    ///
    /// - Parameters:
    ///   - text: 文本框当前尝试写入的金额字符。
    ///   - decimalSeparator: 当前系统区域使用的小数分隔符。
    ///   - fractionDigits: 允许的小数位数，取 `BookkeepingCurrency.inputFractionDigits(for:)`。
    /// - Returns: 使用英文句点的非负金额字符；非法输入返回 `nil`。
    static func normalizedLiveAmountText(
        _ text: String,
        decimalSeparator: String,
        fractionDigits: Int = 2
    ) -> String? {
        if let normalized = normalizedCNYAmountText(
            text,
            decimalSeparator: decimalSeparator,
            fractionDigits: fractionDigits
        ) {
            return normalized
        }
        guard fractionDigits == 0, !decimalSeparator.isEmpty else { return nil }
        let canonical = canonicalized(text, decimalSeparator: decimalSeparator)
        guard let decimalPoint = canonical.firstIndex(of: ".") else { return nil }
        return normalizedCNYAmountText(
            String(canonical[..<decimalPoint]),
            decimalSeparator: ".",
            fractionDigits: 0
        )
    }

    /// 把已经归一的非负金额字符解析为精确十进制数。
    ///
    /// - Parameters:
    ///   - text: 使用英文句点、小数位数不超过 `fractionDigits` 的金额字符。
    ///   - fractionDigits: 允许的小数位数；为 0 时不接受小数点，默认是存储精度两位。
    /// - Returns: 可持久化的非负金额；编辑中或非法字符返回 `nil`。
    static func cnyAmount(fromNormalized text: String, fractionDigits: Int = 2) -> Decimal? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !text.isEmpty,
              parts.count <= 2,
              !parts[0].isEmpty,
              parts.allSatisfy({ part in
                  !part.isEmpty && part.allSatisfy { character in
                      character >= "0" && character <= "9"
                  }
              }),
              parts.count == 1 || parts[1].count <= fractionDigits,
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
