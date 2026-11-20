import Foundation

/// 登录账号的公开资料，来自 Logto 的 userinfo 或 Account API。
struct AccountProfile: Equatable, Identifiable {
    /// 弹层呈现用的稳定标识；资料本身没有本地 ID，同一时刻只编辑一份。
    var id: String { "current" }

    /// 昵称，可为任意文字；未设置时为 nil。
    var name: String?
    /// 用户名，同时是登录标识；只允许字母、数字和下划线，且不能以数字开头。
    var username: String?
    /// 头像地址，指向 OSS 公开访问域名；未设置时为 nil。
    var avatarURL: URL?

    /// 页头展示名称：优先昵称，其次用户名；都为空时返回 nil。
    var displayName: String? {
        [name, username]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// 昵称最大长度，与 Logto 用户表 `name` 字段上限一致。
    static let nameMaxLength = 128

    /// 用户名最大长度，与服务器当前用户名策略一致。
    static let usernameMaxLength = 128

    /// 判断用户名是否符合 Logto 规则：字母或下划线开头，后续为字母、数字或下划线。
    ///
    /// 与 Logto 的 `usernameRegEx`（`^[A-Z_a-z]\w*$`）保持一致，提前在本地拦截，减少无效请求。
    static func isValidUsername(_ username: String) -> Bool {
        guard !username.isEmpty, username.count <= usernameMaxLength else {
            return false
        }
        // Swift 5 语言模式下裸斜杠正则字面量未启用，使用 #/…/# 扩展分隔符写法。
        return username.wholeMatch(of: #/[A-Za-z_][A-Za-z0-9_]*/#) != nil
    }
}

/// 调用 Logto Account API（修改资料、验证身份、绑定邮箱、设置密码、关联 Apple）失败的原因，界面按类型展示本地化文案。
///
/// Logto 的错误码只在 `from(logtoCode:)` / `from(statusCode:logtoCode:)` 这一处归类。
enum AccountProfileError: Error, Equatable {
    /// 用户名已被其他账号使用。
    case usernameTaken
    /// 用户名格式不符合规则。
    case invalidUsername
    /// 验证身份时密码错误。
    case wrongPassword
    /// 密码尝试次数过多，被 Logto 暂时锁定。
    case tooManyAttempts
    /// 服务器未开放该字段的修改（账户中心没开或字段不可编辑）。
    case notAllowed
    /// 登录凭证不被接受（`auth.unauthorized`）：凭证已失效，或是加新 scope 之前登录的老会话，需要重新登录一次。
    case reauthenticationRequired
    /// 身份验证记录已过期或不被接受（`verification_record.permission_denied`），需要重新验证身份。
    case verificationRequired
    /// 邮箱已被其他账号使用。
    case emailInUse
    /// 验证码不正确。
    case codeMismatch
    /// 验证码已过期。
    case codeExpired
    /// 验证码尝试次数过多。
    case codeTooManyAttempts
    /// 验证码记录不存在或与邮箱不匹配，需要重新获取。
    case codeInvalid
    /// 验证码发送太频繁。
    case rateLimited
    /// Logto 没有配置邮件连接器（HTTP 501），发不出验证码。
    case emailServiceUnavailable
    /// 新邮箱的验证记录无效（`verification_record.not_found`），需要重新获取验证码。
    case newEmailVerificationInvalid
    /// 新密码不符合 Logto 的密码规则（`password.rejected`，如太短、太简单）。
    case passwordRejected
    /// 新密码和当前密码相同（`user.same_password`）。
    case samePassword
    /// 要关联的社交账号（如 Apple）已经关联了其他芽豆账号，或当前账号已关联过（`user.identity_already_in_use`）。
    case socialIdentityInUse
    /// 网络不可用或请求超时。
    case network
    /// 其他未归类错误，附带服务器返回的错误码便于排查。
    case unknown(String?)

    /// 对应的 `Localizable.xcstrings` 键。
    var localizationKey: String {
        switch self {
        case .usernameTaken: "profile.edit.error.username_taken"
        case .invalidUsername: "profile.edit.error.username_invalid"
        case .wrongPassword: "profile.edit.error.wrong_password"
        case .tooManyAttempts: "profile.edit.error.too_many_attempts"
        // 「暂时无法修改，请重新登录后再试」两种情况都适用；改昵称时 `auth.unauthorized` 的提示因此保持不变
        case .notAllowed, .reauthenticationRequired: "profile.edit.error.not_allowed"
        case .verificationRequired: "account.email.error.verification_required"
        case .emailInUse: "account.email.error.in_use"
        case .codeMismatch: "account.email.error.code_mismatch"
        case .codeExpired: "account.email.error.code_expired"
        case .codeTooManyAttempts: "account.email.error.code_too_many_attempts"
        case .codeInvalid, .newEmailVerificationInvalid: "account.email.error.code_invalid"
        case .rateLimited: "account.email.error.rate_limited"
        case .emailServiceUnavailable: "account.email.error.service_unavailable"
        case .passwordRejected: "account.password.error.rejected"
        case .samePassword: "account.password.error.same_as_current"
        case .socialIdentityInUse: "account.apple.error.in_use"
        case .network: "profile.edit.error.network"
        case .unknown: "profile.edit.error.unknown"
        }
    }

    /// 把 Logto 返回的错误码归类，未识别的错误码原样保留。
    static func from(logtoCode code: String?) -> AccountProfileError {
        switch code {
        case "user.username_already_in_use":
            .usernameTaken
        case "user.email_already_in_use":
            .emailInUse
        case "session.invalid_credentials":
            .wrongPassword
        case "session.verification_blocked_too_many_attempts":
            .tooManyAttempts
        case "account_center.field_not_editable", "account_center.not_enabled":
            .notAllowed
        case "auth.unauthorized":
            .reauthenticationRequired
        case "verification_record.permission_denied":
            .verificationRequired
        case "verification_record.not_found":
            .newEmailVerificationInvalid
        case "verification_code.code_mismatch":
            .codeMismatch
        case "verification_code.expired":
            .codeExpired
        case "verification_code.exceed_max_try":
            .codeTooManyAttempts
        case "verification_code.not_found", "verification_code.email_mismatch":
            .codeInvalid
        case "request.message_rate_limited":
            .rateLimited
        case "password.rejected":
            .passwordRejected
        case "user.same_password":
            .samePassword
        case "user.identity_already_in_use":
            .socialIdentityInUse
        case "guard.invalid_input":
            .invalidUsername
        case let code? where code.hasPrefix("user.username_"):
            .invalidUsername
        default:
            .unknown(code)
        }
    }

    /// 按 HTTP 状态码和 Logto 错误码归类失败的响应。
    ///
    /// 501 表示发验证码的连接器没有配置，不管错误码是什么都归为邮件服务未开通；
    /// 其余按错误码归类，响应体里没有错误码时用 `http.<状态码>` 代替，便于排查。
    ///
    /// - Parameters:
    ///   - statusCode: HTTP 状态码。
    ///   - code: 响应体里的 `code`；解析不到时为 nil。
    static func from(statusCode: Int, logtoCode code: String?) -> AccountProfileError {
        if statusCode == 501 {
            return .emailServiceUnavailable
        }
        return from(logtoCode: code ?? "http.\(statusCode)")
    }
}

/// Logto Account API 的最小封装：用户以自己的登录凭证读取账号信息、修改资料、绑定邮箱、设置密码和关联 Apple，无需自有后端。
///
/// 前提是服务器已在 Account Center 中开启对应字段的读取 / 编辑权限；
/// 调用方传入不指定资源的 access token（`getAccessToken(for: nil)`）。
struct LogtoAccountAPI {
    /// Logto 服务地址（不含路径）。
    let endpoint: URL

    /// 发送请求的会话，测试时可替换。
    var session: URLSession = .shared

    /// 用密码验证身份，返回修改用户名等敏感字段时需要携带的验证记录 ID（约 10 分钟有效）。
    ///
    /// - Throws: 密码错误、被锁定或网络失败时抛出 `AccountProfileError`。
    func verifyPassword(_ password: String, accessToken: String) async throws -> String {
        struct Response: Decodable {
            let verificationRecordId: String
        }
        let request = try makeRequest(
            path: "api/verifications/password",
            method: "POST",
            body: ["password": password],
            accessToken: accessToken
        )
        let response: Response = try await send(request)
        return response.verificationRecordId
    }

    /// 修改昵称、用户名和 / 或头像，只提交有变化的字段。
    ///
    /// - Parameters:
    ///   - name: 新昵称；外层 nil 表示不修改，内层 nil 表示清空。
    ///   - username: 新用户名；nil 表示不修改。修改时必须同时提供 `verificationID`。
    ///   - avatar: 新头像地址；nil 表示不修改。需在 Logto Account Center 中开启头像字段的编辑权限。
    ///   - verificationID: `verifyPassword` 返回的验证记录 ID。
    /// - Returns: 服务器保存后的最新资料。
    func updateProfile(
        name: String??,
        username: String?,
        avatar: URL? = nil,
        verificationID: String?,
        accessToken: String
    ) async throws -> AccountProfile {
        var body: [String: Any] = [:]
        if let name {
            body["name"] = name ?? NSNull()
        }
        if let username {
            body["username"] = username
        }
        // TODO: 写入后 iOS 端头像显示正常，但 Logto Console 里该用户头像不显示，尚未排查。
        // 待查方向：Console 中用户 `avatar` 字段是否真的有值；浏览器直接打开头像地址是否正常；
        // Console 加载 `avatar.yado1225.top` 图片时是否被防盗链（Referer）、跨域或 CSP 拦截。
        if let avatar {
            body["avatar"] = avatar.absoluteString
        }
        var request = try makeRequest(path: "api/my-account", method: "PATCH", body: body, accessToken: accessToken)
        if let verificationID {
            request.setValue(verificationID, forHTTPHeaderField: Self.verificationHeaderName)
        }
        let response: ProfileResponse = try await send(request)
        return AccountProfile(
            name: response.name,
            username: response.username,
            avatarURL: response.avatar.flatMap(URL.init(string:))
        )
    }

    // MARK: - 账号安全与邮箱

    /// 读取当前账号的登录方式与安全信息（`GET /api/my-account`）。
    ///
    /// - Throws: `AccountProfileError`。
    func fetchAccount(accessToken: String) async throws -> AccountSecurityInfo {
        try await send(makeFetchAccountRequest(accessToken: accessToken))
    }

    /// 给邮箱发验证码（`POST /api/verifications/verification-code`），返回验证码记录 ID 和失效时刻。
    ///
    /// - Parameters:
    ///   - email: 收验证码的地址。
    ///   - purpose: 验证身份（发到当前邮箱）还是验证新邮箱。
    /// - Throws: `AccountProfileError`；没配邮件连接器时为 `.emailServiceUnavailable`。
    func sendEmailVerificationCode(
        to email: String,
        purpose: EmailVerificationPurpose,
        accessToken: String
    ) async throws -> EmailVerificationCodeRecord {
        let request = try makeSendEmailCodeRequest(email: email, purpose: purpose, accessToken: accessToken)
        let response: VerificationCodeResponse = try await send(request)
        return EmailVerificationCodeRecord(
            recordID: response.verificationRecordId,
            // Logto 返回 ISO 8601 时间，与 yado_ai 的时间格式相同，复用同一个解析
            expiresAt: response.expiresAt.flatMap(AIBillingTimestamp.parse)
        )
    }

    /// 校验邮箱验证码（`POST /api/verifications/verification-code/verify`），返回校验通过的验证记录 ID。
    ///
    /// - Parameters:
    ///   - code: 用户输入的验证码。
    ///   - email: 发验证码时的地址，必须一致。
    ///   - verificationID: `sendEmailVerificationCode` 返回的记录 ID。
    /// - Throws: `AccountProfileError`。
    func verifyEmailCode(
        _ code: String,
        email: String,
        verificationID: String,
        accessToken: String
    ) async throws -> String {
        let request = try makeVerifyEmailCodeRequest(
            code: code,
            email: email,
            verificationID: verificationID,
            accessToken: accessToken
        )
        let response: VerificationRecordResponse = try await send(request)
        return response.verificationRecordId
    }

    /// 设置主邮箱（`POST /api/my-account/primary-email`），新增和更换都走它；成功时返回 204，没有响应体。
    ///
    /// - Parameters:
    ///   - email: 新邮箱。
    ///   - newEmailVerificationID: 新邮箱验证码校验通过后的记录 ID。
    ///   - identityVerificationID: 身份验证记录 ID（密码或当前邮箱验证码），放进 `logto-verification-id` 请求头。
    /// - Throws: `AccountProfileError`。
    func setPrimaryEmail(
        _ email: String,
        newEmailVerificationID: String,
        identityVerificationID: String,
        accessToken: String
    ) async throws {
        let request = try makeSetPrimaryEmailRequest(
            email: email,
            newEmailVerificationID: newEmailVerificationID,
            identityVerificationID: identityVerificationID,
            accessToken: accessToken
        )
        try await perform(request)
    }

    /// 设置新密码（`POST /api/my-account/password`），第一次设置和修改都走它；成功时返回 204，没有响应体。
    ///
    /// 需要账户中心的 password 字段为 Edit。账号有验证方式（密码、邮箱或手机号）时必须带身份验证记录；
    /// 只有 Apple 等第三方登录的账号 Logto 不要求，这时传 nil、不带请求头。
    ///
    /// - Parameters:
    ///   - password: 新密码。
    ///   - identityVerificationID: 身份验证记录 ID，放进 `logto-verification-id` 请求头；不需要时为 nil。
    /// - Throws: `AccountProfileError`；不符合密码规则时为 `.passwordRejected`，和当前密码相同时为 `.samePassword`。
    func setPassword(_ password: String, identityVerificationID: String?, accessToken: String) async throws {
        let request = try makeSetPasswordRequest(
            password: password,
            identityVerificationID: identityVerificationID,
            accessToken: accessToken
        )
        try await perform(request)
    }

    /// 创建社交验证记录（`POST /api/verifications/social`），返回记录 ID 和要打开的授权页地址。
    ///
    /// Logto 不校验 `redirectURI`，原样作为 Apple 的 `redirect_uri`，所以它必须是 Services ID 里登记过的地址。
    ///
    /// - Parameters:
    ///   - connectorID: Logto 里社交连接器的 ID。
    ///   - state: 本次关联的 `state`，Logto 不校验，回程时由 App 自己比对。
    ///   - redirectURI: 授权完的回程地址。
    /// - Throws: `AccountProfileError`；授权页地址不合法时为 `.unknown("decode")`。
    func startSocialVerification(
        connectorID: String,
        state: String,
        redirectURI: String,
        accessToken: String
    ) async throws -> SocialVerificationStart {
        let request = try makeStartSocialVerificationRequest(
            connectorID: connectorID,
            state: state,
            redirectURI: redirectURI,
            accessToken: accessToken
        )
        let response: SocialVerificationResponse = try await send(request)
        guard let url = URL(string: response.authorizationUri) else {
            throw AccountProfileError.unknown("decode")
        }
        return SocialVerificationStart(recordID: response.verificationRecordId, authorizationURL: url)
    }

    /// 把授权回程交给 Logto 校验（`POST /api/verifications/social/verify`），返回校验通过的记录 ID。
    ///
    /// - Parameters:
    ///   - recordID: 创建时返回的记录 ID。
    ///   - connectorData: 回程里的查询参数，外加 `redirectUri`；Apple 连接器只用其中的 `id_token`（和首次授权的 `user`）。
    /// - Throws: `AccountProfileError`。
    func verifySocial(recordID: String, connectorData: [String: String], accessToken: String) async throws -> String {
        let request = try makeVerifySocialRequest(recordID: recordID, connectorData: connectorData, accessToken: accessToken)
        let response: VerificationRecordResponse = try await send(request)
        return response.verificationRecordId
    }

    /// 关联社交账号（`POST /api/my-account/identities`）；成功时返回 204，没有响应体。
    ///
    /// 需要账户中心的 social 字段为 Edit、登录时申请了 `identities` scope；账号有验证方式时必须带身份验证记录。
    /// 用 POST 而不是 PUT：已经关联过 Apple 时报错，不会悄悄换成另一个 Apple 账号。
    ///
    /// - Parameters:
    ///   - verificationRecordID: 校验通过的社交验证记录 ID。
    ///   - identityVerificationID: 身份验证记录 ID，放进 `logto-verification-id` 请求头；不需要时为 nil。
    /// - Throws: `AccountProfileError`；这个 Apple 账号已关联其他账号时为 `.socialIdentityInUse`。
    func linkSocialIdentity(
        verificationRecordID: String,
        identityVerificationID: String?,
        accessToken: String
    ) async throws {
        let request = try makeLinkSocialIdentityRequest(
            verificationRecordID: verificationRecordID,
            identityVerificationID: identityVerificationID,
            accessToken: accessToken
        )
        try await perform(request)
    }

    // MARK: - 请求构造（模块内可见，供测试断言）

    /// `GET /api/my-account`，没有请求体。
    func makeFetchAccountRequest(accessToken: String) throws -> URLRequest {
        try makeRequest(path: "api/my-account", method: "GET", body: nil, accessToken: accessToken)
    }

    /// 发邮箱验证码的请求；验证身份时带 `templateType`。
    func makeSendEmailCodeRequest(
        email: String,
        purpose: EmailVerificationPurpose,
        accessToken: String
    ) throws -> URLRequest {
        var body: [String: Any] = ["identifier": Self.emailIdentifier(email)]
        if let templateType = purpose.templateType {
            body["templateType"] = templateType
        }
        return try makeRequest(
            path: "api/verifications/verification-code",
            method: "POST",
            body: body,
            accessToken: accessToken
        )
    }

    /// 校验邮箱验证码的请求。
    func makeVerifyEmailCodeRequest(
        code: String,
        email: String,
        verificationID: String,
        accessToken: String
    ) throws -> URLRequest {
        try makeRequest(
            path: "api/verifications/verification-code/verify",
            method: "POST",
            body: [
                "identifier": Self.emailIdentifier(email),
                "verificationId": verificationID,
                "code": code,
            ],
            accessToken: accessToken
        )
    }

    /// 设置主邮箱的请求，身份验证记录放在 `logto-verification-id` 请求头。
    func makeSetPrimaryEmailRequest(
        email: String,
        newEmailVerificationID: String,
        identityVerificationID: String,
        accessToken: String
    ) throws -> URLRequest {
        var request = try makeRequest(
            path: "api/my-account/primary-email",
            method: "POST",
            body: ["email": email, "newIdentifierVerificationRecordId": newEmailVerificationID],
            accessToken: accessToken
        )
        request.setValue(identityVerificationID, forHTTPHeaderField: Self.verificationHeaderName)
        return request
    }

    /// 设置新密码的请求；有身份验证记录时放在 `logto-verification-id` 请求头。
    func makeSetPasswordRequest(
        password: String,
        identityVerificationID: String?,
        accessToken: String
    ) throws -> URLRequest {
        var request = try makeRequest(
            path: "api/my-account/password",
            method: "POST",
            body: ["password": password],
            accessToken: accessToken
        )
        if let identityVerificationID {
            request.setValue(identityVerificationID, forHTTPHeaderField: Self.verificationHeaderName)
        }
        return request
    }

    /// 创建社交验证记录的请求。
    func makeStartSocialVerificationRequest(
        connectorID: String,
        state: String,
        redirectURI: String,
        accessToken: String
    ) throws -> URLRequest {
        try makeRequest(
            path: "api/verifications/social",
            method: "POST",
            body: ["connectorId": connectorID, "state": state, "redirectUri": redirectURI],
            accessToken: accessToken
        )
    }

    /// 校验社交授权回程的请求；字段名是 `verificationRecordId`（Logto 的 OpenAPI 文档写成 `verificationId`，以服务端校验为准）。
    func makeVerifySocialRequest(
        recordID: String,
        connectorData: [String: String],
        accessToken: String
    ) throws -> URLRequest {
        try makeRequest(
            path: "api/verifications/social/verify",
            method: "POST",
            body: ["verificationRecordId": recordID, "connectorData": connectorData],
            accessToken: accessToken
        )
    }

    /// 关联社交账号的请求；有身份验证记录时放在 `logto-verification-id` 请求头。
    func makeLinkSocialIdentityRequest(
        verificationRecordID: String,
        identityVerificationID: String?,
        accessToken: String
    ) throws -> URLRequest {
        var request = try makeRequest(
            path: "api/my-account/identities",
            method: "POST",
            body: ["newIdentifierVerificationRecordId": verificationRecordID],
            accessToken: accessToken
        )
        if let identityVerificationID {
            request.setValue(identityVerificationID, forHTTPHeaderField: Self.verificationHeaderName)
        }
        return request
    }

    /// 携带身份验证记录 ID 的请求头。
    static let verificationHeaderName = "logto-verification-id"

    // MARK: - 响应处理（模块内可见，供测试断言）

    /// 校验状态码：非 2xx 时解析 Logto 的错误码并抛出对应的 `AccountProfileError`。
    ///
    /// - Parameters:
    ///   - statusCode: HTTP 状态码。
    ///   - data: 响应体，可能为空（如 204）。
    static func validate(statusCode: Int, data: Data) throws {
        guard (200..<300).contains(statusCode) else {
            let code = try? JSONDecoder().decode(ErrorResponse.self, from: data).code
            throw AccountProfileError.from(statusCode: statusCode, logtoCode: code)
        }
    }

    /// 解码成功响应；格式不符时抛出 `AccountProfileError.unknown("decode")`。
    static func decode<Response: Decodable>(_ type: Response.Type, from data: Data) throws -> Response {
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw AccountProfileError.unknown("decode")
        }
    }

    // MARK: - 私有方法

    /// 校验验证码接口返回的记录 ID。
    private struct VerificationRecordResponse: Decodable {
        let verificationRecordId: String
    }

    /// 创建社交验证记录接口返回的记录 ID 和授权页地址。
    private struct SocialVerificationResponse: Decodable {
        let verificationRecordId: String
        let authorizationUri: String
    }

    /// 发验证码接口返回的记录 ID 和失效时刻（ISO 8601 文本）。
    private struct VerificationCodeResponse: Decodable {
        let verificationRecordId: String
        let expiresAt: String?
    }

    /// 请求体里的邮箱标识。
    private static func emailIdentifier(_ email: String) -> [String: String] {
        ["type": "email", "value": email]
    }

    /// Account API 返回的资料字段，只取界面用到的部分。
    private struct ProfileResponse: Decodable {
        let name: String?
        let username: String?
        let avatar: String?
    }

    /// Logto 统一的错误响应体。
    private struct ErrorResponse: Decodable {
        let code: String?
    }

    /// 构造带鉴权头的请求；`body` 为 nil 时（如 GET）不带请求体和 `Content-Type`。
    private func makeRequest(
        path: String,
        method: String,
        body: [String: Any]?,
        accessToken: String
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    /// 发出请求并校验状态码，返回响应体，不解码；成功时没有响应体的接口（204）直接用它。
    @discardableResult
    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AccountProfileError.network
        }
        try Self.validate(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
        return data
    }

    /// 发出请求、校验状态码并解码响应体。
    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let data = try await perform(request)
        return try Self.decode(Response.self, from: data)
    }
}
