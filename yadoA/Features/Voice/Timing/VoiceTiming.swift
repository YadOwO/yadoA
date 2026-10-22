import Foundation
import Observation
import os
import StoreKit

/// 耗时计算使用的单调时钟：不受系统改时间影响。
nonisolated enum VoiceTimingClock {
    /// 当前时刻。
    static var now: ContinuousClock.Instant { ContinuousClock.now }

    /// 从某个时刻到现在经过的毫秒数。
    ///
    /// - Parameter start: 起始时刻。
    /// - Returns: 经过的毫秒数。
    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        milliseconds(ContinuousClock.now - start)
    }

    /// 把时长换成毫秒数。
    ///
    /// - Parameter duration: 时长。
    /// - Returns: 毫秒数。
    static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}

/// 服务端 `Server-Timing` 响应头中的阶段耗时。
///
/// 阶段名与 yado_ai `src/shared/timing.ts` 一致：`pre`、`prepare`、`ttft-N`、`gen-N`、`check-N`、`handle`，
/// 最后一项 `total` 为服务端总耗时。
nonisolated struct VoiceServerTiming: Codable, Equatable, Sendable {
    /// 一个阶段。
    nonisolated struct Span: Codable, Equatable, Sendable {
        /// 阶段名，如 `ttft-1`。
        let name: String

        /// 耗时（毫秒）。
        let durationMs: Double

        /// 附加说明；模型生成阶段为 token 数，如 `in=3100 out=98`。
        let detail: String?

        /// 阶段种类：去掉序号后的名字，如 `ttft`。
        var kind: String {
            guard let dash = name.lastIndex(of: "-"), Int(name[name.index(after: dash)...]) != nil else { return name }
            return String(name[..<dash])
        }

        /// 第几次模型调用；不属于某次调用的阶段为空。
        var step: Int? {
            guard let dash = name.lastIndex(of: "-") else { return nil }
            return Int(name[name.index(after: dash)...])
        }

        /// 从附加说明中读出 token 数。
        ///
        /// - Parameter key: `in` 或 `out`。
        /// - Returns: token 数；没有时为空。
        func tokens(_ key: String) -> Int? {
            detail?.split(separator: " ").lazy.compactMap { pair -> Int? in
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2, parts[0] == key else { return nil }
                return Int(parts[1])
            }.first
        }
    }

    /// 除 `total` 以外的阶段，按发生顺序排列。
    let spans: [Span]

    /// 服务端总耗时；响应头中没有 `total` 时为空。
    let totalMs: Double?

    /// 全部模型调用的输出 token 数。
    var outputTokens: Int {
        spans.compactMap { $0.tokens("out") }.reduce(0, +)
    }

    /// 解析 `Server-Timing` 响应头。
    ///
    /// - Parameter header: 响应头的值，如 `pre;dur=1.2, gen-1;dur=1280;desc="in=3100 out=98", total;dur=1290`。
    /// - Returns: 解析结果；没有任何可用阶段时为空。
    static func parse(_ header: String?) -> VoiceServerTiming? {
        guard let header else { return nil }
        var spans: [Span] = []
        var totalMs: Double?
        for entry in header.split(separator: ",") {
            let parts = entry.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = parts.first, !name.isEmpty else { continue }
            var duration: Double?
            var detail: String?
            for parameter in parts.dropFirst() {
                let pair = parameter.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                switch pair[0] {
                case "dur": duration = Double(pair[1])
                case "desc": detail = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                default: break
                }
            }
            guard let duration else { continue }
            if name == "total" {
                totalMs = duration
            } else {
                spans.append(Span(name: name, durationMs: duration, detail: detail))
            }
        }
        guard !spans.isEmpty || totalMs != nil else { return nil }
        return VoiceServerTiming(spans: spans, totalMs: totalMs)
    }
}

/// 一次请求在网络上的耗时，取自 `URLSessionTaskMetrics`。
nonisolated struct VoiceNetworkTiming: Codable, Equatable, Sendable {
    /// DNS 解析、建立 TCP 连接与 TLS 握手；复用连接时为 0。
    let connectMs: Double

    /// 是否复用了已有连接。
    let isReusedConnection: Bool

    /// 发送请求头与请求体。
    let uploadMs: Double

    /// 请求发完到收到响应第一个字节：服务端处理加网络往返。
    let waitMs: Double

    /// 接收响应体。
    let downloadMs: Double

    /// 网络协议，如 `h2`、`http/1.1`。
    let protocolName: String?

    /// 逐项创建，供测试与解码使用。
    init(
        connectMs: Double,
        isReusedConnection: Bool,
        uploadMs: Double,
        waitMs: Double,
        downloadMs: Double,
        protocolName: String? = nil
    ) {
        self.connectMs = connectMs
        self.isReusedConnection = isReusedConnection
        self.uploadMs = uploadMs
        self.waitMs = waitMs
        self.downloadMs = downloadMs
        self.protocolName = protocolName
    }

    /// 从系统采集的网络指标中取出最后一次实际发出的网络请求。
    ///
    /// - Parameter metrics: 任务结束时系统给出的指标。
    init?(metrics: URLSessionTaskMetrics) {
        let transactions = metrics.transactionMetrics
        guard let transaction = transactions.last(where: { $0.resourceFetchType == .networkLoad }) ?? transactions.last
        else { return nil }
        func span(_ start: Date?, _ end: Date?) -> Double {
            guard let start, let end else { return 0 }
            return max(0, end.timeIntervalSince(start) * 1000)
        }
        connectMs = span(transaction.domainLookupStartDate ?? transaction.connectStartDate, transaction.connectEndDate)
        isReusedConnection = transaction.isReusedConnection
        uploadMs = span(transaction.requestStartDate, transaction.requestEndDate)
        waitMs = span(transaction.requestEndDate, transaction.responseStartDate)
        downloadMs = span(transaction.responseStartDate, transaction.responseEndDate)
        protocolName = transaction.networkProtocolName
    }
}

/// 收集单个请求网络指标的任务代理；系统在任务完成前回调，回调在后台队列执行。
nonisolated final class VoiceTaskMetricsCollector: NSObject, URLSessionTaskDelegate, Sendable {
    private let state = OSAllocatedUnfairLock<VoiceNetworkTiming?>(initialState: nil)

    /// 已收集到的网络耗时；任务结束前为空。
    var timing: VoiceNetworkTiming? {
        state.withLock { $0 }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let timing = VoiceNetworkTiming(metrics: metrics)
        state.withLock { $0 = timing }
    }
}

/// 一次请求的追踪信息：会话层传入标识，网络层填回耗时，请求失败时也能读到已经测到的部分。
final class VoiceRequestTrace {
    /// 发给服务端的追踪请求头，与 yado_ai `middleware/request-timing.ts` 一致。
    enum Header {
        /// 会话标识。
        static let sessionID = "X-Client-Session-Id"
        /// 会话中的第几句。
        static let turn = "X-Client-Turn"
        /// 这句话的第几次请求。
        static let request = "X-Client-Request"
    }

    /// 会话标识；结束会话后重新生成。
    let sessionID: String

    /// 会话中的第几句，从 1 开始。
    let turn: Int

    /// 这句话的第几次请求，从 1 开始。
    let request: Int

    /// 获取登录凭证的耗时；凭证过期时含刷新的网络请求。
    var tokenMs: Double?

    /// 从发出请求到收到完整响应的耗时（客户端测得）。
    var transportMs: Double?

    /// 网络各段耗时；系统没有给出指标时为空。
    var network: VoiceNetworkTiming?

    /// 服务端各阶段耗时；响应没有带 `Server-Timing` 时为空。
    var server: VoiceServerTiming?

    /// 服务端的请求标识，用来在服务器日志里找到这次请求。
    var requestID: String?

    /// HTTP 状态码；请求没有到达服务端时为空。
    var statusCode: Int?

    /// 创建追踪信息。
    ///
    /// - Parameters:
    ///   - sessionID: 会话标识。
    ///   - turn: 会话中的第几句。
    ///   - request: 这句话的第几次请求。
    init(sessionID: String, turn: Int, request: Int) {
        self.sessionID = sessionID
        self.turn = turn
        self.request = request
    }

    /// 记录响应头中的服务端耗时与请求标识。
    ///
    /// - Parameter response: HTTP 响应。
    func record(_ response: HTTPURLResponse) {
        statusCode = response.statusCode
        requestID = response.value(forHTTPHeaderField: "X-Request-Id")
        server = VoiceServerTiming.parse(response.value(forHTTPHeaderField: "Server-Timing"))
    }
}

/// 一句话中的一次请求。
nonisolated struct VoiceRequestTiming: Codable, Equatable, Sendable {
    /// 这次请求的结果。
    nonisolated enum Outcome: String, Codable, Sendable {
        /// 下发了工具调用。
        case toolCalls
        /// 追问。
        case ask
        /// 回复。
        case reply
        /// 请求失败。
        case failed
    }

    /// 这句话的第几次请求，从 1 开始。
    let index: Int

    /// 从开始组装请求到拿到解析后的响应的总耗时。
    let durationMs: Double

    /// 读取账户、分类并组装请求。
    let buildMs: Double

    /// 获取登录凭证。
    let tokenMs: Double?

    /// 发出请求到收到完整响应。
    let transportMs: Double?

    /// 网络各段耗时。
    let network: VoiceNetworkTiming?

    /// 服务端各阶段耗时。
    let server: VoiceServerTiming?

    /// 服务端的请求标识。
    let requestID: String?

    /// HTTP 状态码。
    let statusCode: Int?

    /// 这次请求的结果。
    let outcome: Outcome

    /// 下发的工具调用个数。
    var toolCallCount = 0

    /// 在本地执行这些工具调用的耗时；没有工具调用时为空。
    var executionMs: Double?
}

/// 一句话从松手到出结果的完整时间线。只含耗时与数量，不含用户说的话。
nonisolated struct VoiceTurnTiming: Codable, Equatable, Sendable, Identifiable {
    /// 这句话的结果。
    nonisolated enum Outcome: String, Codable, Sendable {
        /// 回复（服务端回复或本地生成的结果提示）。
        case reply
        /// 追问。
        case ask
        /// 失败。
        case failed
    }

    /// 与会话中这一轮的标识相同。
    let id: UUID

    /// 记录时间。
    let recordedAt: Date

    /// 会话标识，与服务端日志中的 sessionId 对应。
    let sessionID: String

    /// 会话中的第几句。
    let turnIndex: Int

    /// 松手到拿到最终识别文字；点选候选项时为空。
    let speechFinalizeMs: Double?

    /// 开始处理到本轮结束。
    let processingMs: Double

    /// 本句的全部请求。
    let requests: [VoiceRequestTiming]

    /// 这句话的结果。
    let outcome: Outcome

    /// 从松手到出结果的总耗时。
    var totalMs: Double {
        (speechFinalizeMs ?? 0) + processingMs
    }
}

/// 语音记账耗时的系统日志与 signpost：Xcode 控制台、「控制台」App 按 `VoiceTiming` 分类过滤，
/// Instruments 的 os_signpost 模板里能看到识别、请求、执行的时间轴。
nonisolated enum VoiceTimingLog {
    /// 日志分类。
    static let category = "VoiceTiming"

    /// 时间轴打点。
    static let signposter = OSSignposter(subsystem: subsystem, category: category)

    /// 文字日志；只输出耗时、数量与标识，不输出用户说的话。
    static let logger = Logger(subsystem: subsystem, category: category)

    private static let subsystem = Bundle.main.bundleIdentifier ?? "yadoA"

    /// 输出一句话的耗时：一行汇总，每次请求一行明细。
    ///
    /// - Parameter timing: 一句话的耗时。
    static func log(_ timing: VoiceTurnTiming) {
        let speech = timing.speechFinalizeMs.map { " speech=\(Int($0))ms" } ?? ""
        let summary = "turn \(timing.turnIndex) \(timing.outcome.rawValue) total=\(Int(timing.totalMs))ms"
            + "\(speech) requests=\(timing.requests.count) session=\(timing.sessionID.prefix(8))"
        logger.info("\(summary, privacy: .public)")
        for request in timing.requests {
            var parts = ["  request \(request.index) \(request.outcome.rawValue) \(Int(request.durationMs))ms"]
            parts.append("build=\(Int(request.buildMs))")
            if let tokenMs = request.tokenMs { parts.append("token=\(Int(tokenMs))") }
            if let network = request.network {
                parts.append("connect=\(Int(network.connectMs)) upload=\(Int(network.uploadMs))")
                parts.append("wait=\(Int(network.waitMs)) download=\(Int(network.downloadMs))")
            }
            if let server = request.server {
                parts.append(server.spans.map { "\($0.name)=\(Int($0.durationMs))" }.joined(separator: " "))
                if let totalMs = server.totalMs { parts.append("server=\(Int(totalMs))") }
            }
            if let executionMs = request.executionMs { parts.append("execute=\(Int(executionMs))") }
            if let requestID = request.requestID { parts.append("id=\(requestID)") }
            let line = parts.joined(separator: " ")
            logger.info("\(line, privacy: .public)")
        }
    }
}

/// 耗时面板与「语音耗时」页是否可见：DEBUG 包始终可见，Release 包只在 TestFlight 安装时可见。
///
/// 系统日志与 signpost 不受影响，始终输出。
enum VoiceTimingFeature {
    /// 可被界面观察的开关；Release 包启动后判断完成时，已经显示的界面随之刷新。
    @Observable
    final class State {
        /// 当前是否可见。
        var isEnabled: Bool = {
            #if DEBUG
            return true
            #else
            return false
            #endif
        }()
    }

    private static let state = State()

    /// 当前是否可见。
    static var isEnabled: Bool { state.isEnabled }

    /// 启动时判断 Release 包是否从 TestFlight 安装；DEBUG 包不做任何事。
    static func resolve() async {
        #if !DEBUG
        guard let result = try? await AppTransaction.shared else { return }
        switch result {
        case let .verified(transaction), let .unverified(transaction, _):
            state.isEnabled = transaction.environment == .sandbox
        }
        #endif
    }
}
