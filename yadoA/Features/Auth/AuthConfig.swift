import Foundation

/// 登录（Logto）与各后端的配置，按环境取值，见 `AppEnvironment`。
///
/// 每套环境有自己的 Logto：线上的与 yadoI 共用同一租户（同一账号两个 App 通用）；dev 的部署在 Mac mini 上，
/// 账号、应用都与线上无关。业务代码只读 `AuthConfig.endpoint` 这类当前环境的值，不要自己按环境分支。
nonisolated enum AuthConfig {
    /// 随环境变化的一组取值。
    nonisolated struct Values: Sendable {
        /// Logto 服务地址（不含路径），OIDC issuer 由 Logto 拼成 `{endpoint}/oidc`。
        let endpoint: String

        /// Logto Console 中 yadoA 原生应用的 App ID；每套 Logto 的应用是独立的。
        let appId: String

        /// 登录完成后的回调地址，必须与 Logto 应用配置中的 Redirect URI 完全一致。
        ///
        /// scheme 必须全小写：SDK 内部会对 scheme 调用 `lowercased()`，
        /// 若写成 Bundle ID 原样的 `com.yado.yadoA`，回调将无法匹配。
        let redirectUri: String

        /// AI 交互服务（yado_ai）的地址（不含路径）。
        let aiServiceEndpoint: String

        /// yadoA 后端（yadoA_be，云端同步）的地址（不含路径）。
        let syncServiceEndpoint: String

        /// 芽豆公共服务（yado_hub）的地址（不含路径）。
        let hubServiceEndpoint: String

        /// 这套环境是否提供“帮助改进 AI”（向 yado_ai 发送 `X-AI-Trace-Consent`，由服务端把内容上报给 Langfuse）。
        ///
        /// Langfuse 写进隐私政策和第三方共享清单之前，线上必须为 false；之后要开，先改政策并部署，再把 prod 改为 true。
        let isAITraceConsentAvailable: Bool

        /// 这套环境是否开放邮箱账号：登录页的「邮箱登录」按钮，以及「账号与安全」里绑定 / 更换邮箱的入口。
        ///
        /// 线上暂时为 false：线上 Logto 版本较旧，不支持只有 Apple 的用户验证身份要用的 OIDC step-up
        /// （线上 OIDC discovery 里没有 `acr_values_supported`），也还没配邮件连接器，发不出验证码。
        /// 升级线上 Logto、配好邮件连接器和账户中心字段（见 `docs/todos/2026-10-18-auth-profile-todo.md`
        /// 的「Logto 后台配置清单」）之后，再把 prod 改为 true。为 false 时邮箱行只读显示。
        let isEmailAccountAvailable: Bool
    }

    // 两套取值对模块内可见（而非 private），测试可以同时断言两套环境；业务代码只读下面的当前值。

    /// dev 环境：Mac mini 上的整套服务，对外是公网域名（`dev-` 开头），由云服务器的 nginx 转发到 mini。
    /// 设备不需要装 Tailscale，能上网就能访问。
    static let dev = Values(
        endpoint: "https://dev-accounts.yado1225.top",
        appId: "7snnjg90shlsuamug4zez",
        redirectUri: "com.yado.yadoa.dev://callback",
        aiServiceEndpoint: "https://dev-ai-api.yado1225.top",
        syncServiceEndpoint: "https://dev-yadoa-api.yado1225.top",
        hubServiceEndpoint: "https://dev-hub-api.yado1225.top",
        isAITraceConsentAvailable: true,
        isEmailAccountAvailable: true
    )

    /// 线上环境。
    static let prod = Values(
        endpoint: "https://accounts.yado1225.top",
        appId: "rgne9x102v0qrifpqakl6",
        redirectUri: "com.yado.yadoa://callback",
        aiServiceEndpoint: "https://ai-api.yado1225.top",
        syncServiceEndpoint: "https://yadoa-api.yado1225.top",
        hubServiceEndpoint: "https://hub-api.yado1225.top",
        isAITraceConsentAvailable: false,
        isEmailAccountAvailable: false
    )

    /// 当前环境的取值。
    static var current: Values {
        switch AppEnvironment.current {
        case .dev: dev
        case .prod: prod
        }
    }

    /// Logto 服务地址（不含路径）。
    static var endpoint: String { current.endpoint }

    /// Logto Console 中 yadoA 原生应用的 App ID。
    static var appId: String { current.appId }

    /// 登录完成后的回调地址。
    static var redirectUri: String { current.redirectUri }

    /// AI 交互服务（yado_ai）在 Logto 中注册的 API resource 标识；调用 AI 接口时请求它的 access token。
    ///
    /// 它只是标识字符串，不要求可访问，两套环境用同一个值。
    /// 登录时必须一并申请该 resource，否则 refresh token 无法换取它的 access token；
    /// 新增 resource 前已登录的设备需要重新登录一次。
    static let aiServiceResource = "https://api.yado1225.top/ai"

    /// AI 交互服务在当前环境的地址（不含路径）。
    static var aiServiceEndpoint: String { current.aiServiceEndpoint }

    /// AI 交互服务在当前环境的地址，供发请求用。
    static var aiServiceURL: URL { url(aiServiceEndpoint, name: "aiServiceEndpoint") }

    /// yadoA 后端（yadoA_be，云端同步）在 Logto 中注册的 API resource 标识；调用同步接口时请求它的 access token。
    ///
    /// 与后端的 `LOGTO_AUDIENCE` 逐字一致，两套环境用同一个值；登录时同样必须一并申请，新增前已登录的设备需要重新登录一次。
    static let syncServiceResource = "https://api.yado1225.top/yadoa"

    /// yadoA 后端在当前环境的地址（不含路径）。
    static var syncServiceEndpoint: String { current.syncServiceEndpoint }

    /// yadoA 后端在当前环境的地址，供发请求用。
    static var syncServiceURL: URL { url(syncServiceEndpoint, name: "syncServiceEndpoint") }

    /// 芽豆公共服务（yado_hub：意见反馈等各产品共用的功能）在 Logto 中注册的 API resource 标识；调用公共服务接口时请求它的 access token。
    ///
    /// 与后端的 `LOGTO_AUDIENCE` 逐字一致，两套环境用同一个值；登录时同样必须一并申请，新增前已登录的设备需要重新登录一次。
    /// Logto 后台必须先建好这个 resource：登录时申请了不存在的 resource，整个登录都会失败。
    static let hubServiceResource = "https://api.yado1225.top/hub"

    /// 芽豆公共服务在当前环境的地址（不含路径）。
    static var hubServiceEndpoint: String { current.hubServiceEndpoint }

    /// 芽豆公共服务在当前环境的地址，供发请求用。
    static var hubServiceURL: URL { url(hubServiceEndpoint, name: "hubServiceEndpoint") }

    /// 当前环境是否提供“帮助改进 AI”；为 false 时没有入口和页面，也不会带上报头。
    static var isAITraceConsentAvailable: Bool { current.isAITraceConsentAvailable }

    /// 当前环境是否开放邮箱账号（邮箱登录、绑定 / 更换邮箱）；为 false 时没有这两个入口，邮箱行只读。
    static var isEmailAccountAvailable: Bool { current.isEmailAccountAvailable }

    /// 把写死的地址转成 URL；地址是常量，非法即为配置写错，应尽早暴露。
    private static func url(_ text: String, name: String) -> URL {
        guard let url = URL(string: text) else {
            preconditionFailure("AuthConfig.\(name) 不是合法 URL：\(text)")
        }
        return url
    }
}
