import Foundation

/// AI 服务连哪一套：线上，或开发机上用 `pnpm dev` 跑起来的本地 yado_ai。
///
/// 只有本地开发包（`DeveloperTools.isEnabled`）可以切换，其他包始终连线上。切换方式有两种：
/// - Xcode 里选 `yadoA-local` / `yadoA` Scheme 运行：Scheme 通过启动环境变量指定，见 `applyLaunchEnvironment(_:)`；
/// - App 内「我的 → 开发 → AI 服务」（开发入口在头像右上角）。
/// 两种方式写入同一份设置，之后从桌面直接打开 App 也保持上次的选择。
///
/// 登录仍走线上 Logto，本地服务开启免鉴权时忽略 token，未开启时同样能校验线上签发的 token。
enum AIServiceEnvironment: String, CaseIterable, Identifiable {
    /// 线上服务 `AuthConfig.aiServiceEndpoint`。
    case production

    /// 本地服务，地址见 `localEndpoint`。
    case local

    /// 当前选择的存储键。
    static let storageKey = "debug.aiService.environment"

    /// 本地服务地址的存储键。
    static let localEndpointStorageKey = "debug.aiService.localEndpoint"

    /// 本地服务的默认地址：模拟器可以直接访问 Mac 的 localhost；真机需改成 Mac 的局域网地址。
    static let defaultLocalEndpoint = "http://localhost:7790"

    /// Scheme 中指定连哪一套的启动环境变量，取值为 `local` 或 `production`。
    static let launchEnvironmentKey = "YADO_AI_SERVICE"

    /// Scheme 中指定本地服务地址的启动环境变量。
    static let launchLocalEndpointKey = "YADO_AI_LOCAL_ENDPOINT"

    /// 稳定标识。
    var id: Self { self }

    /// 选项名称的本地化键。
    var titleLocalizationKey: String {
        switch self {
        case .production: "debug.aiService.production"
        case .local: "debug.aiService.local"
        }
    }

    /// 当前选择；只有本地开发包（`DeveloperTools.isEnabled`）可能为本地，其他包始终为线上。
    static var current: AIServiceEnvironment {
        #if DEBUG
        guard DeveloperTools.isEnabled else { return .production }
        let rawValue = UserDefaults.standard.string(forKey: storageKey) ?? ""
        return AIServiceEnvironment(rawValue: rawValue) ?? .production
        #else
        return .production
        #endif
    }

    /// 线上服务地址；`AuthConfig.aiServiceEndpoint` 是写死的常量，非法即为配置错误。
    static var productionEndpoint: URL {
        guard let url = URL(string: AuthConfig.aiServiceEndpoint) else {
            preconditionFailure("AuthConfig.aiServiceEndpoint 不是合法 URL：\(AuthConfig.aiServiceEndpoint)")
        }
        return url
    }

    /// 解析本地服务地址：必须是带主机名的 http 或 https 地址。
    ///
    /// - Parameter text: 填写的地址，如 `http://my-mac.local:7790`。
    /// - Returns: 地址；不合法时为空。
    static func localEndpoint(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host() != nil
        else { return nil }
        return url
    }

    /// 按 Xcode Scheme 的启动环境变量写入设置；没有设置这些变量（如从桌面打开）时保持原样。只在 DEBUG 包生效。
    ///
    /// - Parameters:
    ///   - environment: 进程的环境变量。
    ///   - defaults: 写入的设置。
    static func applyLaunchEnvironment(_ environment: [String: String], defaults: UserDefaults = .standard) {
        #if DEBUG
        if let rawValue = environment[launchEnvironmentKey], let selection = AIServiceEnvironment(rawValue: rawValue) {
            defaults.set(selection.rawValue, forKey: storageKey)
        }
        if let endpoint = environment[launchLocalEndpointKey], localEndpoint(from: endpoint) != nil {
            defaults.set(endpoint, forKey: localEndpointStorageKey)
        }
        #endif
    }

    /// 本次请求要连的地址：选了本地且地址合法时为本地，否则为线上。每次请求时读取，切换后立即生效。
    static var currentEndpoint: URL {
        guard current == .local else { return productionEndpoint }
        let text = UserDefaults.standard.string(forKey: localEndpointStorageKey) ?? defaultLocalEndpoint
        return localEndpoint(from: text) ?? productionEndpoint
    }
}
