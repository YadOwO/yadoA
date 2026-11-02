import Foundation

/// 芽豆公共服务（yado_hub）连哪一套：线上，或开发机上用 `pnpm dev` 跑起来的本地服务。
///
/// 与 `SyncServiceEnvironment` 一致：只有 `yadoA-local` 构建（`DeveloperTools.isLocalBuild`）会连本地，其他包始终连线上。
/// 本地地址由 `yadoA-local` Scheme 的启动环境变量指定，见 `applyLaunchEnvironment(_:defaults:)`；之后从桌面直接打开 App
/// 也保持上次的地址。登录仍走线上 Logto，本地服务开启免鉴权时忽略 token。
enum HubServiceEnvironment {
    /// 本地服务地址的存储键。
    static let localEndpointStorageKey = "debug.hubService.localEndpoint"

    /// Scheme 中指定本地服务地址的启动环境变量。
    static let launchLocalEndpointKey = "YADO_HUB_LOCAL_ENDPOINT"

    /// 线上服务地址；`AuthConfig.hubServiceEndpoint` 是写死的常量，非法即为配置错误。
    static var productionEndpoint: URL {
        guard let url = URL(string: AuthConfig.hubServiceEndpoint) else {
            preconditionFailure("AuthConfig.hubServiceEndpoint 不是合法 URL：\(AuthConfig.hubServiceEndpoint)")
        }
        return url
    }

    /// 本次请求要连的地址：`yadoA-local` 构建且配置了合法的本地地址时为本地，否则为线上。
    static var currentEndpoint: URL {
        #if DEBUG
        guard DeveloperTools.isLocalBuild,
              let text = UserDefaults.standard.string(forKey: localEndpointStorageKey),
              let url = AIServiceEnvironment.localEndpoint(from: text)
        else { return productionEndpoint }
        return url
        #else
        return productionEndpoint
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
