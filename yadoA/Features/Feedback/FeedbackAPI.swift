import Foundation

/// 意见反馈接口调用失败的原因，界面据此给出提示。
enum FeedbackAPIError: Error, Equatable {
    /// 当前未登录。
    case notSignedIn

    /// 登录已失效，本地凭证已清除，需要重新登录。
    case sessionExpired

    /// 服务端拒绝了身份凭证。
    case unauthorized

    /// 发送太频繁，被服务端限流。
    case rateLimited

    /// 服务暂时不可用。
    case serviceUnavailable

    /// 请求超时。
    case timeout

    /// 网络不可用。
    case network

    /// 请求或响应不符合契约，属于程序错误。
    case invalidContract
}

/// 意见反馈用户端接口；对话与未读状态依赖该协议，测试注入假实现。
protocol FeedbackServing {
    /// 拉取一页消息（`GET /v1/feedback/{product}/messages`），按序号从新到旧。
    ///
    /// - Parameter before: 只取序号比它小的消息；为 nil 时从最新一条开始。
    /// - Returns: 一页消息和下一页游标。
    /// - Throws: `FeedbackAPIError`。
    func fetchMessages(before: Int64?) async throws -> FeedbackMessagePage

    /// 发一条消息（`POST /v1/feedback/{product}/messages`）；同一 ID 重发时服务端返回已保存的那条。
    ///
    /// - Parameter request: 消息 ID、正文与设备信息。
    /// - Returns: 服务端保存的消息。
    /// - Throws: `FeedbackAPIError`。
    func send(_ request: FeedbackSendRequest) async throws -> FeedbackMessage

    /// 把已读位置推进到 seq（`POST /v1/feedback/{product}/read`）。
    ///
    /// - Parameter seq: 已看到的最新消息序号。
    /// - Returns: 推进后的未读条数。
    /// - Throws: `FeedbackAPIError`。
    func markRead(upTo seq: Int64) async throws -> Int

    /// 查询未读的团队回复条数（`GET /v1/feedback/{product}/unread`）。
    ///
    /// - Returns: 未读条数。
    /// - Throws: `FeedbackAPIError`。
    func fetchUnreadCount() async throws -> Int
}

/// 调用 yado_hub 意见反馈用户端接口的网络客户端。
final class FeedbackAPI: FeedbackServing {
    /// 客户端用到的接口。
    enum Route: Equatable {
        /// `GET /v1/feedback/{product}/messages`：消息分页。
        case messages(before: Int64?, limit: Int)

        /// `POST /v1/feedback/{product}/messages`：发消息。
        case send

        /// `POST /v1/feedback/{product}/read`：标记已读。
        case read

        /// `GET /v1/feedback/{product}/unread`：未读条数。
        case unread

        /// HTTP 方法。
        var method: String {
            switch self {
            case .messages, .unread: "GET"
            case .send, .read: "POST"
            }
        }

        /// 接口路径，产品代号在路径里。
        var path: String {
            switch self {
            case .messages, .send: "v1/feedback/\(FeedbackAPI.product)/messages"
            case .read: "v1/feedback/\(FeedbackAPI.product)/read"
            case .unread: "v1/feedback/\(FeedbackAPI.product)/unread"
            }
        }

        /// 查询参数。
        var queryItems: [URLQueryItem] {
            switch self {
            case let .messages(before, limit):
                var items = [URLQueryItem(name: "limit", value: String(limit))]
                if let before {
                    items.append(URLQueryItem(name: "before", value: String(before)))
                }
                return items
            case .send, .read, .unread:
                return []
            }
        }
    }

    /// 本产品代号，与 yado_hub `config/products.ts` 的 `PRODUCT_CODES` 一致。
    static let product = "yadoa"

    /// 单次请求的超时时长；接口只读写数据库。
    static let requestTimeout: TimeInterval = 15

    /// 每页消息条数；服务端上限 100。
    static let pageSize = 30

    /// 指定的服务地址（不含路径）；为空时每次请求按 `HubServiceEnvironment` 取当前地址。
    private let endpointOverride: URL?

    /// 网络会话；测试可注入。
    private let session: URLSession

    /// 获取公共服务 access token 的动作。
    private let accessToken: () async throws -> String

    /// 创建客户端。
    ///
    /// - Parameters:
    ///   - endpoint: 服务地址；为空时每次请求取 `HubServiceEnvironment.currentEndpoint`。
    ///   - session: 网络会话。
    ///   - accessToken: 获取 access token 的动作，抛出 `ServiceAuthError`。
    init(
        endpoint: URL? = nil,
        session: URLSession = .shared,
        accessToken: @escaping () async throws -> String
    ) {
        self.endpointOverride = endpoint
        self.session = session
        self.accessToken = accessToken
    }

    /// 用登录状态创建：凭证取自公共服务的 access token。
    ///
    /// - Parameter authStore: 全局登录状态。
    convenience init(authStore: AuthStore) {
        self.init { try await authStore.accessTokenForHubService() }
    }

    /// 本次请求要连的地址。
    private var endpoint: URL {
        endpointOverride ?? HubServiceEnvironment.currentEndpoint
    }

    func fetchMessages(before: Int64?) async throws -> FeedbackMessagePage {
        try await perform(.messages(before: before, limit: Self.pageSize))
    }

    func send(_ request: FeedbackSendRequest) async throws -> FeedbackMessage {
        try await perform(.send, body: request)
    }

    func markRead(upTo seq: Int64) async throws -> Int {
        let result: FeedbackUnreadCount = try await perform(.read, body: FeedbackMarkReadRequest(seq: seq))
        return result.unreadCount
    }

    func fetchUnreadCount() async throws -> Int {
        let result: FeedbackUnreadCount = try await perform(.unread)
        return result.unreadCount
    }

    /// 构造接口请求。
    ///
    /// - Parameters:
    ///   - route: 接口。
    ///   - body: JSON 请求体；无请求体时为 nil。
    ///   - token: access token。
    /// - Returns: 带鉴权头和超时设置的请求。
    func makeURLRequest(_ route: Route, body: Data?, token: String) -> URLRequest {
        var url = endpoint.appending(path: route.path)
        let queryItems = route.queryItems
        if !queryItems.isEmpty {
            url.append(queryItems: queryItems)
        }
        var request = URLRequest(url: url)
        request.httpMethod = route.method
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    /// 把非 200 响应映射为界面可处理的错误。
    ///
    /// - Parameter statusCode: HTTP 状态码。
    /// - Returns: 对应的错误。
    static func error(statusCode: Int) -> FeedbackAPIError {
        switch statusCode {
        case 401:
            .unauthorized
        case 429:
            .rateLimited
        case 500...599:
            .serviceUnavailable
        default:
            .invalidContract
        }
    }

    /// 发出不带请求体的请求并解码 200 响应。
    ///
    /// - Parameter route: 接口。
    /// - Returns: 解码后的响应。
    /// - Throws: `FeedbackAPIError`。
    private func perform<Response: Decodable>(_ route: Route) async throws -> Response {
        try await perform(route, bodyData: nil)
    }

    /// 编码 JSON 请求体，发出请求并解码 200 响应。
    ///
    /// - Parameters:
    ///   - route: 接口。
    ///   - body: 请求体。
    /// - Returns: 解码后的响应。
    /// - Throws: `FeedbackAPIError`。
    private func perform<Response: Decodable, Body: Encodable>(_ route: Route, body: Body) async throws -> Response {
        let bodyData: Data
        do {
            bodyData = try JSONEncoder().encode(body)
        } catch {
            throw FeedbackAPIError.invalidContract
        }
        return try await perform(route, bodyData: bodyData)
    }

    /// 获取凭证、发出请求并解码 200 响应。
    ///
    /// - Parameters:
    ///   - route: 接口。
    ///   - bodyData: 已编码的 JSON 请求体；GET 接口为 nil。
    /// - Returns: 解码后的响应。
    /// - Throws: `FeedbackAPIError`。
    private func perform<Response: Decodable>(_ route: Route, bodyData: Data?) async throws -> Response {
        let token: String
        do {
            token = try await accessToken()
        } catch ServiceAuthError.notSignedIn {
            throw FeedbackAPIError.notSignedIn
        } catch ServiceAuthError.sessionExpired {
            throw FeedbackAPIError.sessionExpired
        } catch {
            throw FeedbackAPIError.network
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: makeURLRequest(route, body: bodyData, token: token))
        } catch let error as URLError where error.code == .timedOut {
            throw FeedbackAPIError.timeout
        } catch {
            throw FeedbackAPIError.network
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackAPIError.invalidContract
        }
        guard httpResponse.statusCode == 200 else {
            throw Self.error(statusCode: httpResponse.statusCode)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw FeedbackAPIError.invalidContract
        }
    }
}
