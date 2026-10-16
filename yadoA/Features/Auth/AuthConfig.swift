import Foundation

/// Logto 登录配置，与服务器上 Logto Console 中名为 yadoA 的原生应用一一对应。
///
/// 目前只有线上一套 Logto（与 yadoI 共用同一租户，同一账号两个 App 通用），
/// Debug 与 Release 构建都连它；以后若需要多环境，再把这里的值按构建配置拆开。
enum AuthConfig {
    /// Logto 服务地址（不含路径），OIDC issuer 由 Logto 拼成 `{endpoint}/oidc`。
    static let endpoint = "https://accounts.yado1225.top"

    /// Logto Console 中 yadoA 原生应用的 App ID。
    static let appId = "rgne9x102v0qrifpqakl6"

    /// 登录完成后的回调地址，必须与 Logto 应用配置中的 Redirect URI 完全一致。
    ///
    /// scheme 必须全小写：SDK 内部会对 scheme 调用 `lowercased()`，
    /// 若写成 Bundle ID 原样的 `com.yado.yadoA`，回调将无法匹配。
    static let redirectUri = "com.yado.yadoa://callback"
}
