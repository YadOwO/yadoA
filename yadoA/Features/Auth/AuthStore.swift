import Foundation
import Logto
import LogtoClient
import Observation

/// 登录状态中心：封装 Logto 客户端，向界面暴露登录态与用户信息。
///
/// 登录由 SDK 打开 Logto 托管的登录页完成，App 自身不接触用户密码；
/// 凭证的持久化与续期由 SDK 处理（存于 Keychain）。
/// 登录与否不影响本地账本：记账、账户等数据始终保存在本机，不读取登录身份。
@Observable
final class AuthStore {
    /// 本地是否持有有效凭证。
    private(set) var isAuthenticated: Bool

    /// 已登录用户的展示名称：优先取昵称，没有时取用户名；未登录或解析失败时为 nil。
    private(set) var displayName: String?

    /// 最近一次登录失败的错误详情；用户主动取消登录不计为错误，界面展示后应调用 `dismissError()` 清除。
    private(set) var errorMessage: String?

    /// 是否正在执行登录或退出，用于禁用按钮避免重复触发。
    private(set) var isBusy = false

    private let client: LogtoClient

    init() {
        let client = Self.makeClient()
        self.client = client
        isAuthenticated = client.isAuthenticated
        displayName = Self.readDisplayName(from: client)
    }

    /// 发起登录，弹出 Logto 托管的登录 / 注册页。
    func signIn() async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        do {
            try await client.signInWithBrowser(redirectUri: AuthConfig.redirectUri)
            isAuthenticated = true
            displayName = Self.readDisplayName(from: client)
        } catch {
            isAuthenticated = client.isAuthenticated
            displayName = Self.readDisplayName(from: client)
            // 用户点了关闭不是异常，不必打扰
            errorMessage = Self.isUserCancellation(error) ? nil : Self.describe(error)
        }
    }

    /// 退出登录并清除本机凭证，不触碰本地账本数据。
    func signOut() async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        // 返回值仅表示“撤销远端 refresh token 失败”，本地凭证此时已清空，可安全忽略
        await client.signOut()
        isAuthenticated = client.isAuthenticated
        displayName = nil
    }

    /// 错误提示展示完毕后清除，避免下次进入页面重复弹出。
    func dismissError() {
        errorMessage = nil
    }

    // MARK: - 私有方法

    private static func makeClient() -> LogtoClient {
        // LogtoConfig 仅在 endpoint 不是合法 URL 时抛错，属于配置写错，应尽早暴露
        guard let config = try? LogtoConfig(endpoint: AuthConfig.endpoint, appId: AuthConfig.appId) else {
            preconditionFailure("AuthConfig.endpoint 不是合法 URL：\(AuthConfig.endpoint)")
        }
        return LogtoClient(useConfig: config)
    }

    /// 从 ID token 中读取展示名称；空白字符串视为缺失。
    private static func readDisplayName(from client: LogtoClient) -> String? {
        guard client.isAuthenticated, let claims = try? client.getIdTokenClaims() else {
            return nil
        }
        return [claims.name, claims.username]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// 判断错误是否为用户主动关闭了登录页。
    ///
    /// iOS 上 SDK 使用内置网页登录会话，用户关掉登录页时 SDK 抛出
    /// `SignIn(type: .authFailed, innerError: nil)`，这是 SDK 中唯一抛该组合的位置，故可据此识别。
    /// 已知局限：页面加载失败时也需要用户手动关闭，同样会被归为取消而不提示。
    private static func isUserCancellation(_ error: Error) -> Bool {
        guard let signInError = error as? LogtoClientErrors.SignIn else {
            return false
        }
        return signInError.type == .authFailed && signInError.innerError == nil
    }

    /// 把错误转成便于排查的详情文本，尽量带上 SDK 的错误类型。
    private static func describe(_ error: Error) -> String {
        guard let signInError = error as? LogtoClientErrors.SignIn else {
            return error.localizedDescription
        }
        guard let innerError = signInError.innerError else {
            return signInError.type.rawValue
        }
        return "\(signInError.type.rawValue): \(innerError.localizedDescription)"
    }
}
