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

    /// 已登录用户的资料；未登录或解析失败时为 nil。
    private(set) var profile: AccountProfile?

    /// 已登录用户的展示名称：优先取昵称，没有时取用户名；未登录或资料为空时为 nil。
    var displayName: String? {
        profile?.displayName
    }

    /// 最近一次登录失败的错误详情；用户主动取消登录不计为错误，界面展示后应调用 `dismissError()` 清除。
    private(set) var errorMessage: String?

    /// 是否正在执行登录或退出，用于禁用按钮避免重复触发。
    private(set) var isBusy = false

    private let client: LogtoClient

    init() {
        let client = Self.makeClient()
        self.client = client
        isAuthenticated = client.isAuthenticated
        profile = Self.readProfile(from: client)
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
            profile = Self.readProfile(from: client)
        } catch {
            isAuthenticated = client.isAuthenticated
            profile = Self.readProfile(from: client)
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
        profile = nil
    }

    /// 从 Logto 拉取最新资料，覆盖登录时 ID token 里的快照。
    ///
    /// ID token 只记录登录那一刻的资料，在其他端改过昵称后需靠这里刷新；
    /// 失败时静默保留现有资料，不打扰用户。
    func refreshProfile() async {
        guard client.isAuthenticated, let userInfo = try? await client.fetchUserInfo() else {
            return
        }
        // 等待期间可能已退出登录，此时不能把资料写回
        guard isAuthenticated else { return }
        profile = AccountProfile(
            name: userInfo.name,
            username: userInfo.username,
            avatarURL: userInfo.picture.flatMap(URL.init(string:))
        )
    }

    /// 修改昵称和 / 或用户名，成功后立即更新本地资料。
    ///
    /// 修改用户名属于敏感操作，Logto 要求先用密码验证身份，因此此时必须传入 `password`。
    /// - Parameters:
    ///   - name: 新昵称；外层 nil 表示不修改，内层 nil 表示清空。
    ///   - username: 新用户名；nil 表示不修改。
    ///   - password: 修改用户名时用于验证身份的当前密码。
    /// - Throws: `AccountProfileError`。
    func updateProfile(name: String??, username: String?, password: String?) async throws {
        let api = LogtoAccountAPI(endpoint: Self.endpointURL)
        let accessToken: String
        do {
            // 不指定资源时拿到的是访问 Logto 用户接口的 token，SDK 会在过期时自动续期
            accessToken = try await client.getAccessToken(for: nil)
        } catch {
            throw AccountProfileError.notAllowed
        }

        var verificationID: String?
        if username != nil {
            guard let password, !password.isEmpty else {
                throw AccountProfileError.wrongPassword
            }
            verificationID = try await api.verifyPassword(password, accessToken: accessToken)
        }

        let updated = try await api.updateProfile(
            name: name,
            username: username,
            verificationID: verificationID,
            accessToken: accessToken
        )
        guard isAuthenticated else { return }
        // 头像当前只读，接口未返回时沿用已有地址
        profile = AccountProfile(
            name: updated.name,
            username: updated.username,
            avatarURL: updated.avatarURL ?? profile?.avatarURL
        )
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

    /// Logto 服务地址；`AuthConfig.endpoint` 已在创建客户端时校验过合法性。
    private static var endpointURL: URL {
        guard let url = URL(string: AuthConfig.endpoint) else {
            preconditionFailure("AuthConfig.endpoint 不是合法 URL：\(AuthConfig.endpoint)")
        }
        return url
    }

    /// 从 ID token 中读取登录时的资料快照，未登录或解析失败时返回 nil。
    private static func readProfile(from client: LogtoClient) -> AccountProfile? {
        guard client.isAuthenticated, let claims = try? client.getIdTokenClaims() else {
            return nil
        }
        return AccountProfile(
            name: claims.name,
            username: claims.username,
            avatarURL: claims.picture.flatMap(URL.init(string:))
        )
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
