import Foundation

/// 这个包连哪一套环境。一套环境包含：登录（Logto）、各后端的默认地址、本机数据。
///
/// 由编译条件决定，不走运行时环境变量：从桌面直接打开的 App 读不到 Xcode Scheme 注入的变量，
/// 而登录、后端和本机数据必须整套一起切换（dev Logto 签发的 token 线上后端不认，反过来也一样）。
///
/// 环境标志与 `DEBUG` 无关：「连哪一套」和「能不能断点调试」是两件事。
/// 各构建配置的 `SWIFT_ACTIVE_COMPILATION_CONDITIONS` 与 Bundle ID：
///
/// | 配置       | 标志               | 环境 | Bundle ID            | 用途                   |
/// |------------|--------------------|------|----------------------|------------------------|
/// | Debug      | `DEBUG` `ENV_DEV`  | dev  | `com.yado.yadoA.dev` | 日常开发、测试         |
/// | DebugProd  | `DEBUG` `ENV_PROD` | 线上 | `com.yado.yadoA`     | 断点排查线上问题       |
/// | Release    | `ENV_PROD`         | 线上 | `com.yado.yadoA`     | 出包                   |
///
/// dev 包与线上包的 Bundle ID 不同，系统把它们当成两个 App：数据库、设置、钥匙串里的登录状态各一份，
/// 可以同时装在一台设备上，dev 的数据不会同步到线上账号。
nonisolated enum AppEnvironment: String, Sendable {
    /// 开发环境：Mac mini 上的整套 dev 服务（独立的 Logto、数据库和各后端），经 Tailscale 访问。
    case dev

    /// 线上环境。
    case prod

    /// 当前构建所连的环境。
    static let current: AppEnvironment = {
        #if ENV_DEV
        return .dev
        #elseif ENV_PROD
        return .prod
        #else
        // 新增构建配置时漏配环境标志，在这里直接编译失败，而不是悄悄连到错误的环境
        #error("当前构建配置没有环境标志，请在 SWIFT_ACTIVE_COMPILATION_CONDITIONS 中添加 ENV_DEV 或 ENV_PROD")
        #endif
    }()
}
