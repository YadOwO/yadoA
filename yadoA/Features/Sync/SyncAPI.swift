import Foundation

/// 同步接口调用失败的原因，同步引擎据此决定重试、暂停还是提示重新登录。
nonisolated enum SyncAPIError: Error, Equatable, Sendable {
    /// 当前未登录。
    case notSignedIn

    /// 登录已失效，本地凭证已清除，需要重新登录。
    case sessionExpired

    /// 服务端拒绝了身份凭证。
    case unauthorized

    /// 云端数据已被重置（其他设备删除了云端数据），本机代次过期；附带服务端当前代次。
    case epochMismatch(currentEpoch: Int)

    /// 服务端暂时不可用（5xx 或限流）。
    case serviceUnavailable

    /// 请求超时。
    case timeout

    /// 网络不可用。
    case network

    /// 请求或响应不符合契约，属于程序错误，重试无意义。
    case invalidContract

    /// 是否属于临时故障，可按退避策略自动重试。
    var isRetryable: Bool {
        switch self {
        case .serviceUnavailable, .timeout, .network:
            true
        case .notSignedIn, .sessionExpired, .unauthorized, .epochMismatch, .invalidContract:
            false
        }
    }
}

/// 云端同步接口；同步引擎依赖该协议，测试注入假实现。
nonisolated protocol SyncServing: Sendable {
    /// 读取服务端同步状态（`GET /v1/sync/state`）。
    ///
    /// - Returns: 当前数据代次。
    /// - Throws: `SyncAPIError`。
    func fetchState() async throws -> SyncServerState

    /// 推送一批本地变更（`POST /v1/sync/push`）。
    ///
    /// - Parameter request: 设备、代次、本机进度与 1...250 条变更。
    /// - Returns: 每条变更的裁决结果，或要求先全量拉取。
    /// - Throws: `SyncAPIError`；代次不一致时为 `.epochMismatch`。
    func push(_ request: SyncPushRequest) async throws -> SyncPushResponse

    /// 拉取一页变更（`GET /v1/sync/pull`）。
    ///
    /// `since = 0` 开始一轮全量拉取：单页不是完整状态，必须翻完所有页、合并整轮结果后再替换本地已同步的数据，
    /// 整轮完成前不要推送。
    /// - Parameters:
    ///   - since: 已拉取到的序号；0 表示全量。
    ///   - deviceID: 本机设备标识。
    ///   - epoch: 本机记录的数据代次。
    ///   - limit: 每页条数；为空时用服务端默认值。
    /// - Returns: 一页变更。
    /// - Throws: `SyncAPIError`；代次不一致时为 `.epochMismatch`。
    func pull(since: Int64, deviceID: UUID, epoch: Int, limit: Int?) async throws -> SyncPullPage

    /// 删除当前用户的全部云端数据（`DELETE /v1/sync/data`），代次加 1。
    ///
    /// - Parameter epoch: 本机记录的数据代次；不一致时服务端拒绝，防止旧设备删掉重置后的新数据。
    /// - Returns: 删除后的同步状态（新代次）。
    /// - Throws: `SyncAPIError`；代次不一致时为 `.epochMismatch`。
    func deleteAllData(epoch: Int) async throws -> SyncServerState
}

/// 调用 yadoA 后端 `/v1/sync/*` 的网络客户端。
///
/// 请求和 JSON 编解码都在 `@concurrent` 的 `send` 中执行，不占主线程；同步引擎在主线程调用也不会卡界面。
nonisolated final class SyncAPI: SyncServing {
    /// 一次接口请求的方法、路径和参数。
    nonisolated enum Route: Equatable, Sendable {
        case state
        case push
        case pull(since: Int64, deviceID: UUID, epoch: Int, limit: Int?)
        case deleteAllData(epoch: Int)

        /// HTTP 方法。
        var method: String {
            switch self {
            case .state, .pull: "GET"
            case .push: "POST"
            case .deleteAllData: "DELETE"
            }
        }

        /// 相对于服务地址的路径。
        var path: String {
            switch self {
            case .state: "v1/sync/state"
            case .push: "v1/sync/push"
            case .pull: "v1/sync/pull"
            case .deleteAllData: "v1/sync/data"
            }
        }

        /// 查询参数；UUID 统一用小写。
        var queryItems: [URLQueryItem] {
            switch self {
            case .state, .push:
                return []
            case let .pull(since, deviceID, epoch, limit):
                var items = [
                    URLQueryItem(name: "since", value: String(since)),
                    URLQueryItem(name: "deviceId", value: deviceID.uuidString.lowercased()),
                    URLQueryItem(name: "epoch", value: String(epoch)),
                ]
                if let limit {
                    items.append(URLQueryItem(name: "limit", value: String(limit)))
                }
                return items
            case let .deleteAllData(epoch):
                return [URLQueryItem(name: "epoch", value: String(epoch))]
            }
        }
    }

    /// 单次请求的超时时长；推送一批最大约 4 MB，弱网下需要留足上传时间。
    static let requestTimeout: TimeInterval = 60

    /// 服务地址（不含路径）。
    private let endpoint: URL

    /// 网络会话；测试可注入。
    private let session: URLSession

    /// 获取同步服务 access token 的动作，抛出 `ServiceAuthError`。
    private let accessToken: @Sendable () async throws -> String

    /// 创建客户端。
    ///
    /// - Parameters:
    ///   - endpoint: 服务地址；默认为线上 `AuthConfig.syncServiceEndpoint`。
    ///   - session: 网络会话。
    ///   - accessToken: 获取 access token 的动作，通常是 `AuthStore.accessTokenForSyncService()`。
    init(
        endpoint: URL = SyncAPI.productionEndpoint,
        session: URLSession = .shared,
        accessToken: @escaping @Sendable () async throws -> String
    ) {
        self.endpoint = endpoint
        self.session = session
        self.accessToken = accessToken
    }

    /// 线上服务地址；`AuthConfig.syncServiceEndpoint` 是写死的常量，非法即为配置错误。
    static var productionEndpoint: URL {
        guard let url = URL(string: AuthConfig.syncServiceEndpoint) else {
            preconditionFailure("AuthConfig.syncServiceEndpoint 不是合法 URL：\(AuthConfig.syncServiceEndpoint)")
        }
        return url
    }

    func fetchState() async throws -> SyncServerState {
        try await send(.state)
    }

    func push(_ request: SyncPushRequest) async throws -> SyncPushResponse {
        try await send(.push, pushRequest: request)
    }

    func pull(since: Int64, deviceID: UUID, epoch: Int, limit: Int?) async throws -> SyncPullPage {
        try await send(.pull(since: since, deviceID: deviceID, epoch: epoch, limit: limit))
    }

    func deleteAllData(epoch: Int) async throws -> SyncServerState {
        try await send(.deleteAllData(epoch: epoch))
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

    /// 把非 200 响应映射为同步引擎可处理的错误。
    ///
    /// - Parameters:
    ///   - statusCode: HTTP 状态码。
    ///   - body: 错误响应体 `{ code, message, details? }`。
    /// - Returns: 对应的错误。
    static func error(statusCode: Int, body: Data) -> SyncAPIError {
        switch statusCode {
        case 401:
            return .unauthorized
        case 409:
            let errorBody = try? JSONDecoder().decode(SyncErrorBody.self, from: body)
            guard errorBody?.code == "EPOCH_MISMATCH", let epoch = errorBody?.details?.epoch else {
                return .invalidContract
            }
            return .epochMismatch(currentEpoch: epoch)
        case 429, 500...599:
            return .serviceUnavailable
        default:
            return .invalidContract
        }
    }

    // MARK: - 私有方法

    /// 获取凭证、编码请求体、发出请求并解码 200 响应；整段在后台执行。
    ///
    /// - Parameters:
    ///   - route: 接口。
    ///   - pushRequest: 推送接口的请求体；其他接口为 nil。
    @concurrent
    private func send<Response: Decodable & Sendable>(
        _ route: Route,
        pushRequest: SyncPushRequest? = nil
    ) async throws -> Response {
        var body: Data?
        if let pushRequest {
            do {
                body = try SyncCoding.makeEncoder().encode(pushRequest)
            } catch {
                throw SyncAPIError.invalidContract
            }
        }

        let token: String
        do {
            token = try await accessToken()
        } catch ServiceAuthError.notSignedIn {
            throw SyncAPIError.notSignedIn
        } catch ServiceAuthError.sessionExpired {
            throw SyncAPIError.sessionExpired
        } catch {
            throw SyncAPIError.network
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: makeURLRequest(route, body: body, token: token))
        } catch let error as URLError where error.code == .timedOut {
            throw SyncAPIError.timeout
        } catch {
            throw SyncAPIError.network
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SyncAPIError.invalidContract
        }
        guard httpResponse.statusCode == 200 else {
            throw Self.error(statusCode: httpResponse.statusCode, body: data)
        }
        do {
            return try SyncCoding.makeDecoder().decode(Response.self, from: data)
        } catch {
            throw SyncAPIError.invalidContract
        }
    }
}
