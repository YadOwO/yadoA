import Foundation

/// 「开发」页面入口的开关：只有用 `yadoA-local` Scheme 运行过的 DEBUG 包才显示，Release 包始终隐藏。
///
/// Scheme 通过启动环境变量 `YADO_LOCAL_BUILD` 指定（`yadoA-local` 为 1，`yadoA` 为 0），启动时写入设置；
/// 之后从桌面直接打开 App（没有环境变量）也保持上次的结果。
enum DeveloperTools {
    /// 是否为本地开发包的存储键。
    static let storageKey = "debug.developerTools.enabled"

    /// Scheme 中指定是否为本地开发包的启动环境变量，取值为 `1` 或 `0`。
    static let launchEnvironmentKey = "YADO_LOCAL_BUILD"

    /// 当前是否显示开发页面入口；Release 包始终为 false。
    static var isEnabled: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: storageKey)
        #else
        false
        #endif
    }

    /// 按 Xcode Scheme 的启动环境变量写入设置；没有该变量或取值不是 `1` / `0` 时保持原样。只在 DEBUG 包生效。
    ///
    /// - Parameters:
    ///   - environment: 进程的环境变量。
    ///   - defaults: 写入的设置。
    static func applyLaunchEnvironment(_ environment: [String: String], defaults: UserDefaults = .standard) {
        #if DEBUG
        switch environment[launchEnvironmentKey] {
        case "1": defaults.set(true, forKey: storageKey)
        case "0": defaults.set(false, forKey: storageKey)
        default: break
        }
        #endif
    }
}
