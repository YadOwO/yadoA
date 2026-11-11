import Foundation

/// AI 服务连哪一个：当前环境部署的那个（`AuthConfig.aiServiceEndpoint`，见 `AppEnvironment`），
/// 或开发机上用 `pnpm dev` 跑起来的本机 yado_ai。
///
/// 只有 dev 环境的包可以改连本机，线上包（DebugProd、Release）始终连线上：本机服务按 dev Logto 校验 token，
/// 也避免把线上账号的内容发到开发机。切换方式有两种：
/// - Xcode 里选 `yadoA-local` / `yadoA` Scheme 运行：Scheme 通过启动环境变量指定，见 `applyLaunchEnvironment(_:)`；
/// - App 内「我的 → 开发 → AI 服务」（开发入口在头像右上角）。
/// 两种方式写入同一份设置，之后从桌面直接打开 App 也保持上次的选择。
///
/// 登录走当前环境的 Logto：本机服务的 `LOGTO_ISSUER` 要指向 dev Logto，或开启免鉴权忽略 token。
enum AIServiceEnvironment: String, CaseIterable, Identifiable {
    /// 当前环境部署的服务 `AuthConfig.aiServiceEndpoint`：dev 包是 Mac mini 上的，线上包是线上的。
    case remote

    /// 开发机本机的服务，地址见 `localEndpoint`。
    case local

    /// 当前选择的存储键。
    static let storageKey = "debug.aiService.environment"

    /// 本地服务地址的存储键。
    static let localEndpointStorageKey = "debug.aiService.localEndpoint"

    /// 本地服务的默认地址：模拟器可以直接访问 Mac 的 localhost；真机需改成 Mac 的局域网地址。
    static let defaultLocalEndpoint = "http://localhost:7790"

    /// Scheme 中指定连哪一个的启动环境变量，取值为 `local` 或 `remote`。
    static let launchEnvironmentKey = "YADO_AI_SERVICE"

    /// Scheme 中指定本地服务地址的启动环境变量。
    static let launchLocalEndpointKey = "YADO_AI_LOCAL_ENDPOINT"

    /// 稳定标识。
    var id: Self { self }

    /// 选项名称的本地化键。
    var titleLocalizationKey: String {
        switch self {
        case .remote: "debug.aiService.remote"
        case .local: "debug.aiService.local"
        }
    }

    /// 当前选择；只有 dev 环境里显示「开发」页面的包（`DeveloperTools.isEnabled`）可能为本机，其他包始终连当前环境部署的服务。
    static var current: AIServiceEnvironment {
        #if DEBUG
        guard AppEnvironment.current == .dev, DeveloperTools.isEnabled else { return .remote }
        let rawValue = UserDefaults.standard.string(forKey: storageKey) ?? ""
        return AIServiceEnvironment(rawValue: rawValue) ?? .remote
        #else
        return .remote
        #endif
    }

    /// 当前环境部署的服务地址；`AuthConfig.aiServiceEndpoint` 是写死的常量，非法即为配置错误。
    static var defaultEndpoint: URL {
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

    /// 本次请求要连的地址：选了本机且地址合法时为本机，否则为当前环境部署的服务。每次请求时读取，切换后立即生效。
    static var currentEndpoint: URL {
        guard current == .local else { return defaultEndpoint }
        let text = UserDefaults.standard.string(forKey: localEndpointStorageKey) ?? defaultLocalEndpoint
        return localEndpoint(from: text) ?? defaultEndpoint
    }
}
