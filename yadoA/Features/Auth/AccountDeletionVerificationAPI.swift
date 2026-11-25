import Foundation

/// 注销前证明「是本人」的凭据，三种方式选一种，由 yado_hub 自己去 Logto 校验，通过后换一张 10 分钟有效的注销票据。
nonisolated enum AccountDeletionProof: Equatable, Sendable, Encodable {
    /// 发到 Logto 主邮箱的 6 位数字验证码。
    case emailCode(String)

    /// 芽豆账号的登录密码。
    case password(String)

    /// 刚用 `max_age=0` 重新登录后拿到的 ID token，hub 会验签并检查登录时间。
    case idToken(String)

    private nonisolated enum CodingKeys: String, CodingKey {
        case method
        case code
        case password
        case idToken
    }

    /// 编码成 hub 要求的请求体：`{"method":"email_code","code":…}`、`{"method":"password","password":…}` 或 `{"method":"id_token","idToken":…}`。
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .emailCode(code):
            try container.encode("email_code", forKey: .method)
            try container.encode(code, forKey: .code)
        case let .password(password):
            try container.encode("password", forKey: .method)
            try container.encode(password, forKey: .password)
        case let .idToken(idToken):
            try container.encode("id_token", forKey: .method)
            try container.encode(idToken, forKey: .idToken)
        }
    }
}

/// 注销前验证身份、读取数据清单这几个接口调用失败的原因，界面据此给出提示。
nonisolated enum AccountDeletionVerificationError: Error, Equatable, Sendable {
    /// 密码不对。
    case wrongPassword

    /// 验证码不对，可以重新输入。
    case codeMismatch

    /// 验证码已失效（过期、次数用完或没发过），要重新获取。
    case codeInvalid

    /// 账号在 Logto 里没有主邮箱，发不了验证码。
    case emailUnavailable

    /// 重新登录没有完成：ID token 的登录时间不够新。
    case loginNotRecent

    /// 尝试太频繁，被限流了。
    case rateLimited

    /// 登录已失效，需要重新登录。
    case sessionExpired

    /// App 版本低于服务端要求，需要升级。
    case upgradeRequired

    /// 服务暂时不可用，或返回了不符合契约的响应。
    case serviceUnavailable

    /// 网络不可用或请求超时。
    case network

    /// 给用户看的提示文案键。
    var localizationKey: String {
        switch self {
        case .wrongPassword: "profile.edit.error.wrong_password"
        case .codeMismatch: "account.email.error.code_mismatch"
        case .codeInvalid: "account.email.error.code_invalid"
        case .emailUnavailable, .serviceUnavailable: "account.email.identity.unavailable"
        case .loginNotRecent: "account.delete.verify.error.login_not_recent"
        case .rateLimited: "account.delete.verify.error.rate_limited"
        case .sessionExpired: "account.delete.failed.session"
        case .upgradeRequired: "account.delete.failed.upgrade"
        case .network: "profile.edit.error.network"
        }
    }

    /// hub 错误响应的结构：`{"code":…,"message":…,"details":{"reason":…}}`；只取分辨原因用的 `code` 和 `details.reason`。
    private nonisolated struct ErrorBody: Decodable {
        /// 业务错误码，如 `IDENTITY_VERIFICATION_FAILED`。
        let code: String?

        /// `details.reason`；`details` 不是对象或没有 `reason` 时为 nil。
        let reason: String?

        private nonisolated enum CodingKeys: String, CodingKey {
            case code
            case details
        }

        private nonisolated enum DetailsKeys: String, CodingKey {
            case reason
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            code = try? container.decodeIfPresent(String.self, forKey: .code)
            reason = (try? container.nestedContainer(keyedBy: DetailsKeys.self, forKey: .details))
                .flatMap { try? $0.decodeIfPresent(String.self, forKey: .reason) }
        }
    }

    /// 把非 200 响应映射为界面可处理的错误。
    ///
    /// 400 要看响应体：`IDENTITY_VERIFICATION_FAILED` 的 `details.reason` 说明哪里没通过，认不出的按服务暂时不可用。
    ///
    /// - Parameters:
    ///   - statusCode: HTTP 状态码。
    ///   - body: 响应体，用来读 400 的原因。
    /// - Returns: 对应的错误。
    static func error(statusCode: Int, body: Data) -> AccountDeletionVerificationError {
        switch statusCode {
        case 400:
            guard let parsed = try? JSONDecoder().decode(ErrorBody.self, from: body),
                  parsed.code == "IDENTITY_VERIFICATION_FAILED"
            else { return .serviceUnavailable }
            switch parsed.reason {
            case "wrong_password": return .wrongPassword
            case "code_mismatch": return .codeMismatch
            case "code_invalid": return .codeInvalid
            case "email_unavailable": return .emailUnavailable
            case "login_not_recent": return .loginNotRecent
            default: return .serviceUnavailable
            }
        case 401:
            return .sessionExpired
        case 426:
            return .upgradeRequired
        case 429:
            return .rateLimited
        default:
            return .serviceUnavailable
        }
    }
}

/// 注销前的身份验证和数据清单：调 yado_hub，测试注入假实现。
protocol AccountDeletionVerifying {
    /// 让 hub 给 Logto 里的主邮箱发一封验证码邮件。
    ///
    /// - Throws: `AccountDeletionVerificationError`。
    func sendEmailCode() async throws

    /// 让 hub 校验身份凭据，通过后换来注销票据。
    ///
    /// - Parameter proof: 邮箱验证码、密码或重新登录后的 ID token。
    /// - Returns: 注销票据，10 分钟有效，调 `DELETE /v1/account` 时放进请求头。
    /// - Throws: `AccountDeletionVerificationError`。
    func verify(_ proof: AccountDeletionProof) async throws -> String

    /// 读取各芽豆产品里这个账号的数据量，注销确认页据此列出会被删掉的内容。
    ///
    /// - Throws: `AccountDeletionVerificationError`。
    func fetchSummary() async throws -> AccountDataSummary
}

/// 调用 yado_hub 注销前验证接口的网络客户端。
///
/// 注销要先换一张注销票据：验证身份由 hub 在服务端强制，App 只负责把密码、验证码或 ID token 交给 hub，
/// 不直接去 Logto 校验；拿到票据后再调 `AccountDeletionAPI`。
final class AccountDeletionVerificationAPI: AccountDeletionVerifying {
    /// 发邮箱验证码的路径：yado_hub 的 `POST /v1/account/verification/email-code`。
    static let emailCodePath = "v1/account/verification/email-code"

    /// 换注销票据的路径：yado_hub 的 `POST /v1/account/verification`。
    static let verificationPath = "v1/account/verification"

    /// 数据清单的路径：yado_hub 的 `GET /v1/account/summary`。
    static let summaryPath = "v1/account/summary"

    /// 验证类请求的超时时长：hub 要去 Logto Management API 校验或发邮件，比普通请求慢。
    static let verificationTimeout: TimeInterval = 40

    /// 数据清单请求的超时时长：hub 并行查各下游，每个下游最多等 10 秒。
    static let summaryTimeout: TimeInterval = 20

    /// 发验证码接口返回的 `{"sent": true}`。
    private struct CodeSentResponse: Decodable {
        let sent: Bool
    }

    /// 换票据接口返回的 `{"ticket": …, "expiresAt": …}`；有效期按验证通过的时刻在本地算，这里只取票据。
    private struct TicketResponse: Decodable {
        let ticket: String
    }

    /// 指定的 hub 服务地址；为空时用当前环境的 `AuthConfig.hubServiceURL`。
    private let hubEndpointOverride: URL?

    /// 网络会话；测试可注入。
    private let session: URLSession

    /// 获取 hub 服务 access token 的动作。
    private let hubAccessToken: () async throws -> String

    /// 创建客户端。
    ///
    /// - Parameters:
    ///   - session: 网络会话。
    ///   - hubAccessToken: 获取 hub 服务 access token 的动作，抛出 `ServiceAuthError`。
    ///   - hubEndpoint: hub 服务地址；为空时用当前环境的 `AuthConfig.hubServiceURL`。
    init(
        session: URLSession = .shared,
        hubAccessToken: @escaping () async throws -> String,
        hubEndpoint: URL? = nil
    ) {
        self.session = session
        self.hubAccessToken = hubAccessToken
        self.hubEndpointOverride = hubEndpoint
    }

    func sendEmailCode() async throws {
        let data = try await send { makeEmailCodeRequest(token: $0) }
        guard let body = try? JSONDecoder().decode(CodeSentResponse.self, from: data), body.sent else {
            throw AccountDeletionVerificationError.serviceUnavailable
        }
    }

    func verify(_ proof: AccountDeletionProof) async throws -> String {
        let data = try await send { try makeVerificationRequest(proof: proof, token: $0) }
        guard let body = try? JSONDecoder().decode(TicketResponse.self, from: data), !body.ticket.isEmpty else {
            throw AccountDeletionVerificationError.serviceUnavailable
        }
        return body.ticket
    }

    func fetchSummary() async throws -> AccountDataSummary {
        let data = try await send { makeSummaryRequest(token: $0) }
        guard let summary = try? JSONDecoder().decode(AccountDataSummary.self, from: data) else {
            throw AccountDeletionVerificationError.serviceUnavailable
        }
        return summary
    }

    // MARK: - 构造请求

    /// 构造发邮箱验证码的请求。
    ///
    /// - Parameter token: hub 服务的 access token。
    /// - Returns: POST 请求，带鉴权头、版本头和超时设置，不带请求体。
    func makeEmailCodeRequest(token: String) -> URLRequest {
        baseRequest(path: Self.emailCodePath, method: "POST", token: token, timeout: Self.verificationTimeout)
    }

    /// 构造换注销票据的请求。
    ///
    /// - Parameters:
    ///   - proof: 身份凭据，编码成 JSON 请求体。
    ///   - token: hub 服务的 access token。
    /// - Returns: POST 请求，带 JSON 请求体、鉴权头、版本头和超时设置。
    /// - Throws: 编码请求体失败（不会发生，只是不吞掉错误）。
    func makeVerificationRequest(proof: AccountDeletionProof, token: String) throws -> URLRequest {
        var request = baseRequest(path: Self.verificationPath, method: "POST", token: token, timeout: Self.verificationTimeout)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(proof)
        return request
    }

    /// 构造读取数据清单的请求。
    ///
    /// - Parameter token: hub 服务的 access token。
    /// - Returns: GET 请求，带鉴权头、版本头和超时设置。
    func makeSummaryRequest(token: String) -> URLRequest {
        baseRequest(path: Self.summaryPath, method: "GET", token: token, timeout: Self.summaryTimeout)
    }

    // MARK: - 私有方法

    /// 三个接口共用的请求外壳。
    private func baseRequest(path: String, method: String, token: String, timeout: TimeInterval) -> URLRequest {
        let endpoint = hubEndpointOverride ?? AuthConfig.hubServiceURL
        var request = URLRequest(url: endpoint.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        AppVersion.apply(to: &request)
        return request
    }

    /// 取 hub 的 token、发出请求，只放行 200 响应。
    ///
    /// - Parameter build: 用 token 构造请求。
    /// - Returns: 200 响应的响应体。
    /// - Throws: `AccountDeletionVerificationError`。
    private func send(_ build: (String) throws -> URLRequest) async throws -> Data {
        let token: String
        do {
            token = try await hubAccessToken()
        } catch ServiceAuthError.notSignedIn {
            throw AccountDeletionVerificationError.sessionExpired
        } catch ServiceAuthError.sessionExpired {
            throw AccountDeletionVerificationError.sessionExpired
        } catch {
            throw AccountDeletionVerificationError.network
        }

        let request: URLRequest
        do {
            request = try build(token)
        } catch {
            throw AccountDeletionVerificationError.serviceUnavailable
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AccountDeletionVerificationError.network
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AccountDeletionVerificationError.serviceUnavailable
        }
        if AppUpdatePrompt.checkUpgradeRequired(httpResponse) {
            throw AccountDeletionVerificationError.upgradeRequired
        }
        guard httpResponse.statusCode == 200 else {
            throw AccountDeletionVerificationError.error(statusCode: httpResponse.statusCode, body: data)
        }
        return data
    }
}
