import Foundation
import SwiftData

/// 本地记账统一使用的币种约定：一个账本一种币。
///
/// 账户、流水和周期记账生成的流水都写同一个账本币种，不做按账户分币种，也不接汇率；
/// 换币种只换符号，金额不换算。账本币种不单独存库，而是从已有数据推出来：
/// 本机有账户时取最早建的账户的 `currencyCode`；没有账户时取本机存的选择（`storageKey`）；
/// 也没有时取手机地区的货币；都拿不到时用 `fallbackCode`。
/// 币种解析、小数位和可选币种列表只在这里写一份，视图、仓库、语音、备份都调它，不要在别处重复实现。
nonisolated enum BookkeepingCurrency {
    /// 拿不到地区货币、旧备份缺币种字段时使用的 ISO 4217 货币代码（旧版本的账本都是人民币）。
    static let fallbackCode = "CNY"

    /// 账本里还没有账户时，本机存下的币种选择所用的 `UserDefaults` 键。
    static let storageKey = "bookkeeping.currencyCode"

    /// 选择币种时排在最前面的常用币种。
    static let commonCodes = ["CNY", "USD", "CAD", "GBP", "EUR", "HKD", "TWD", "JPY", "KRW", "AUD", "SGD"]

    /// 常用币种加上系统认识的 ISO 常用币种，已去重，常用的排在前面。
    private static let allSelectableCodes: [String] = {
        var seen = Set<String>()
        var codes: [String] = []
        for code in commonCodes + NSLocale.commonISOCurrencyCodes where seen.insert(code).inserted {
            codes.append(code)
        }
        return codes
    }()

    /// 可以选作账本币种的全部代码：常用币种在前，其余 ISO 常用币种在后。
    ///
    /// - Returns: 去重后的币种代码。
    static func selectableCodes() -> [String] {
        allSelectableCodes
    }

    /// 是不是三位大写 ASCII 字母，备份和云同步只用它校验记录里的币种。
    ///
    /// - Parameter code: 待校验的币种代码。
    /// - Returns: 格式合法时为 `true`。
    static func isWellFormed(_ code: String) -> Bool {
        code.utf8.count == 3 && code.utf8.allSatisfy { $0 >= 0x41 && $0 <= 0x5A }
    }

    /// 是不是可以选作账本币种的 ISO 常用币种。
    ///
    /// - Parameter code: 待判断的币种代码。
    /// - Returns: 在 `selectableCodes()` 里时为 `true`。
    static func isSelectable(_ code: String) -> Bool {
        isWellFormed(code) && allSelectableCodes.contains(code)
    }

    /// 手机地区对应的默认币种：只认 `selectableCodes()` 里的币种，拿不到或不认识时用 `fallbackCode`。
    ///
    /// - Parameter locale: 取地区货币的语言环境。
    /// - Returns: 默认币种代码。
    static func regionDefault(locale: Locale = .current) -> String {
        if let code = locale.currency?.identifier, isSelectable(code) {
            return code
        }
        return fallbackCode
    }

    /// 按「最早账户 → 本机存的值 → 地区 → CNY」的顺序决定账本币种，格式不合法的值直接跳过。
    ///
    /// 纯函数：不读库也不读 `UserDefaults`，由调用方把读到的值传进来。
    /// - Parameters:
    ///   - earliestAccountCode: 最早建的账户的币种；本机没有账户时为 `nil`。
    ///   - storedCode: 本机存的币种选择；没存过时为 `nil`。
    ///   - locale: 取地区默认币种的语言环境。
    /// - Returns: 账本币种代码。
    static func resolve(
        earliestAccountCode: String?,
        storedCode: String?,
        locale: Locale = .current
    ) -> String {
        if let earliestAccountCode, isWellFormed(earliestAccountCode) {
            return earliestAccountCode
        }
        if let storedCode, isWellFormed(storedCode) {
            return storedCode
        }
        return regionDefault(locale: locale)
    }

    /// 从本机账本推出当前账本币种：取最早建的账户（按 `createdAt`）的币种，没有账户时再看本机存的值和地区。
    ///
    /// 仓库和服务在写入、校验前用它取账本币种；视图改读环境值 `ledgerCurrencyCode`。
    /// - Parameters:
    ///   - context: 读取账户的 context。
    ///   - defaults: 读取本机存的币种选择。
    ///   - locale: 取地区默认币种的语言环境。
    /// - Returns: 账本币种代码。
    /// - Throws: 读取账户失败时抛出。
    @MainActor
    static func current(
        in context: ModelContext,
        defaults: UserDefaults = .standard,
        locale: Locale = .current
    ) throws -> String {
        var descriptor = FetchDescriptor<Account>(sortBy: [SortDescriptor(\.createdAt)])
        descriptor.fetchLimit = 1
        let earliest = try context.fetch(descriptor).first
        return resolve(
            earliestAccountCode: earliest?.currencyCode,
            storedCode: defaults.string(forKey: storageKey),
            locale: locale
        )
    }

    /// 币种自己的小数位数，例如 CNY、USD 是 2，JPY、KRW 是 0，KWD 是 3。
    ///
    /// - Parameter code: ISO 4217 货币代码。
    /// - Returns: 该币种显示金额用的小数位数。
    static func fractionDigits(for code: String) -> Int {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.currencyCode = code
        return formatter.maximumFractionDigits
    }

    /// 金额输入框允许的小数位数：不超过币种自己的小数位，也不超过存储精度（两位）。
    ///
    /// - Parameter code: ISO 4217 货币代码。
    /// - Returns: `min(fractionDigits, 2)`；三位小数的币种（KWD 等）仍按两位输入。
    static func inputFractionDigits(for code: String) -> Int {
        min(fractionDigits(for: code), 2)
    }

    /// 币种在指定语言下的名称，系统不认识时退回代码本身。
    ///
    /// - Parameters:
    ///   - code: ISO 4217 货币代码。
    ///   - locale: 决定名称语言的语言环境。
    /// - Returns: 本地化的币种名称。
    static func displayName(for code: String, locale: Locale) -> String {
        locale.localizedString(forCurrencyCode: code) ?? code
    }

    /// 币种在指定语言下的符号，由系统决定写法（例如中文界面下美元显示为 US$）。
    ///
    /// - Parameters:
    ///   - code: ISO 4217 货币代码。
    ///   - locale: 决定符号写法的语言环境。
    /// - Returns: 货币符号；系统给不出符号时退回代码本身。
    static func symbol(for code: String, locale: Locale) -> String {
        symbols(for: [code], locale: locale)[code] ?? code
    }

    /// 一批币种在指定语言下的符号；只创建一个格式化器，列表里批量取符号时用它。
    ///
    /// - Parameters:
    ///   - codes: ISO 4217 货币代码。
    ///   - locale: 决定符号写法的语言环境。
    /// - Returns: 代码到符号的字典；系统给不出符号的币种退回代码本身。
    static func symbols(for codes: [String], locale: Locale) -> [String: String] {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        var result: [String: String] = [:]
        for code in codes {
            formatter.currencyCode = code
            result[code] = formatter.currencySymbol ?? code
        }
        return result
    }
}

extension Decimal {
    /// 按语言环境把金额格式化为货币文本；负数沿用货币格式自带的负号。
    ///
    /// 一个账本一种币：币种必须由调用方显式传入，账本币种取环境值 `ledgerCurrencyCode`，
    /// 单条记录则用它自己的 `currencyCode`。小数位按币种自己的规则显示。
    ///
    /// - Parameters:
    ///   - locale: 决定货币符号、千分位和小数点的语言环境。
    ///   - currencyCode: ISO 4217 货币代码。
    /// - Returns: 本地化后的金额文本。
    nonisolated func formattedCurrency(
        locale: Locale,
        currencyCode: String
    ) -> String {
        formatted(.currency(code: currencyCode).locale(locale))
    }
}
