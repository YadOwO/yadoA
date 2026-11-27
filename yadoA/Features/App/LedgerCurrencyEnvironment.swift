import SwiftData
import SwiftUI

/// `EnvironmentValues.ledgerCurrencyCode` 的环境键，没注入时回退到 `BookkeepingCurrency.fallbackCode`。
private nonisolated struct LedgerCurrencyCodeKey: EnvironmentKey {
    static var defaultValue: String { BookkeepingCurrency.fallbackCode }
}

extension EnvironmentValues {
    /// 当前账本币种的 ISO 4217 代码，视图格式化金额、限制小数位、判断能否记账时统一读它。
    ///
    /// 由 `LedgerCurrencyModifier` 在根视图注入，改币种、恢复备份、收到同步后会自动刷新；
    /// 没有注入时（例如预览）取带默认值的 `CNY`，不会因为缺少注入而崩溃。
    nonisolated var ledgerCurrencyCode: String {
        get { self[LedgerCurrencyCodeKey.self] }
        set { self[LedgerCurrencyCodeKey.self] = newValue }
    }
}

/// 把账本币种注入环境：取最早建的账户的币种，没有账户时看本机存的值，再看手机地区。
///
/// 账户由 `@Query` 观察、本机存的值由 `@AppStorage` 观察，所以任何写入账户币种的路径
/// （设置里改币种、恢复备份、云同步收到别的设备的改动）都会让所有页面跟着刷新。
/// 取值规则和 `BookkeepingCurrency.current(in:)` 一致，都走 `BookkeepingCurrency.resolve`。
struct LedgerCurrencyModifier: ViewModifier {
    /// 全部账户，按创建时间升序；最早的一个决定账本币种。
    @Query(sort: \Account.createdAt) private var accounts: [Account]

    /// 账本里还没有账户时，本机存的币种选择。
    @AppStorage(BookkeepingCurrency.storageKey) private var storedCode: String?

    func body(content: Content) -> some View {
        content.environment(
            \.ledgerCurrencyCode,
            BookkeepingCurrency.resolve(
                earliestAccountCode: accounts.first?.currencyCode,
                storedCode: storedCode
            )
        )
    }
}
