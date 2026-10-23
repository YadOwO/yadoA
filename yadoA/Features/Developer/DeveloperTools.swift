import Foundation

/// 开发调试相关的开关。
///
/// - `isEnabled`：是否显示「开发」页面入口、记录语音耗时。
/// - `isLocalBuild`：是否为 `yadoA-local` 构建，只有它会连本地的同步服务。由启动环境变量 `YADO_LOCAL_BUILD`
///   指定（`yadoA-local` 为 1，`yadoA` 为 0），启动时写入设置；之后从桌面直接打开 App（没有环境变量）也保持上次的结果。
enum DeveloperTools {
    /// 是否为本地开发包的存储键。
    static let storageKey = "debug.developerTools.enabled"

    /// Scheme 中指定是否为本地开发包的启动环境变量，取值为 `1` 或 `0`。
    static let launchEnvironmentKey = "YADO_LOCAL_BUILD"

    /// 是否显示「开发」页面入口；只有 `yadoA-local` 构建显示，Release 包始终隐藏。
    static var isEnabled: Bool {
        #if DEBUG
        // 调试期间临时对所有 DEBUG 包打开，去掉 `true ||` 即恢复
        true || isLocalBuild
        #else
        false
        #endif
    }

    /// 是否为 `yadoA-local` 构建；Release 包始终为 false。
    static var isLocalBuild: Bool {
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
