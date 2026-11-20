import Foundation

// MARK: - 账号安全信息

/// 「账号与安全」页展示的账号信息，来自 Logto Account API 的 `GET /api/my-account`。
///
/// Logto 会按 access token 的 scope 和账户中心（Account Center）各字段的设置裁剪返回内容，
/// 所以除了用户 ID，其余字段都可能缺失；缺失（nil）表示「读不到」，不等于「没有」：
/// - `primaryEmail`：需要 `email` scope，且账户中心 email 字段为 ReadOnly / Edit；
/// - `hasPrimaryEmail`：只要有 `email` scope 就返回，缺失说明当前会话是加 `email` scope 之前登录的；
/// - `socialTargets`（`identities`）：需要 `identities` scope，且 social 字段为 ReadOnly / Edit；
/// - `hasPassword`：需要 `profile` scope，且 password 字段为 ReadOnly / Edit。
nonisolated struct AccountSecurityInfo: Decodable, Equatable, Sendable {
    /// Logto 用户 ID（即 ID token 的 `sub`）。
    let userID: String

    /// 用户名；没有设置或读不到时为 nil。
    let username: String?

    /// 主邮箱地址；没有绑定或读不到时为 nil。
    let primaryEmail: String?

    /// 是否绑定了主邮箱；nil 表示当前会话没有 `email` scope，读不到。
    let hasPrimaryEmail: Bool?

    /// 是否设置了密码；nil 表示读不到。
    let hasPassword: Bool?

    /// 是否有可用于验证身份的方式（密码、邮箱或手机号任一）；为 false 就是只用第三方（如 Apple）登录的账号。
    let hasSecurityVerificationMethod: Bool

    /// 已关联的社交连接器 target（如 `"apple"`）；nil 表示读不到。
    let socialTargets: Set<String>?

    /// 去掉空白后的主邮箱；为空串时视为没有。
    var trimmedPrimaryEmail: String? {
        Self.nonEmptyTrimmed(primaryEmail)
    }

    /// 是否已绑定邮箱：有地址就算绑定；没有地址时看 `hasPrimaryEmail`，两者都读不到时为 nil。
    var isEmailBound: Bool? {
        if trimmedPrimaryEmail != nil { return true }
        return hasPrimaryEmail
    }

    /// 是否已关联指定的社交连接器；读不到 `identities` 时为 nil。
    ///
    /// - Parameter target: 连接器 target，与 `AuthSocialProvider.connectorTarget` 一致。
    func isSocialLinked(_ target: String) -> Bool? {
        socialTargets.map { $0.contains(target) }
    }

    /// 是否要先重新登录一次，才能管理邮箱。
    ///
    /// 只在开放邮箱账号的环境里判断：返回里没有 `hasPrimaryEmail`，说明这次会话是加 `email` scope 之前登录的。
    /// 线上 Logto 版本较旧，可能本来就不返回这个字段，开关关闭时不提示，避免让用户反复重新登录也解决不了。
    ///
    /// - Parameter isEmailAccountAvailable: 当前环境是否开放邮箱账号，即 `AuthConfig.isEmailAccountAvailable`。
    func needsReauthentication(isEmailAccountAvailable: Bool) -> Bool {
        isEmailAccountAvailable && hasPrimaryEmail == nil
    }

    // MARK: 解码

    private enum CodingKeys: String, CodingKey {
        case id
        case username
        case primaryEmail
        case hasPrimaryEmail
        case hasPassword
        case hasSecurityVerificationMethod
        case identities
    }

    /// `identities` 里每个连接器的值；只关心有哪些 key，内容不解析。
    private nonisolated struct Identity: Decodable {}

    /// 逐字段创建，供预览和测试使用。
    init(
        userID: String,
        username: String? = nil,
        primaryEmail: String? = nil,
        hasPrimaryEmail: Bool? = nil,
        hasPassword: Bool? = nil,
        hasSecurityVerificationMethod: Bool,
        socialTargets: Set<String>? = nil
    ) {
        self.userID = userID
        self.username = username
        self.primaryEmail = primaryEmail
        self.hasPrimaryEmail = hasPrimaryEmail
        self.hasPassword = hasPassword
        self.hasSecurityVerificationMethod = hasSecurityVerificationMethod
        self.socialTargets = socialTargets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userID = try container.decode(String.self, forKey: .id)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        primaryEmail = try container.decodeIfPresent(String.self, forKey: .primaryEmail)
        hasPrimaryEmail = try container.decodeIfPresent(Bool.self, forKey: .hasPrimaryEmail)
        hasPassword = try container.decodeIfPresent(Bool.self, forKey: .hasPassword)
        socialTargets = try container.decodeIfPresent([String: Identity].self, forKey: .identities).map { Set($0.keys) }
        // 新版 Logto 总会返回；旧版没有时按读得到的密码和邮箱推断
        let hasEmailAddress = Self.nonEmptyTrimmed(primaryEmail) != nil
        hasSecurityVerificationMethod = try container.decodeIfPresent(Bool.self, forKey: .hasSecurityVerificationMethod)
            ?? (hasPassword == true || hasPrimaryEmail == true || hasEmailAddress)
    }

    /// 去掉首尾空白，空串视为 nil。
    private static func nonEmptyTrimmed(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }
}

// MARK: - 邮箱

/// 邮箱地址的本地校验与展示。
nonisolated enum AccountEmail {
    /// 去掉首尾空白，作为提交给 Logto 的地址。
    ///
    /// - Parameter text: 用户输入的文字。
    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 判断地址是否符合 Logto 的邮箱规则（`^\S+@\S+\.\S+$`），提前在本地拦截，减少无效请求。
    ///
    /// - Parameter email: 已去掉首尾空白的地址。
    static func isValid(_ email: String) -> Bool {
        guard !email.isEmpty, email.count <= maxLength else { return false }
        return email.wholeMatch(of: #/\S+@\S+\.\S+/#) != nil
    }

    /// 两个地址是否是同一个邮箱；邮箱不区分大小写。
    static func isSame(_ lhs: String, _ rhs: String) -> Bool {
        normalized(lhs).lowercased() == normalized(rhs).lowercased()
    }

    /// 打码后的地址：用户名部分只留第一个字符，域名保留，如 `yado@gmail.com` → `y***@gmail.com`。
    ///
    /// 没有 `@` 或用户名为空时整段打码。
    ///
    /// - Parameter email: 完整地址。
    static func masked(_ email: String) -> String {
        let email = normalized(email)
        guard let at = email.lastIndex(of: "@"), at != email.startIndex else { return "***" }
        let local = email[..<at]
        let domain = email[email.index(after: at)...]
        return "\(local.prefix(1))***@\(domain)"
    }

    /// 邮箱最大长度，与 Logto 发验证码接口的上限一致。
    static let maxLength = 256
}

// MARK: - 身份验证

/// 修改邮箱、密码，关联 Apple 前验证身份的方式，按 `select(for:)` 的顺序选出一种。
nonisolated enum AccountIdentityVerificationMethod: Equatable, Sendable {
    /// 输入当前密码。
    case password

    /// 给当前邮箱发验证码（模板 `UserPermissionValidation`），附带当前邮箱地址。
    case currentEmailCode(String)

    /// 只用 Apple 等第三方登录、没有密码和邮箱的账号：重新走一遍 Logto 托管页（OIDC step-up），
    /// 由托管页让用户重新登录并设置已验证的邮箱或密码。
    case stepUp

    /// 有验证方式但 App 用不上（例如只有手机号，或邮箱地址读不到），暂时无法在 App 内验证身份。
    case unavailable

    /// 按「当前邮箱验证码 → 密码 → step-up」的顺序选择验证方式。
    ///
    /// 绑定了邮箱时优先用邮箱：忘了密码也能验证，改密码时尤其需要。
    /// Logto 的身份验证记录只认密码和发到当前邮箱 / 手机号的验证码，不认 Apple 等社交验证；
    /// 只有完全没有这些方式（`hasSecurityVerificationMethod == false`）时才走 step-up，
    /// 否则 step-up 回来也拿不到能用的方式，会一直绕圈。
    ///
    /// - Parameter info: 最新的账号信息。
    static func select(for info: AccountSecurityInfo) -> AccountIdentityVerificationMethod {
        if let email = info.trimmedPrimaryEmail {
            return .currentEmailCode(email)
        }
        if info.hasPassword == true {
            return .password
        }
        if !info.hasSecurityVerificationMethod {
            return .stepUp
        }
        return .unavailable
    }
}

/// 一次通过的身份验证：Logto 的验证记录 ID，修改邮箱、密码时放进 `logto-verification-id` 请求头。
///
/// Logto 的身份验证记录固定 10 分钟有效，从记录创建时算起：密码记录在验证时创建，
/// 验证码记录在发码时就创建了（发码接口返回 `expiresAt`）。只存在内存里，过期后要重新验证。
nonisolated struct AccountIdentityVerification: Equatable, Sendable {
    /// Logto 身份验证记录的有效期。
    static let lifetime: TimeInterval = 10 * 60

    /// 本地提前视为过期的余量，避免请求发出时刚好过期。
    static let safetyMargin: TimeInterval = 30

    /// 验证记录 ID。
    let recordID: String

    /// 记录在 Logto 那边失效的时刻（按本机时间估算）。
    let expiresAt: Date

    /// - Parameters:
    ///   - recordID: 验证记录 ID。
    ///   - expiresAt: 记录失效的时刻。
    init(recordID: String, expiresAt: Date) {
        self.recordID = recordID
        self.expiresAt = expiresAt
    }

    /// 用密码验证：记录在验证时创建，从验证通过的时刻起算。
    ///
    /// - Parameters:
    ///   - recordID: 验证记录 ID。
    ///   - verifiedAt: 验证通过的时刻。
    init(recordID: String, verifiedAt: Date) {
        self.init(recordID: recordID, expiresAt: verifiedAt.addingTimeInterval(Self.lifetime))
    }

    /// 用当前邮箱验证码验证：记录在发码时就创建了，按发码接口返回的 `expiresAt` 算；
    /// 没有返回或解析失败时，从发码请求发出的时刻起算 10 分钟。
    ///
    /// - Parameters:
    ///   - recordID: 校验通过的验证记录 ID。
    ///   - code: 发码时返回的记录。
    ///   - requestedAt: 发码请求发出的时刻。
    static func emailCode(
        recordID: String,
        code: EmailVerificationCodeRecord,
        requestedAt: Date
    ) -> AccountIdentityVerification {
        AccountIdentityVerification(
            recordID: recordID,
            expiresAt: code.expiresAt ?? requestedAt.addingTimeInterval(lifetime)
        )
    }

    /// 在指定时刻是否仍可使用（已扣除余量）。
    ///
    /// - Parameter date: 要判断的时刻，通常是当前时间。
    func isValid(at date: Date) -> Bool {
        date < expiresAt.addingTimeInterval(-Self.safetyMargin)
    }
}

/// 发验证码接口返回的记录。
nonisolated struct EmailVerificationCodeRecord: Equatable, Sendable {
    /// 验证码记录 ID，校验验证码时带上。
    let recordID: String

    /// 记录失效的时刻；接口没返回或解析失败时为 nil。
    let expiresAt: Date?
}

/// 发验证码的用途，决定 Logto 用哪个邮件模板。
nonisolated enum EmailVerificationPurpose: Sendable {
    /// 验证身份：发到当前邮箱，用 `UserPermissionValidation` 模板，验证后的记录可作为身份验证记录。
    case identityVerification

    /// 验证新邮箱归属：Logto 对新地址固定用 `BindNewIdentifier` 模板，不用传模板类型。
    case newEmail

    /// 请求体里的 `templateType`；nil 时不传。
    var templateType: String? {
        switch self {
        case .identityVerification: "UserPermissionValidation"
        case .newEmail: nil
        }
    }
}

/// 重发验证码的冷却时间。
nonisolated enum EmailCodeCooldown {
    /// 两次发送之间至少间隔的秒数。
    static let duration: TimeInterval = 60

    /// 距离可以重发还剩多少秒，向上取整；没发过或已到时间时为 0。
    ///
    /// - Parameters:
    ///   - sentAt: 上次发送的时刻；nil 表示还没发过。
    ///   - now: 当前时刻。
    static func remainingSeconds(sentAt: Date?, now: Date) -> Int {
        guard let sentAt else { return 0 }
        let remaining = duration - now.timeIntervalSince(sentAt)
        return remaining > 0 ? Int(remaining.rounded(.up)) : 0
    }
}

// MARK: - 关联第三方账号

/// 在「账号与安全」里关联 Apple 的回程约定，和云服务器 nginx 的跳转规则一一对应。
///
/// 流程：App 用 `state`（以 `statePrefix` 开头）和 `redirectURI(endpoint:connectorID:)` 创建 Logto 的社交验证记录，
/// 在 `ASWebAuthenticationSession` 里打开 Apple 授权页；Apple 授权完把结果 form_post 到 Logto 的 `/callback/<连接器 ID>`，
/// Logto 转成同路径的 GET，nginx 再 302 到 `<登录回调 scheme>://apple-link?<原参数>`，回到 App 后由 `parseCallback` 解析。
nonisolated enum SocialLink {
    /// `state` 的前缀：nginx 只把这个前缀的回程跳回 App，正常的 Apple 登录（Logto 自己生成的 state）不受影响。
    static let statePrefix = "yadoa_"

    /// 跳回 App 时自定义 scheme 后面的 host。
    static let callbackHost = "apple-link"

    /// 生成一次关联用的 `state`：前缀加随机串，回程时比对，防止拿别的授权结果来关联。
    static func makeState() -> String {
        statePrefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// 交给 Apple 的回程地址：Logto 的 `/callback/<连接器 ID>`，必须在 Apple 开发者后台的 Services ID 里登记。
    ///
    /// - Parameters:
    ///   - endpoint: Logto 服务地址（不含路径）。
    ///   - connectorID: Logto 里 Apple 连接器的 ID。
    static func redirectURI(endpoint: String, connectorID: String) -> String {
        "\(endpoint)/callback/\(connectorID)"
    }

    /// 回程的解析结果。
    enum CallbackResult: Equatable {
        /// 授权成功，附带回程里的全部查询参数（`state`、`code`、`id_token`，首次授权还有 `user`），原样交给 Logto 校验。
        case authorized([String: String])
        /// 用户在 Apple 页面上取消了授权。
        case cancelled
        /// 回程不对：不是关联的回程地址、`state` 对不上，或缺少授权结果。
        case invalid
    }

    /// 解析跳回 App 的地址。
    ///
    /// - Parameters:
    ///   - url: `ASWebAuthenticationSession` 收到的回程地址。
    ///   - expectedState: 创建验证记录时用的 `state`。
    static func parseCallback(_ url: URL, expectedState: String) -> CallbackResult {
        guard url.host() == callbackHost,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return .invalid }
        var parameters: [String: String] = [:]
        for item in items {
            parameters[item.name] = item.value ?? ""
        }
        if let error = parameters["error"] {
            return error == "user_cancelled_authorize" ? .cancelled : .invalid
        }
        guard parameters["state"] == expectedState,
              parameters["id_token"] != nil || parameters["code"] != nil
        else { return .invalid }
        return .authorized(parameters)
    }
}

/// 创建社交验证记录的结果。
nonisolated struct SocialVerificationStart: Equatable, Sendable {
    /// 验证记录 ID，校验回程和关联时带上。
    let recordID: String

    /// 要在浏览器里打开的授权页地址（Apple 的授权页）。
    let authorizationURL: URL
}

// MARK: - 重新登录

/// 重新走一遍 Logto 托管页（补 scope 或 step-up）的结果。
nonisolated enum AccountReauthenticationResult: Equatable, Sendable {
    /// 回来的是同一个账号，凭证已更新。
    case succeeded

    /// 用户关掉了托管页，凭证不变。
    case cancelled

    /// 托管页里登录的是另一个账号；为了不让本机数据和别的账号混在一起，已退出登录，需要重新登录。
    case switchedAccount

    /// 托管页加载或登录失败，凭证不变；附带便于排查的错误详情。
    case failed(String)

    /// 托管页登录成功后，比对前后的用户 ID 得出结果。
    ///
    /// - Parameters:
    ///   - originalUserID: 打开托管页之前记下的 `sub`。
    ///   - currentUserID: 回来后 ID token 里的 `sub`；解析失败时为 nil，按换了账号处理。
    static func afterSignIn(originalUserID: String, currentUserID: String?) -> AccountReauthenticationResult {
        currentUserID == originalUserID ? .succeeded : .switchedAccount
    }
}

// MARK: - 接口

/// 「账号与安全」和改邮箱、改密码、关联 Apple 流程用到的 Logto Account API；测试时替换成假实现。
protocol AccountSecurityServing {
    /// 读取当前账号的安全信息。
    func fetchAccount() async throws -> AccountSecurityInfo

    /// 用密码验证身份，返回身份验证记录 ID。
    func verifyPassword(_ password: String) async throws -> String

    /// 给邮箱发验证码，返回验证码记录（ID 和失效时刻）。
    func sendEmailCode(to email: String, purpose: EmailVerificationPurpose) async throws -> EmailVerificationCodeRecord

    /// 校验验证码，返回校验通过的验证记录 ID。
    func verifyEmailCode(_ code: String, email: String, verificationID: String) async throws -> String

    /// 设置主邮箱（新增和更换都走它）。
    func setPrimaryEmail(_ email: String, newEmailVerificationID: String, identityVerificationID: String) async throws

    /// 设置新密码（第一次设置和修改都走它）。
    ///
    /// - Parameters:
    ///   - password: 新密码。
    ///   - identityVerificationID: 身份验证记录 ID；账号没有任何验证方式（只有 Apple）时 Logto 不要求，传 nil。
    func setPassword(_ password: String, identityVerificationID: String?) async throws

    /// 创建社交验证记录，拿到要打开的授权页地址。
    ///
    /// - Parameters:
    ///   - connectorID: Logto 里社交连接器的 ID。
    ///   - state: 本次关联的 `state`，见 `SocialLink.makeState()`。
    ///   - redirectURI: 授权完的回程地址，见 `SocialLink.redirectURI(endpoint:connectorID:)`。
    func startSocialVerification(connectorID: String, state: String, redirectURI: String) async throws -> SocialVerificationStart

    /// 把授权回程交给 Logto 校验，返回校验通过的验证记录 ID。
    ///
    /// - Parameters:
    ///   - recordID: `startSocialVerification` 返回的记录 ID。
    ///   - connectorData: 回程里的查询参数，外加 `redirectUri`。
    func verifySocial(recordID: String, connectorData: [String: String]) async throws -> String

    /// 把校验通过的社交账号关联到当前账号。
    ///
    /// - Parameters:
    ///   - verificationRecordID: `verifySocial` 返回的记录 ID。
    ///   - identityVerificationID: 身份验证记录 ID；账号没有任何验证方式时 Logto 不要求，传 nil。
    func linkSocialIdentity(verificationRecordID: String, identityVerificationID: String?) async throws
}

/// 用当前登录凭证调用 `LogtoAccountAPI` 的实现，由 `AuthStore.makeAccountSecurityClient()` 创建。
///
/// 每次调用前都重新取 access token，过期时由 SDK 续期。所有方法抛出 `AccountProfileError`。
struct AccountSecurityClient: AccountSecurityServing {
    /// Logto Account API。
    let api: LogtoAccountAPI

    /// 取不指定资源的 access token（访问 Logto 自身接口用）。
    let accessToken: () async throws -> String

    func fetchAccount() async throws -> AccountSecurityInfo {
        try await api.fetchAccount(accessToken: accessToken())
    }

    func verifyPassword(_ password: String) async throws -> String {
        try await api.verifyPassword(password, accessToken: accessToken())
    }

    func sendEmailCode(to email: String, purpose: EmailVerificationPurpose) async throws -> EmailVerificationCodeRecord {
        try await api.sendEmailVerificationCode(to: email, purpose: purpose, accessToken: accessToken())
    }

    func verifyEmailCode(_ code: String, email: String, verificationID: String) async throws -> String {
        try await api.verifyEmailCode(code, email: email, verificationID: verificationID, accessToken: accessToken())
    }

    func setPrimaryEmail(_ email: String, newEmailVerificationID: String, identityVerificationID: String) async throws {
        try await api.setPrimaryEmail(
            email,
            newEmailVerificationID: newEmailVerificationID,
            identityVerificationID: identityVerificationID,
            accessToken: accessToken()
        )
    }

    func setPassword(_ password: String, identityVerificationID: String?) async throws {
        try await api.setPassword(password, identityVerificationID: identityVerificationID, accessToken: accessToken())
    }

    func startSocialVerification(connectorID: String, state: String, redirectURI: String) async throws -> SocialVerificationStart {
        try await api.startSocialVerification(
            connectorID: connectorID,
            state: state,
            redirectURI: redirectURI,
            accessToken: accessToken()
        )
    }

    func verifySocial(recordID: String, connectorData: [String: String]) async throws -> String {
        try await api.verifySocial(recordID: recordID, connectorData: connectorData, accessToken: accessToken())
    }

    func linkSocialIdentity(verificationRecordID: String, identityVerificationID: String?) async throws {
        try await api.linkSocialIdentity(
            verificationRecordID: verificationRecordID,
            identityVerificationID: identityVerificationID,
            accessToken: accessToken()
        )
    }
}
