import Foundation

/// 点数查询接口调用失败的原因，界面据此给出提示。
enum AIBillingAPIError: Error, Equatable {
    /// 当前未登录。
    case notSignedIn

    /// 登录已失效，本地凭证已清除，需要重新登录。
    case sessionExpired

    /// AI 服务拒绝了身份凭证。
    case unauthorized

    /// 点数服务暂时不可用。
    case serviceUnavailable

    /// 请求超时。
    case timeout

    /// 网络不可用。
    case network

    /// 请求或响应不符合契约，属于程序错误。
    case invalidContract
}

/// 查询点数余额、流水与模型档位的能力；测试注入假实现。
protocol AIBillingFetching {
    /// 查询当前账号的余额；本产品首次查询时服务端发放本产品的新用户赠送。
    ///
    /// - Returns: 余额。
    /// - Throws: `AIBillingAPIError`。
    func fetchWallet() async throws -> AIWallet

    /// 按时间倒序查询一页流水。
    ///
    /// - Parameter cursor: 上一页返回的游标；为 nil 时从最新一条开始。
    /// - Returns: 一页流水和下一页游标。
    /// - Throws: `AIBillingAPIError`。
    func fetchEntries(cursor: String?) async throws -> AICreditEntryPage

    /// 查询模型档位列表，用于让用户选档位并展示每句扣的点数。
    ///
    /// - Returns: 档位列表。
    /// - Throws: `AIBillingAPIError`。
    func fetchModelTiers() async throws -> AIModelTierList
}

/// 调用 yado_ai 点数与模型档位查询接口的网络客户端；这些接口不调用模型、不扣点。
final class AIBillingAPI: AIBillingFetching {
    /// 客户端用到的接口。
    enum Route: Equatable {
        /// `GET /v1/billing/wallet`：余额与各批点数的过期时刻。
        case wallet

        /// `GET /v1/billing/entries`：流水分页。
        case entries(cursor: String?, limit: Int)

        /// `GET /v1/models`：模型档位与每轮点数。
        case models

        /// 接口路径。
        var path: String {
            switch self {
            case .wallet: "v1/billing/wallet"
            case .entries: "v1/billing/entries"
            case .models: "v1/models"
            }
        }

        /// 查询参数；余额和流水都要带本产品代号，服务端缺这个参数时返回 400。
        var queryItems: [URLQueryItem] {
            switch self {
            case .wallet:
                return [URLQueryItem(name: "product", value: AIBillingAPI.product)]
            case let .entries(cursor, limit):
                var items = [
                    URLQueryItem(name: "product", value: AIBillingAPI.product),
                    URLQueryItem(name: "limit", value: String(limit))
                ]
                if let cursor {
                    items.append(URLQueryItem(name: "cursor", value: cursor))
                }
                return items
            case .models:
                return []
            }
        }
    }

    /// 本产品代号，与 yado_ai `config/billing.ts` 的 `PRODUCT_CODES` 一致；服务端按它发放本产品的新用户赠送。
    static let product = "yadoa"

    /// 单次请求的超时时长；查询接口只访问数据库，不调用模型。
    static let requestTimeout: TimeInterval = 15

    /// 每页流水条数；服务端上限 50。
    static let pageSize = 20

    /// 指定的 AI 服务地址（不含路径）；为空时每次请求按 `AIServiceEnvironment` 取当前地址。
    private let endpointOverride: URL?

    /// 网络会话；测试可注入。
    private let session: URLSession

    /// 获取 AI 服务 access token 的动作。
    private let accessToken: () async throws -> String

    /// 创建客户端。
    ///
    /// - Parameters:
    ///   - endpoint: AI 服务地址；为空时每次请求取 `AIServiceEnvironment.currentEndpoint`，开发者设置里切换后立即生效。
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

    /// 本次请求要连的地址。
    private var endpoint: URL {
        endpointOverride ?? AIServiceEnvironment.currentEndpoint
    }

    func fetchWallet() async throws -> AIWallet {
        try await send(.wallet)
    }

    func fetchEntries(cursor: String?) async throws -> AICreditEntryPage {
        try await send(.entries(cursor: cursor, limit: Self.pageSize))
    }

    func fetchModelTiers() async throws -> AIModelTierList {
        try await send(.models)
    }

    /// 构造接口请求。
    ///
    /// - Parameters:
    ///   - route: 接口。
    ///   - token: access token。
    /// - Returns: 带鉴权头和超时设置的 GET 请求。
    func makeURLRequest(_ route: Route, token: String) -> URLRequest {
        var url = endpoint.appending(path: route.path)
        let queryItems = route.queryItems
        if !queryItems.isEmpty {
            url.append(queryItems: queryItems)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// 把非 200 响应映射为界面可处理的错误。
    ///
    /// - Parameter statusCode: HTTP 状态码。
    /// - Returns: 对应的错误。
    static func error(statusCode: Int) -> AIBillingAPIError {
        switch statusCode {
        case 401:
            .unauthorized
        case 429, 500...599:
            .serviceUnavailable
        default:
            .invalidContract
        }
    }

    /// 获取凭证、发出请求并解码 200 响应。
    ///
    /// - Parameter route: 接口。
    /// - Returns: 解码后的响应。
    /// - Throws: `AIBillingAPIError`。
    private func send<Response: Decodable>(_ route: Route) async throws -> Response {
        let token: String
        do {
            token = try await accessToken()
        } catch ServiceAuthError.notSignedIn {
            throw AIBillingAPIError.notSignedIn
        } catch ServiceAuthError.sessionExpired {
            throw AIBillingAPIError.sessionExpired
        } catch {
            throw AIBillingAPIError.network
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: makeURLRequest(route, token: token))
        } catch let error as URLError where error.code == .timedOut {
            throw AIBillingAPIError.timeout
        } catch {
            throw AIBillingAPIError.network
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIBillingAPIError.invalidContract
        }
        guard httpResponse.statusCode == 200 else {
            throw Self.error(statusCode: httpResponse.statusCode)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw AIBillingAPIError.invalidContract
        }
    }
}
