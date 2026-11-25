import Foundation

/// 注销账号接口调用失败的原因，界面据此给出提示。
enum AccountDeletionAPIError: Error, Equatable {
    /// 当前未登录。
    case notSignedIn

    /// 登录已失效，本地凭证已清除，需要重新登录。
    case sessionExpired

    /// 服务拒绝了身份凭证。
    case unauthorized

    /// 服务暂时不可用（429 或 5xx），包括 yado_hub 删到某个服务或 Logto 时失败（502）、注销还没配置好（503）。
    case serviceUnavailable

    /// 请求超时。
    case timeout

    /// 网络不可用。
    case network

    /// 请求或响应不符合契约，属于程序错误。
    case invalidContract

    /// App 版本低于服务端要求，需要升级后才能继续。
    case upgradeRequired

    /// 注销票据无效、已过期或不属于当前用户（hub 返回 403 `ACCOUNT_VERIFICATION_REQUIRED`），要重新验证身份。
    case verificationRequired
}

/// 注销账号的服务端动作；测试注入假实现。
protocol AccountDeleting {
    /// 注销芽豆账号：调 yado_hub 的 `DELETE /v1/account`，由 hub 依次删除这个账号在意见反馈、AI 点数和各芽豆产品云端的数据，
    /// 全部成功后删除 Logto 用户（所有芽豆 App 共用这一个账号）。
    ///
    /// 任何一步失败 hub 都会停下并返回错误，已删的部分不用回滚；失败后在票据有效期内可以用同一张票据直接重试。
    ///
    /// - Parameter ticket: 注销票据，验证身份后由 hub 签发（`AccountDeletionVerifying.verify`），10 分钟有效，放进请求头。
    /// - Throws: `AccountDeletionAPIError`；票据失效时为 `.verificationRequired`。
    func deleteAccount(ticket: String) async throws
}

/// 调用 yado_hub 注销接口的网络客户端。
///
/// 注销统一由 yado_hub 编排：App 只调这一个接口、只要 hub 的 token，不再挨个调 yado_ai、yadoA_be 等服务，
/// 也不用关心删除顺序（Logto 用户由 hub 最后删除）。
/// 调用时必须带注销票据（`X-Account-Deletion-Ticket`），票据要先验证身份才能换到，见 `AccountDeletionVerificationAPI`。
final class AccountDeletionAPI: AccountDeleting {
    /// 注销接口的路径：yado_hub 的 `DELETE /v1/account`。
    static let path = "v1/account"

    /// 放注销票据的请求头名称。
    static let ticketHeaderName = "X-Account-Deletion-Ticket"

    /// 注销接口返回的 `{"deleted": true}`。
    private struct Response: Decodable {
        let deleted: Bool
    }

    /// 单次请求的超时时长。
    ///
    /// hub 要串行等意见反馈、几个下游服务和 Logto，服务端最坏约 50 秒（hub 前面的 nginx 读超时 60 秒），
    /// 这里留到 90 秒，避免服务端还在删、App 先报超时。
    static let requestTimeout: TimeInterval = 90

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

    func deleteAccount(ticket: String) async throws {
        let token: String
        do {
            token = try await hubAccessToken()
        } catch ServiceAuthError.notSignedIn {
            throw AccountDeletionAPIError.notSignedIn
        } catch ServiceAuthError.sessionExpired {
            throw AccountDeletionAPIError.sessionExpired
        } catch {
            throw AccountDeletionAPIError.network
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: makeURLRequest(token: token, ticket: ticket))
        } catch let error as URLError where error.code == .timedOut {
            throw AccountDeletionAPIError.timeout
        } catch {
            throw AccountDeletionAPIError.network
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AccountDeletionAPIError.invalidContract
        }
        // 不带票据的旧版会收到 426
        if AppUpdatePrompt.checkUpgradeRequired(httpResponse) {
            throw AccountDeletionAPIError.upgradeRequired
        }
        guard httpResponse.statusCode == 200 else {
            throw Self.error(statusCode: httpResponse.statusCode)
        }
        guard let body = try? JSONDecoder().decode(Response.self, from: data), body.deleted else {
            throw AccountDeletionAPIError.invalidContract
        }
    }

    /// 构造注销请求。
    ///
    /// - Parameters:
    ///   - token: hub 服务的 access token。
    ///   - ticket: 注销票据，放进 `ticketHeaderName` 请求头。
    /// - Returns: DELETE 请求，带鉴权头、票据头、版本头和超时设置，不带请求体。
    func makeURLRequest(token: String, ticket: String) -> URLRequest {
        let endpoint = hubEndpointOverride ?? AuthConfig.hubServiceURL
        var request = URLRequest(url: endpoint.appending(path: Self.path))
        request.httpMethod = "DELETE"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(ticket, forHTTPHeaderField: Self.ticketHeaderName)
        AppVersion.apply(to: &request)
        return request
    }

    /// 把非 200 响应映射为界面可处理的错误。
    ///
    /// - Parameter statusCode: HTTP 状态码。
    /// - Returns: 对应的错误。
    static func error(statusCode: Int) -> AccountDeletionAPIError {
        switch statusCode {
        case 401:
            .unauthorized
        case 403:
            .verificationRequired
        case 426:
            .upgradeRequired
        case 429, 500...599:
            .serviceUnavailable
        default:
            .invalidContract
        }
    }
}
