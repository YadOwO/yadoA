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

    /// 头像上传器；凭证来源目前是 Debug 构建注入的本地密钥。
    // TODO: 接入服务端 STS 签发后，把这里换成 STS 凭证来源，详见 `BundledOSSCredentialProvider` 上的说明。
    private let avatarUploader = AvatarUploader(credentialProvider: BundledOSSCredentialProvider())

    /// 当前构建是否可以更换头像：需已登录且本地配置了上传凭证（仅 Debug 构建）。
    var canChangeAvatar: Bool {
        isAuthenticated && BundledOSSCredentialProvider().isAvailable
    }

    private let client: LogtoClient

    init() {
        let client = Self.makeClient()
        self.client = client
        isAuthenticated = client.isAuthenticated
        profile = Self.readProfile(from: client)
    }

    /// 发起登录，弹出 Logto 托管的登录 / 注册页。
    ///
    /// - Parameter provider: 指定第三方登录方式时跳过 Logto 的方式选择，直接进入该连接器；nil 时走账号密码页。
    func signIn(provider: AuthSocialProvider? = nil) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        do {
            try await client.signInWithBrowser(
                redirectUri: AuthConfig.redirectUri,
                directSignIn: provider.map { LogtoCore.DirectSignInOptions(method: .social, target: $0.connectorTarget) }
            )
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
    /// 网络等临时失败时静默保留现有资料；凭证已失效（被撤销、用户被删除）时清除本地凭证，界面回到未登录。
    func refreshProfile() async {
        guard client.isAuthenticated else { return }
        let userInfo: LogtoCore.UserInfoResponse
        do {
            userInfo = try await client.fetchUserInfo()
        } catch {
            await clearCredentialsIfRevoked(error)
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

    /// 获取调用 AI 交互服务的 access token；SDK 会缓存并在过期时用 refresh token 续期。
    ///
    /// - Returns: 面向 `AuthConfig.aiServiceResource` 的 access token。
    /// - Throws: `ServiceAuthError`，见 `accessToken(forResource:)`。
    func accessTokenForAIService() async throws -> String {
        try await accessToken(forResource: AuthConfig.aiServiceResource)
    }

    /// 获取调用 yadoA 后端（云端同步）的 access token；SDK 会缓存并在过期时用 refresh token 续期。
    ///
    /// - Returns: 面向 `AuthConfig.syncServiceResource` 的 access token。
    /// - Throws: `ServiceAuthError`，见 `accessToken(forResource:)`。
    func accessTokenForSyncService() async throws -> String {
        try await accessToken(forResource: AuthConfig.syncServiceResource)
    }

    /// 把处理好的头像上传到 OSS，返回公开访问地址；此时尚未写入 Logto 资料。
    ///
    /// - Parameter jpegData: `AvatarImageProcessor` 输出的 JPEG 数据。
    /// - Throws: `AvatarUploadError`。
    func uploadAvatar(jpegData: Data) async throws -> URL {
        // sub 是 Logto 用户的稳定 ID，不随改用户名变化，作为头像目录名
        guard client.isAuthenticated, let userID = try? client.getIdTokenClaims().sub, !userID.isEmpty else {
            throw AvatarUploadError.notSignedIn
        }
        return try await avatarUploader.upload(jpegData: jpegData, userID: userID)
    }

    /// 修改昵称和 / 或头像，成功后立即更新本地资料。
    ///
    /// 用户名同时是登录标识，暂不开放修改（Logto Account Center 中该字段应设为只读）；
    /// 后续若开放，需由服务端控制修改频率，不走这里直连 Account API。
    /// - Parameters:
    ///   - name: 新昵称；外层 nil 表示不修改，内层 nil 表示清空。
    ///   - avatar: 已上传到 OSS 的新头像地址；nil 表示不修改。
    /// - Throws: `AccountProfileError`。
    func updateProfile(name: String??, avatar: URL? = nil) async throws {
        let api = LogtoAccountAPI(endpoint: Self.endpointURL)
        let accessToken: String
        do {
            // 不指定资源时拿到的是访问 Logto 用户接口的 token，SDK 会在过期时自动续期
            accessToken = try await client.getAccessToken(for: nil)
        } catch {
            throw AccountProfileError.notAllowed
        }

        let updated = try await api.updateProfile(
            name: name,
            username: nil,
            avatar: avatar,
            verificationID: nil,
            accessToken: accessToken
        )
        guard isAuthenticated else { return }
        // 接口未返回头像时，优先用本次提交的地址，其次沿用已有地址
        profile = AccountProfile(
            name: updated.name,
            username: updated.username,
            avatarURL: updated.avatarURL ?? avatar ?? profile?.avatarURL
        )
    }

    /// 错误提示展示完毕后清除，避免下次进入页面重复弹出。
    func dismissError() {
        errorMessage = nil
    }

    // MARK: - 私有方法

    /// 获取指定 API resource 的 access token。
    ///
    /// - Parameter resource: 登录时已申请的 API resource 标识。
    /// - Returns: access token。
    /// - Throws: 未登录时抛出 `ServiceAuthError.notSignedIn`；凭证已失效时清除本地凭证并抛出
    ///   `ServiceAuthError.sessionExpired`；网络等其他失败抛出 `ServiceAuthError.unavailable`。
    private func accessToken(forResource resource: String) async throws -> String {
        guard client.isAuthenticated else { throw ServiceAuthError.notSignedIn }
        do {
            return try await client.getAccessToken(for: resource)
        } catch {
            if await clearCredentialsIfRevoked(error) {
                throw ServiceAuthError.sessionExpired
            }
            throw ServiceAuthError.unavailable
        }
    }

    /// 凭证已失效时清除本地凭证并回到未登录状态；网络等临时失败不处理。
    ///
    /// - Parameter error: 获取 token 或刷新资料时 SDK 抛出的错误。
    /// - Returns: 是否判定为凭证失效并已清除。
    @discardableResult
    private func clearCredentialsIfRevoked(_ error: Error) async -> Bool {
        guard Self.isCredentialRevoked(error) else { return false }
        // 远端 refresh token 已不可用，撤销失败可以忽略；SDK 会先清空本地凭证
        await client.signOut()
        isAuthenticated = client.isAuthenticated
        profile = nil
        return true
    }

    /// 判断错误是否表示本地凭证已不可用，需要重新登录。
    ///
    /// - 本地没有 refresh token；
    /// - Logto token 接口返回 400，且错误为 `invalid_grant`（refresh token 过期、被撤销或用户被删除）
    ///   或 `invalid_target`（登录时没有申请所需的 API resource，例如新增 resource 前已登录的设备）。
    ///
    /// 资料接口的错误会把 token 错误包在 `innerError` 里，因此沿 `innerError` 逐层查找。
    static func isCredentialRevoked(_ error: Error) -> Bool {
        var current: Error? = error
        while let error = current {
            if let tokenError = error as? LogtoClientErrors.AccessToken {
                if tokenError.type == .noRefreshTokenFound { return true }
                current = tokenError.innerError
            } else if let userInfoError = error as? LogtoClientErrors.UserInfo {
                current = userInfoError.innerError
            } else if case let .withCode(code, _, data)? = error as? LogtoErrors.Response {
                return isRevokedTokenResponse(statusCode: code, body: data)
            } else {
                return false
            }
        }
        return false
    }

    /// 判断 Logto token 接口的错误响应是否表示凭证已不可用。
    ///
    /// - Parameters:
    ///   - statusCode: HTTP 状态码。
    ///   - body: 响应体；标准 OAuth 格式为 `{ "error": "invalid_grant" }`，Logto 也可能返回
    ///     `{ "code": "oidc.invalid_grant" }`。
    /// - Returns: 400 且错误为 `invalid_grant` 或 `invalid_target` 时返回 `true`。
    static func isRevokedTokenResponse(statusCode: Int, body: Data?) -> Bool {
        guard statusCode == 400,
              let body,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return false }
        let errorCodes = [object["error"], object["code"]].compactMap { $0 as? String }
        return errorCodes.contains { code in
            code.hasSuffix("invalid_grant") || code.hasSuffix("invalid_target")
        }
    }

    private static func makeClient() -> LogtoClient {
        // LogtoConfig 仅在 endpoint 不是合法 URL 时抛错，属于配置写错，应尽早暴露
        guard let config = try? LogtoConfig(
            endpoint: AuthConfig.endpoint,
            appId: AuthConfig.appId,
            resources: [AuthConfig.aiServiceResource, AuthConfig.syncServiceResource]
        ) else {
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
    /// 但 SDK 1.2.0 的 `LogtoAuthSession.start()` 会把它再包一层 `SignIn(type: .unknownError, innerError: …)`，
    /// 因此需要沿 `innerError` 逐层向内查找。
    /// 已知局限：页面加载失败时也需要用户手动关闭，同样会被归为取消而不提示。
    private static func isUserCancellation(_ error: Error) -> Bool {
        var current: Error? = error
        while let signInError = current as? LogtoClientErrors.SignIn {
            if signInError.type == .authFailed && signInError.innerError == nil {
                return true
            }
            current = signInError.innerError
        }
        return false
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

/// 获取后端服务（AI 交互服务、yadoA 后端）access token 时的错误。
nonisolated enum ServiceAuthError: Error, Equatable, Sendable {
    /// 当前未登录。
    case notSignedIn

    /// 登录已失效，本地凭证已清除，需要重新登录。
    case sessionExpired

    /// 网络等临时原因导致暂时无法获取 token。
    case unavailable
}
