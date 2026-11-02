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

/// 修改资料失败的原因，界面按类型展示本地化文案。
enum AccountProfileError: Error, Equatable {
    /// 用户名已被其他账号使用。
    case usernameTaken
    /// 用户名格式不符合规则。
    case invalidUsername
    /// 验证身份时密码错误。
    case wrongPassword
    /// 密码尝试次数过多，被 Logto 暂时锁定。
    case tooManyAttempts
    /// 服务器未开放该字段的修改，或身份验证已失效。
    case notAllowed
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
        case .notAllowed: "profile.edit.error.not_allowed"
        case .network: "profile.edit.error.network"
        case .unknown: "profile.edit.error.unknown"
        }
    }

    /// 把 Logto 返回的错误码归类，未识别的错误码原样保留。
    static func from(logtoCode code: String?) -> AccountProfileError {
        switch code {
        case "user.username_already_in_use":
            .usernameTaken
        case "session.invalid_credentials":
            .wrongPassword
        case "session.verification_blocked_too_many_attempts":
            .tooManyAttempts
        case "account_center.field_not_editable", "account_center.not_enabled",
             "verification_record.permission_denied", "auth.unauthorized":
            .notAllowed
        case "guard.invalid_input":
            .invalidUsername
        case let code? where code.hasPrefix("user.username_"):
            .invalidUsername
        default:
            .unknown(code)
        }
    }
}

/// Logto Account API 的最小封装：用户以自己的登录凭证修改自己的资料，无需自有后端。
///
/// 前提是服务器已在 Account Center 中开启对应字段的编辑权限；
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
            request.setValue(verificationID, forHTTPHeaderField: "logto-verification-id")
        }
        let response: ProfileResponse = try await send(request)
        return AccountProfile(
            name: response.name,
            username: response.username,
            avatarURL: response.avatar.flatMap(URL.init(string:))
        )
    }

    // MARK: - 私有方法

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

    private func makeRequest(
        path: String,
        method: String,
        body: [String: Any],
        accessToken: String
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AccountProfileError.network
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let code = try? JSONDecoder().decode(ErrorResponse.self, from: data).code
            throw AccountProfileError.from(logtoCode: code ?? "http.\(status)")
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw AccountProfileError.unknown("decode")
        }
    }
}
