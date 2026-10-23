import Foundation

/// 云端同步连哪一套 yadoA_be：线上，或开发机上用 `pnpm dev` 跑起来的本地服务。
///
/// 只有 `yadoA-local` 构建（`DeveloperTools.isLocalBuild`）会连本地，其他包始终连线上。本地地址由 `yadoA-local` Scheme 的
/// 启动环境变量指定，见 `applyLaunchEnvironment(_:defaults:)`；之后从桌面直接打开 App 也保持上次的地址。
/// 地址在启动时确定，App 运行期间不变；与上次同步用的地址不同时，由 `SyncLifecycle.resetIfEndpointChanged(to:)` 解除绑定。
///
/// 本地服务和线上一样校验线上 Logto 签发的 token，登录账号与线上通用。
enum SyncServiceEnvironment {
    /// 本地服务地址的存储键。
    static let localEndpointStorageKey = "debug.syncService.localEndpoint"

    /// Scheme 中指定本地服务地址的启动环境变量。
    static let launchLocalEndpointKey = "YADO_SYNC_LOCAL_ENDPOINT"

    /// 本次启动同步要连的地址：`yadoA-local` 构建且配置了合法的本地地址时为本地，否则为线上。
    static var currentEndpoint: URL {
        #if DEBUG
        guard DeveloperTools.isLocalBuild,
              let text = UserDefaults.standard.string(forKey: localEndpointStorageKey),
              let url = AIServiceEnvironment.localEndpoint(from: text)
        else { return SyncAPI.productionEndpoint }
        return url
        #else
        return SyncAPI.productionEndpoint
        #endif
    }

    /// 按 Xcode Scheme 的启动环境变量写入本地地址；没有该变量或地址不合法时保持原样。只在 DEBUG 包生效。
    ///
    /// - Parameters:
    ///   - environment: 进程的环境变量。
    ///   - defaults: 写入的设置。
    static func applyLaunchEnvironment(_ environment: [String: String], defaults: UserDefaults = .standard) {
        #if DEBUG
        if let endpoint = environment[launchLocalEndpointKey], AIServiceEnvironment.localEndpoint(from: endpoint) != nil {
            defaults.set(endpoint, forKey: localEndpointStorageKey)
        }
        #endif
    }
}
