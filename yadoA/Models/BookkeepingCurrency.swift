import Foundation

/// 本地记账统一使用的币种约定。
///
/// 当前版本只支持人民币：账户、流水和周期规则都以 `CNY` 持久化，写入流程会拒绝其他币种。
/// 需要判断或格式化币种时统一引用这里，不要在各处重复写 `"CNY"`；以后支持多币种时也只需从这里展开。
nonisolated enum BookkeepingCurrency {
    /// 当前唯一支持的 ISO 4217 货币代码。
    static let code = "CNY"
}

extension Decimal {
    /// 按语言环境把金额格式化为货币文本；负数沿用货币格式自带的负号。
    ///
    /// - Parameters:
    ///   - locale: 决定货币符号、千分位和小数点的语言环境。
    ///   - currencyCode: ISO 4217 货币代码；默认使用当前唯一支持的 `BookkeepingCurrency.code`。
    /// - Returns: 本地化后的金额文本。
    nonisolated func formattedCurrency(
        locale: Locale,
        currencyCode: String = BookkeepingCurrency.code
    ) -> String {
        formatted(.currency(code: currencyCode).locale(locale))
    }
}
