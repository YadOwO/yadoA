import Foundation

/// 数据联动接口调用失败的原因，界面和 `DataLinkStore` 据此处理。
nonisolated enum DataLinkAPIError: Error, Equatable {
    /// 当前未登录。
    case notSignedIn

    /// 登录已失效，本地凭证已清除，需要重新登录。
    case sessionExpired

    /// 服务端拒绝了身份凭证。
    case unauthorized

    /// 用户没有授权（取汇总时 403）。
    case notGranted

    /// 联动来源没有打开（404）：服务端没配这个来源，或服务端还不支持联动。
    case unavailable

    /// 芽豆有物的服务失败、超时或响应不合契约（502）。
    case upstreamFailed

    /// 调用太频繁，被服务端限流。
    case rateLimited

    /// 服务暂时不可用（其他 5xx）。
    case serviceUnavailable

    /// 请求超时。
    case timeout

    /// 网络不可用。
    case network

    /// 请求或响应不符合契约，属于程序错误。
    case invalidContract

    /// App 版本低于服务端要求，需要升级后才能使用。
    case upgradeRequired
}

/// 数据联动用户端接口；联动状态依赖该协议，测试注入假实现。
protocol DataLinkServing {
    /// 拉取联动列表（`GET /v1/links`）。
    ///
    /// - Returns: 服务端打开的联动来源和用户是否已授权。
    /// - Throws: `DataLinkAPIError`。
    func fetchLinks() async throws -> DataLinkList

    /// 授权芽豆有物的物品购入价汇总提供给本 App（`PUT /v1/links/yadoi/yadoa`）；可以重复调用。
    ///
    /// - Returns: 授权后的状态。
    /// - Throws: `DataLinkAPIError`，来源没打开时为 `unavailable`。
    func grantItemValue() async throws -> DataLinkStatus

    /// 取消授权（`DELETE /v1/links/yadoi/yadoa`）；可以重复调用，来源有没有打开都允许。
    ///
    /// - Returns: 取消后的状态。
    /// - Throws: `DataLinkAPIError`。
    func revokeItemValue() async throws -> DataLinkStatus

    /// 取物品购入价汇总（`GET /v1/links/yadoi/yadoa/item-value-summary`）。
    ///
    /// - Returns: 在用和退役物品的购入价汇总。
    /// - Throws: `DataLinkAPIError`，没授权为 `notGranted`，来源没打开为 `unavailable`，芽豆有物取不到为 `upstreamFailed`。
    func fetchItemValueSummary() async throws -> ItemValueSummary
}

/// 调用 yado_hub 数据联动用户端接口的网络客户端。
final class DataLinkAPI: DataLinkServing {
    /// 客户端用到的接口。
    enum Route: Equatable {
        /// `GET /v1/links`：联动列表。
        case list

        /// `PUT /v1/links/yadoi/yadoa`：授权。
        case grant

        /// `DELETE /v1/links/yadoi/yadoa`：取消授权。
        case revoke

        /// `GET /v1/links/yadoi/yadoa/item-value-summary`：物品购入价汇总。
        case itemValueSummary

        /// HTTP 方法。
        var method: String {
            switch self {
            case .list, .itemValueSummary: "GET"
            case .grant: "PUT"
            case .revoke: "DELETE"
            }
        }

        /// 接口路径，来源和使用方的代号在路径里。
        var path: String {
            let link = "v1/links/\(DataLinkCode.source)/\(DataLinkCode.target)"
            switch self {
            case .list: return "v1/links"
            case .grant, .revoke: return link
            case .itemValueSummary: return "\(link)/item-value-summary"
            }
        }
    }

    /// 单次请求的超时时长；取汇总时 hub 还要等芽豆有物最多 5 秒，留足余量。
    static let requestTimeout: TimeInterval = 15

    /// 指定的服务地址（不含路径）；为空时用当前环境的 `AuthConfig.hubServiceURL`。
    private let endpointOverride: URL?

    /// 网络会话；测试可注入。
    private let session: URLSession

    /// 获取公共服务 access token 的动作。
    private let accessToken: () async throws -> String

    /// 创建客户端。
    ///
    /// - Parameters:
    ///   - endpoint: 服务地址；为空时用当前环境的 `AuthConfig.hubServiceURL`。
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
        endpointOverride ?? AuthConfig.hubServiceURL
    }

    func fetchLinks() async throws -> DataLinkList {
        try await perform(.list)
    }

    func grantItemValue() async throws -> DataLinkStatus {
        try await perform(.grant)
    }

    func revokeItemValue() async throws -> DataLinkStatus {
        try await perform(.revoke)
    }

    func fetchItemValueSummary() async throws -> ItemValueSummary {
        try await perform(.itemValueSummary)
    }

    /// 构造接口请求；这几个接口都没有请求体。
    ///
    /// - Parameters:
    ///   - route: 接口。
    ///   - token: access token。
    /// - Returns: 带鉴权头和超时设置的请求。
    func makeURLRequest(_ route: Route, token: String) -> URLRequest {
        var request = URLRequest(url: endpoint.appending(path: route.path))
        request.httpMethod = route.method
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        AppVersion.apply(to: &request)
        return request
    }

    /// 把非 200 响应映射为界面可处理的错误。
    ///
    /// - Parameter statusCode: HTTP 状态码。
    /// - Returns: 对应的错误。
    static func error(statusCode: Int) -> DataLinkAPIError {
        switch statusCode {
        case 401:
            .unauthorized
        case 403:
            .notGranted
        case 404:
            .unavailable
        case 426:
            .upgradeRequired
        case 429:
            .rateLimited
        case 502:
            .upstreamFailed
        case 500...599:
            .serviceUnavailable
        default:
            .invalidContract
        }
    }

    /// 获取凭证、发出请求并解码 200 响应。
    ///
    /// - Parameter route: 接口。
    /// - Returns: 解码后的响应。
    /// - Throws: `DataLinkAPIError`。
    private func perform<Response: Decodable>(_ route: Route) async throws -> Response {
        let token: String
        do {
            token = try await accessToken()
        } catch ServiceAuthError.notSignedIn {
            throw DataLinkAPIError.notSignedIn
        } catch ServiceAuthError.sessionExpired {
            throw DataLinkAPIError.sessionExpired
        } catch {
            throw DataLinkAPIError.network
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: makeURLRequest(route, token: token))
        } catch let error as URLError where error.code == .timedOut {
            throw DataLinkAPIError.timeout
        } catch {
            throw DataLinkAPIError.network
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DataLinkAPIError.invalidContract
        }
        if AppUpdatePrompt.checkUpgradeRequired(httpResponse) {
            throw DataLinkAPIError.upgradeRequired
        }
        guard httpResponse.statusCode == 200 else {
            throw Self.error(statusCode: httpResponse.statusCode)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw DataLinkAPIError.invalidContract
        }
    }
}
