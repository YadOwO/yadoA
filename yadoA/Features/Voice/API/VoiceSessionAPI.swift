import Foundation

/// 语音记账会话接口调用失败的原因，界面据此给出提示。
enum VoiceSessionAPIError: Error, Equatable {
    /// 当前未登录。
    case notSignedIn

    /// 登录已失效，本地凭证已清除，需要重新登录。
    case sessionExpired

    /// AI 服务拒绝了身份凭证。
    case unauthorized

    /// 超过调用限额；`isDaily` 为真表示当天的次数已用完。
    case rateLimited(isDaily: Bool)

    /// 会话内容过长，需要结束后重新开始。
    case sessionTooLong

    /// 模型调用失败、超时或服务尚未配置模型。
    case serviceUnavailable

    /// 请求超时。
    case timeout

    /// 网络不可用。
    case network

    /// 请求或响应不符合契约，属于程序错误。
    case invalidContract
}

/// 发送一步会话请求的能力；测试注入假实现驱动会话循环。
protocol VoiceSessionTurnSending {
    /// 发送一步请求。
    ///
    /// - Parameter request: 会话上下文与全部事件。
    /// - Returns: 工具调用、追问或回复。
    /// - Throws: `VoiceSessionAPIError`。
    func send(_ request: VoiceSessionTurnRequest) async throws -> VoiceSessionTurnResponse
}

/// 调用 yado_ai `POST /v1/yadoa/voice-session/turn` 的网络客户端。
final class VoiceSessionAPI: VoiceSessionTurnSending {
    /// AI 服务地址（不含路径）。
    private let endpoint: URL

    /// 网络会话；测试可注入。
    private let session: URLSession

    /// 获取 AI 服务 access token 的动作。
    private let accessToken: () async throws -> String

    /// 单次请求的超时时长；服务端一步最多调用模型两次，每次超时 20 秒。
    static let requestTimeout: TimeInterval = 45

    /// 创建客户端。
    ///
    /// - Parameters:
    ///   - endpoint: AI 服务地址，默认取 `AuthConfig.aiServiceEndpoint`。
    ///   - session: 网络会话。
    ///   - accessToken: 获取 access token 的动作，抛出 `AIServiceAuthError`。
    init(
        endpoint: URL = VoiceSessionAPI.defaultEndpoint,
        session: URLSession = .shared,
        accessToken: @escaping () async throws -> String
    ) {
        self.endpoint = endpoint
        self.session = session
        self.accessToken = accessToken
    }

    /// 默认 AI 服务地址；`AuthConfig.aiServiceEndpoint` 是写死的常量，非法即为配置错误。
    static var defaultEndpoint: URL {
        guard let url = URL(string: AuthConfig.aiServiceEndpoint) else {
            preconditionFailure("AuthConfig.aiServiceEndpoint 不是合法 URL：\(AuthConfig.aiServiceEndpoint)")
        }
        return url
    }

    func send(_ request: VoiceSessionTurnRequest) async throws -> VoiceSessionTurnResponse {
        let token: String
        do {
            token = try await accessToken()
        } catch AIServiceAuthError.notSignedIn {
            throw VoiceSessionAPIError.notSignedIn
        } catch AIServiceAuthError.sessionExpired {
            throw VoiceSessionAPIError.sessionExpired
        } catch {
            throw VoiceSessionAPIError.network
        }

        var urlRequest = URLRequest(url: endpoint.appending(path: "v1/yadoa/voice-session/turn"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = Self.requestTimeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            urlRequest.httpBody = try JSONEncoder().encode(request)
        } catch {
            throw VoiceSessionAPIError.invalidContract
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError where error.code == .timedOut {
            throw VoiceSessionAPIError.timeout
        } catch {
            throw VoiceSessionAPIError.network
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoiceSessionAPIError.invalidContract
        }
        guard httpResponse.statusCode == 200 else {
            throw Self.error(statusCode: httpResponse.statusCode, body: data)
        }
        do {
            return try JSONDecoder().decode(VoiceSessionTurnResponse.self, from: data)
        } catch {
            throw VoiceSessionAPIError.invalidContract
        }
    }

    /// 把非 200 响应映射为界面可处理的错误。
    ///
    /// - Parameters:
    ///   - statusCode: HTTP 状态码。
    ///   - body: 错误响应体 `{ code, message, details? }`。
    /// - Returns: 对应的错误。
    static func error(statusCode: Int, body: Data) -> VoiceSessionAPIError {
        switch statusCode {
        case 401:
            return .unauthorized
        case 413:
            return .sessionTooLong
        case 429:
            let errorBody = try? JSONDecoder().decode(VoiceSessionErrorBody.self, from: body)
            return .rateLimited(isDaily: errorBody?.details?.rule == "per_day")
        case 502, 503:
            return .serviceUnavailable
        default:
            return .invalidContract
        }
    }
}

/// 服务端统一错误响应中需要读取的部分。
private nonisolated struct VoiceSessionErrorBody: Decodable {
    /// 限流错误的详情。
    nonisolated struct Details: Decodable {
        /// 触发的限流规则：`per_minute` 或 `per_day`。
        let rule: String?
    }

    /// 错误码。
    let code: String

    /// 错误详情。
    let details: Details?
}
