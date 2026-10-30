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

    /// AI 点数不足，服务端没有调用模型。
    case insufficientPoints

    /// 计费轮次不合法（超时、超过请求次数上限或与首次请求不一致），本轮需要结束后重说。
    case turnInvalid

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
    /// - Parameters:
    ///   - request: 会话上下文与全部事件。
    ///   - turnID: 计费轮次 ID：用户每说一句（包括回答追问）生成新的，同一句的续步沿用，服务端据此每句只扣一次点数。
    ///   - tier: 模型档位：每句开始时取用户所选，同一句的续步沿用（中途换档位服务端会拒绝）；为 nil 时不带档位，
    ///     服务端按默认档位处理。
    ///   - trace: 追踪信息：带上会话、句序号与请求序号，并填回各段耗时；失败时也填回已经测到的部分。
    /// - Returns: 工具调用、追问或回复。
    /// - Throws: `VoiceSessionAPIError`。
    func send(
        _ request: VoiceSessionTurnRequest,
        turnID: UUID,
        tier: AIModelTier?,
        trace: VoiceRequestTrace
    ) async throws -> VoiceSessionTurnResponse
}

/// 调用 yado_ai `POST /v1/yadoa/voice-session/turn` 的网络客户端。
final class VoiceSessionAPI: VoiceSessionTurnSending {
    /// 指定的 AI 服务地址（不含路径）；为空时每次请求按 `AIServiceEnvironment` 取当前地址。
    private let endpointOverride: URL?

    /// 网络会话；测试可注入。
    private let session: URLSession

    /// 获取 AI 服务 access token 的动作。
    private let accessToken: () async throws -> String

    /// 每次请求开始时取一个余额回报动作；回报动作记着发起请求时的账号，响应回来时已换账号就丢弃。
    ///
    /// 服务端带回的余额来自扣点成功的响应头，或点数不足时错误详情里的余额。
    private let pointsReporter: () -> (Int) -> Void

    /// 读取当前账号是否授权上报本次内容；默认未授权。
    private let isTraceConsented: () -> Bool

    /// 单次请求的超时时长；服务端一步最多调用模型两次，每次超时 20 秒。
    static let requestTimeout: TimeInterval = 45

    /// 计费轮次 ID 的请求头，与 yado_ai `shared/billing/headers.ts` 一致。
    static let turnIDHeader = "X-AI-Turn-Id"

    /// 模型档位的请求头，与 yado_ai `shared/ai/model-header.ts` 一致。
    static let tierHeader = "X-AI-Tier"

    /// “帮助改进 AI”授权的请求头，与 yado_ai `shared/ai/trace-consent.ts` 一致；未授权时不带。
    static let traceConsentHeader = "X-AI-Trace-Consent"

    /// 结算后余额的响应头，与 yado_ai `shared/billing/headers.ts` 一致；只在实际扣点模式下返回。
    static let pointsBalanceHeader = "X-AI-Points-Balance"

    /// 创建客户端。
    ///
    /// - Parameters:
    ///   - endpoint: AI 服务地址；为空时每次请求取 `AIServiceEnvironment.currentEndpoint`，开发者设置里切换后立即生效。
    ///   - session: 网络会话。
    ///   - pointsReporter: 每次请求开始时取余额回报动作，用于就地刷新点数显示；通常是 `AIPointsStore.balanceReporter()`。
    ///   - isTraceConsented: 读取当前账号是否打开了“帮助改进 AI”；通常是 `AIPointsStore.isTraceConsented`。
    ///   - accessToken: 获取 access token 的动作，抛出 `ServiceAuthError`。
    init(
        endpoint: URL? = nil,
        session: URLSession = .shared,
        pointsReporter: @escaping () -> (Int) -> Void = { { _ in } },
        isTraceConsented: @escaping () -> Bool = { false },
        accessToken: @escaping () async throws -> String
    ) {
        self.endpointOverride = endpoint
        self.session = session
        self.pointsReporter = pointsReporter
        self.isTraceConsented = isTraceConsented
        self.accessToken = accessToken
    }

    /// 本次请求要连的地址。
    private var endpoint: URL {
        endpointOverride ?? AIServiceEnvironment.currentEndpoint
    }

    func send(
        _ request: VoiceSessionTurnRequest,
        turnID: UUID,
        tier: AIModelTier?,
        trace: VoiceRequestTrace
    ) async throws -> VoiceSessionTurnResponse {
        // 在取凭证前记下账号：请求期间换了账号，带回的余额不会记到新账号上
        let reportPointsBalance = pointsReporter()
        let tokenStartedAt = VoiceTimingClock.now
        let token: String
        do {
            // 成功、失败都记下：凭证过期后刷新慢、最终失败时，正需要看出时间耗在这一段
            defer { trace.tokenMs = VoiceTimingClock.milliseconds(since: tokenStartedAt) }
            token = try await accessToken()
        } catch ServiceAuthError.notSignedIn {
            throw VoiceSessionAPIError.notSignedIn
        } catch ServiceAuthError.sessionExpired {
            throw VoiceSessionAPIError.sessionExpired
        } catch {
            throw VoiceSessionAPIError.network
        }

        var urlRequest = URLRequest(url: endpoint.appending(path: "v1/yadoa/voice-session/turn"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = Self.requestTimeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(turnID.uuidString, forHTTPHeaderField: Self.turnIDHeader)
        if let tier {
            urlRequest.setValue(tier.rawValue, forHTTPHeaderField: Self.tierHeader)
        }
        if isTraceConsented() {
            urlRequest.setValue("1", forHTTPHeaderField: Self.traceConsentHeader)
        }
        // 服务端日志据此把同一句话的多次请求串起来
        urlRequest.setValue(trace.sessionID, forHTTPHeaderField: VoiceRequestTrace.Header.sessionID)
        urlRequest.setValue(String(trace.turn), forHTTPHeaderField: VoiceRequestTrace.Header.turn)
        urlRequest.setValue(String(trace.request), forHTTPHeaderField: VoiceRequestTrace.Header.request)
        do {
            urlRequest.httpBody = try JSONEncoder().encode(request)
        } catch {
            throw VoiceSessionAPIError.invalidContract
        }

        let data: Data
        let response: URLResponse
        let metrics = VoiceTaskMetricsCollector()
        let transportStartedAt = VoiceTimingClock.now
        // 记下网络耗时；请求失败时也记，超时这类情况正需要看卡在哪一段
        func recordTransport() {
            trace.transportMs = VoiceTimingClock.milliseconds(since: transportStartedAt)
            trace.network = metrics.timing
        }
        do {
            (data, response) = try await session.data(for: urlRequest, delegate: metrics)
        } catch let error as URLError where error.code == .timedOut {
            recordTransport()
            throw VoiceSessionAPIError.timeout
        } catch {
            recordTransport()
            throw VoiceSessionAPIError.network
        }
        recordTransport()
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoiceSessionAPIError.invalidContract
        }
        trace.record(httpResponse)
        // 扣点已在服务端结算，先回报余额，响应体解码失败也不影响余额显示
        if let balance = Self.pointsBalance(from: httpResponse, body: data) {
            reportPointsBalance(balance)
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

    /// 从响应中读出服务端结算后的余额。
    ///
    /// - Parameters:
    ///   - response: HTTP 响应，200 时从 `X-AI-Points-Balance` 响应头读取。
    ///   - body: 响应体，402 时从错误详情的 `balance` 读取。
    /// - Returns: 余额；模拟模式、结算失败或其他状态码时为 nil。
    static func pointsBalance(from response: HTTPURLResponse, body: Data) -> Int? {
        switch response.statusCode {
        case 200:
            return response.value(forHTTPHeaderField: pointsBalanceHeader).flatMap { Int($0) }
        case 402:
            return (try? JSONDecoder().decode(VoiceSessionErrorBody.self, from: body))?.details?.balance
        default:
            return nil
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
        case 402:
            return .insufficientPoints
        case 409:
            return .turnInvalid
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
    /// 错误详情；不同错误码带不同字段。
    nonisolated struct Details: Decodable {
        /// 限流错误触发的规则：`per_minute` 或 `per_day`。
        let rule: String?

        /// 点数不足时的当前余额。
        let balance: Int?
    }

    /// 错误码。
    let code: String

    /// 错误详情。
    let details: Details?
}
