import Foundation
@testable import yadoA

/// 测试用的账本币种存储：隔离的 `UserDefaults`，不碰 `.standard`。
///
/// 账本里还没有账户时，账本币种取决于本机存的值和模拟器的地区；新建第一个账户的测试如果要稳定地得到 CNY，
/// 就把这里的存储注入给仓库（`LocalAccountRepository(container:defaults:)`、`BackupImportService(container:defaults:)` 等）。
enum LedgerTestDefaults {
    /// 隔离存储的名称：所有测试共用同一个，里面只存着 CNY，不会被测试写成别的币种。
    private static let sharedSuiteName = "yadoATests.ledgerCurrency.shared"

    /// 已经存好 CNY 的共用存储，只读使用；会写币种的测试请用 `make(currency:name:)` 另建一份。
    static let cny: UserDefaults = {
        let defaults = UserDefaults(suiteName: sharedSuiteName)!
        defaults.set("CNY", forKey: BookkeepingCurrency.storageKey)
        return defaults
    }()

    /// 创建一份全新的隔离存储，供会写币种的测试使用。
    ///
    /// - Parameters:
    ///   - currency: 预先存好的币种；为 `nil` 时什么都不存。
    ///   - name: 区分用例的名称，同名存储会先被清空。
    /// - Returns: 隔离的 `UserDefaults`。
    static func make(currency: String? = nil, name: String) -> UserDefaults {
        let suiteName = "yadoATests.ledgerCurrency.\(name)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        if let currency {
            defaults.set(currency, forKey: BookkeepingCurrency.storageKey)
        }
        return defaults
    }
}
