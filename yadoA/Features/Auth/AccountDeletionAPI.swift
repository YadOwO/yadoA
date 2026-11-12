import Foundation

/// 注销账号接口调用失败的原因，界面据此给出提示。
enum AccountDeletionAPIError: Error, Equatable {
    /// 当前未登录。
    case notSignedIn

    /// 登录已失效，本地凭证已清除，需要重新登录。
    case sessionExpired

    /// 服务拒绝了身份凭证。
    case unauthorized

    /// 服务暂时不可用（429 或 5xx）。
    case serviceUnavailable

    /// 请求超时。
    case timeout

    /// 网络不可用。
    case network

    /// 请求或响应不符合契约，属于程序错误。
    case invalidContract
}

/// 注销账号所需的三个服务端动作；测试注入假实现。
protocol AccountDeleting {
    /// 删除 yado_ai 里这个账号的点数账本等数据（`DELETE /v1/account`）；可重复调用。
    ///
    /// - Throws: `AccountDeletionAPIError`。
    func deleteAIData() async throws

    /// 删除 yado_hub 里这个账号在所有芽豆 App 的意见反馈对话、消息和诊断（`DELETE /v1/account`）；可重复调用。
    ///
    /// 必须在 `deleteAccount()` 之前调用，因为之后拿不到 hub 的 token。
    ///
    /// - Throws: `AccountDeletionAPIError`。
    func deleteFeedbackData() async throws

    /// 删除账号：yadoA_be 先删 Logto 用户，再清云端同步数据（`DELETE /v1/me`）；可重复调用。
    ///
    /// - Throws: `AccountDeletionAPIError`。
    func deleteAccount() async throws
}

extension AccountDeleting {
    /// 按固定顺序删除服务端数据：`deleteAIData()` → `deleteFeedbackData()` → `deleteAccount()`。
    ///
    /// 顺序不能变：`deleteAccount()` 会删除 Logto 用户，之后拿不到 yado_ai、yado_hub 的 token，所以必须最后调用。
    /// 任何一步抛错就立即中止，后面的步骤不再执行，错误原样抛出。
    ///
    /// - Throws: `AccountDeletionAPIError`。
    func deleteRemoteData() async throws {
        try await deleteAIData()
        try await deleteFeedbackData()
        try await deleteAccount()
    }
}

/// 调用 yado_ai、yado_hub 与 yadoA_be 注销接口的网络客户端。
///
/// 调用顺序固定：`deleteAIData()` → `deleteFeedbackData()` → `deleteAccount()`，因为最后一步会删除 Logto 用户，之后就拿不到新 token 了。
final class AccountDeletionAPI: AccountDeleting {
    /// 客户端用到的接口。
    enum Route: Equatable {
        /// `DELETE /v1/account`：yado_ai 删除点数账本等数据。
        case aiData

        /// `DELETE /v1/account`：yado_hub 删除意见反馈数据。
        case feedbackData

        /// `DELETE /v1/me`：yadoA_be 删除 Logto 用户与云端同步数据。
        case account

        /// 接口路径。
        var path: String {
            switch self {
            case .aiData: "v1/account"
            case .feedbackData: "v1/account"
            case .account: "v1/me"
            }
        }
    }

    /// 注销接口返回的 `{"deleted": true}`。
    private struct Response: Decodable {
        let deleted: Bool
    }

    /// 单次请求的超时时长。
    static let requestTimeout: TimeInterval = 30

    /// 指定的 AI 服务地址；为空时用当前环境的 `AuthConfig.aiServiceURL`。
    private let aiEndpointOverride: URL?

    /// 指定的同步服务地址；为空时用当前环境的 `AuthConfig.syncServiceURL`。
    private let syncEndpointOverride: URL?

    /// 指定的 hub 服务地址；为空时用当前环境的 `AuthConfig.hubServiceURL`。
    private let hubEndpointOverride: URL?

    /// 网络会话；测试可注入。
    private let session: URLSession

    /// 获取 AI 服务 access token 的动作。
    private let aiAccessToken: () async throws -> String

    /// 获取同步服务 access token 的动作。
    private let syncAccessToken: () async throws -> String

    /// 获取 hub 服务 access token 的动作。
    private let hubAccessToken: () async throws -> String

    /// 创建客户端。
    ///
    /// - Parameters:
    ///   - session: 网络会话。
    ///   - aiAccessToken: 获取 AI 服务 access token 的动作，抛出 `ServiceAuthError`。
    ///   - syncAccessToken: 获取同步服务 access token 的动作，抛出 `ServiceAuthError`。
    ///   - hubAccessToken: 获取 hub 服务 access token 的动作，抛出 `ServiceAuthError`。
    ///   - aiEndpoint: AI 服务地址；为空时用当前环境的 `AuthConfig.aiServiceURL`。
    ///   - syncEndpoint: 同步服务地址；为空时用当前环境的 `AuthConfig.syncServiceURL`。
    ///   - hubEndpoint: hub 服务地址；为空时用当前环境的 `AuthConfig.hubServiceURL`。
    init(
        session: URLSession = .shared,
        aiAccessToken: @escaping () async throws -> String,
        syncAccessToken: @escaping () async throws -> String,
        hubAccessToken: @escaping () async throws -> String,
        aiEndpoint: URL? = nil,
        syncEndpoint: URL? = nil,
        hubEndpoint: URL? = nil
    ) {
        self.session = session
        self.aiAccessToken = aiAccessToken
        self.syncAccessToken = syncAccessToken
        self.hubAccessToken = hubAccessToken
        self.aiEndpointOverride = aiEndpoint
        self.syncEndpointOverride = syncEndpoint
        self.hubEndpointOverride = hubEndpoint
    }

    func deleteAIData() async throws {
        try await send(.aiData)
    }

    func deleteFeedbackData() async throws {
        try await send(.feedbackData)
    }

    func deleteAccount() async throws {
        try await send(.account)
    }

    /// 构造接口请求。
    ///
    /// - Parameters:
    ///   - route: 接口。
    ///   - token: access token。
    /// - Returns: DELETE 请求，带鉴权头和超时设置，不带请求体。
    func makeURLRequest(_ route: Route, token: String) -> URLRequest {
        let endpoint = switch route {
        case .aiData: aiEndpointOverride ?? AuthConfig.aiServiceURL
        case .feedbackData: hubEndpointOverride ?? AuthConfig.hubServiceURL
        case .account: syncEndpointOverride ?? AuthConfig.syncServiceURL
        }
        var request = URLRequest(url: endpoint.appending(path: route.path))
        request.httpMethod = "DELETE"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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
        case 429, 500...599:
            .serviceUnavailable
        default:
            .invalidContract
        }
    }

    /// 获取凭证、发出请求并校验 200 响应体。
    ///
    /// - Parameter route: 接口。
    /// - Throws: `AccountDeletionAPIError`。
    private func send(_ route: Route) async throws {
        let tokenProvider = switch route {
        case .aiData: aiAccessToken
        case .feedbackData: hubAccessToken
        case .account: syncAccessToken
        }
        let token: String
        do {
            token = try await tokenProvider()
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
            (data, response) = try await session.data(for: makeURLRequest(route, token: token))
        } catch let error as URLError where error.code == .timedOut {
            throw AccountDeletionAPIError.timeout
        } catch {
            throw AccountDeletionAPIError.network
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AccountDeletionAPIError.invalidContract
        }
        guard httpResponse.statusCode == 200 else {
            throw Self.error(statusCode: httpResponse.statusCode)
        }
        guard let body = try? JSONDecoder().decode(Response.self, from: data), body.deleted else {
            throw AccountDeletionAPIError.invalidContract
        }
    }
}
