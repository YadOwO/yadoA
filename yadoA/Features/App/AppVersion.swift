import Foundation

/// App 版本号的统一出口：联网请求的 `X-App-Version` 请求头、「我的」页和反馈里显示的版本都从这里取。
///
/// 必须是 `nonisolated`：工程默认隔离是 MainActor，而同步客户端会在 `@concurrent` 的后台任务里读取它。
nonisolated enum AppVersion {
    /// 版本请求头的名字，与 yadoA_be、yado_ai 的 `shared/app-version.ts` 里的 `APP_VERSION_HEADER` 一致。
    static let headerName = "X-App-Version"

    /// 读取版本号字符串，格式为「营销版本 (构建号)」，例如 `1.0 (12)`；构建号为空时只返回营销版本号。
    ///
    /// - Parameter bundle: 读取版本信息的资源包，默认是主 App。
    /// - Returns: 版本号字符串；营销版本号也读不到时为空字符串。
    static func string(bundle: Bundle = .main) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }

    /// 当前 App 的版本号字符串；启动后不会变，只算一次。
    static let current: String = string()

    /// 当前 App 的营销版本号（`CFBundleShortVersionString`，例如 `1.2.0`），不带构建号；
    /// 和 App Store 上的版本号比较新旧时用它。读不到时为空字符串。
    static let marketingVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    /// 给请求带上版本请求头；当前版本号为空时不带。
    ///
    /// - Parameter request: 要设置请求头的请求。
    static func apply(to request: inout URLRequest) {
        guard !current.isEmpty else { return }
        request.setValue(current, forHTTPHeaderField: headerName)
    }
}
