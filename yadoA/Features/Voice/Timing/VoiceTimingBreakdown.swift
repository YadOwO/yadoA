import Foundation

/// 耗时树中的一行。
struct VoiceTimingRow: Identifiable, Equatable {
    /// 在树中的位置。
    let id: Int

    /// 缩进层级，0 为最外层。
    let depth: Int

    /// 阶段名称。
    let title: String

    /// 耗时（毫秒）；只作分组标题时为空。
    let durationMs: Double?

    /// 附加说明，如 token 数、请求标识。
    let detail: String?

    /// 是否为总计行。
    var isTotal = false
}

/// 把一句话的耗时整理成一棵树：会话卡片的耗时面板、「语音耗时」页和导出文本共用。
///
/// ```
/// 语音识别收尾          180ms
/// 第 1 次请求          2350ms
///   准备请求              3ms
///   获取登录凭证          1ms
///   网络建连             40ms
///   上传                 10ms
///   服务端             2260ms
///     模型首 token      960ms  输入 3100 tokens
///     模型生成         1280ms  输出 98 tokens · 77 tok/s
///   网络往返             30ms
///   下载                 10ms
/// 本地执行               60ms  3 个操作
/// 总计                 2630ms
/// ```
enum VoiceTimingBreakdown {
    /// 生成耗时树。
    ///
    /// - Parameters:
    ///   - timing: 一句话的耗时。
    ///   - locale: 文案语言。
    /// - Returns: 按显示顺序排列的各行。
    static func rows(for timing: VoiceTurnTiming, locale: Locale) -> [VoiceTimingRow] {
        var rows: [VoiceTimingRow] = []
        func add(_ depth: Int, _ key: String, _ durationMs: Double?, detail: String? = nil, title: String? = nil) {
            rows.append(VoiceTimingRow(
                id: rows.count,
                depth: depth,
                title: title ?? text(key, locale),
                durationMs: durationMs,
                detail: detail
            ))
        }

        if let speechMs = timing.speechFinalizeMs {
            add(0, "voice.timing.speech", speechMs)
        }
        for request in timing.requests {
            var failure: String?
            if request.outcome == .failed {
                failure = request.statusCode.map { "HTTP \($0)" } ?? text("voice.timing.failed", locale)
            }
            add(0, "", request.durationMs, detail: failure, title: String(
                format: text("voice.timing.request", locale), locale: locale, request.index
            ))
            add(1, "voice.timing.build", request.buildMs)
            if let tokenMs = request.tokenMs {
                add(1, "voice.timing.token", tokenMs)
            }
            if let network = request.network {
                let connection: String? = network.isReusedConnection ? text("voice.timing.connect.reused", locale) : network.protocolName
                add(1, "voice.timing.connect", network.connectMs, detail: connection)
                add(1, "voice.timing.upload", network.uploadMs)
            }
            if let server = request.server {
                add(1, "voice.timing.server", server.totalMs, detail: request.requestID.map { String($0.prefix(8)) })
                for span in server.spans {
                    add(2, "", span.durationMs, detail: spanDetail(span, in: server, locale: locale), title: spanTitle(span, locale: locale))
                }
            } else if request.network != nil {
                add(1, "voice.timing.server", nil, detail: text("voice.timing.server.unavailable", locale))
            }
            if let network = request.network {
                // 等待响应的时间扣掉服务端处理，剩下的是请求与响应在路上的时间
                if let serverMs = request.server?.totalMs {
                    add(1, "voice.timing.roundTrip", max(0, network.waitMs - serverMs))
                } else {
                    add(1, "voice.timing.wait", network.waitMs)
                }
                add(1, "voice.timing.download", network.downloadMs)
            } else if let transportMs = request.transportMs {
                add(1, "voice.timing.transport", transportMs)
            }
            if let executionMs = request.executionMs {
                add(0, "voice.timing.execute", executionMs, detail: String(
                    format: text("voice.timing.execute.detail", locale), locale: locale, request.toolCallCount
                ))
            }
        }
        rows.append(VoiceTimingRow(
            id: rows.count, depth: 0, title: text("voice.timing.total", locale), durationMs: timing.totalMs,
            detail: nil, isTotal: true
        ))
        return rows
    }

    /// 一句话的概要，如「2.63s · 请求 1 次」。
    ///
    /// - Parameters:
    ///   - timing: 一句话的耗时。
    ///   - locale: 文案语言。
    /// - Returns: 概要文字。
    static func summary(for timing: VoiceTurnTiming, locale: Locale) -> String {
        String(
            format: text("voice.timing.summary", locale),
            locale: locale,
            format(timing.totalMs),
            timing.requests.count
        )
    }

    /// 导出用的纯文本：每句一段，带会话、句序号与服务端请求标识，方便对照服务器日志。
    ///
    /// - Parameters:
    ///   - timings: 要导出的记录，按时间先后排列。
    ///   - locale: 文案语言。
    /// - Returns: 纯文本。
    static func exportText(for timings: [VoiceTurnTiming], locale: Locale) -> String {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.timeZone = .current
        return timings.map { timing in
            var lines = [
                "\(dateFormatter.string(from: timing.recordedAt))  session=\(timing.sessionID.prefix(8))"
                    + "  turn=\(timing.turnIndex)  \(timing.outcome.rawValue)  \(summary(for: timing, locale: locale))",
            ]
            for row in rows(for: timing, locale: locale) {
                let indent = String(repeating: "  ", count: row.depth + 1)
                let duration = row.durationMs.map(format) ?? "-"
                lines.append("\(indent)\(row.title)  \(duration)\(row.detail.map { "  \($0)" } ?? "")")
            }
            for request in timing.requests {
                if let requestID = request.requestID {
                    lines.append("  request \(request.index): \(requestID)")
                }
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// 一组耗时的中位数与 P95（最近秩法）。
    ///
    /// - Parameter values: 耗时（毫秒）。
    /// - Returns: 中位数与 P95；没有数据时为空。
    static func percentiles(_ values: [Double]) -> (p50: Double, p95: Double)? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        func percentile(_ p: Double) -> Double {
            let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
            return sorted[min(sorted.count, max(1, rank)) - 1]
        }
        return (percentile(50), percentile(95))
    }

    /// 耗时文字：1 秒以内用毫秒，10 毫秒以内保留一位小数，1 秒以上用秒并保留两位小数。
    ///
    /// - Parameter milliseconds: 毫秒数。
    /// - Returns: 如 `4.5ms`、`180ms`、`2.63s`。
    static func format(_ milliseconds: Double) -> String {
        if milliseconds >= 1000 {
            return String(format: "%.2fs", milliseconds / 1000)
        }
        if milliseconds < 10 {
            return String(format: "%.1fms", milliseconds)
        }
        return String(format: "%.0fms", milliseconds)
    }

    // MARK: - 私有方法

    /// 服务端阶段的名称；同一请求里第二次模型调用（参数不合法后重试）加上序号。
    private static func spanTitle(_ span: VoiceServerTiming.Span, locale: Locale) -> String {
        let key = switch span.kind {
        case "pre": "voice.timing.server.pre"
        case "prepare": "voice.timing.server.prepare"
        case "ttft": "voice.timing.server.ttft"
        case "gen": "voice.timing.server.gen"
        case "check": "voice.timing.server.check"
        case "handle": "voice.timing.server.handle"
        default: ""
        }
        let title = key.isEmpty ? span.name : text(key, locale)
        guard let step = span.step, step > 1 else { return title }
        return "\(title) #\(step)"
    }

    /// 模型阶段的 token 说明：首 token 显示输入 token 数，生成显示输出 token 数与速度。
    private static func spanDetail(_ span: VoiceServerTiming.Span, in server: VoiceServerTiming, locale: Locale) -> String? {
        switch span.kind {
        case "ttft":
            // 输入 token 数记在同一次调用的生成阶段上
            let generation = server.spans.first { $0.kind == "gen" && $0.step == span.step }
            return generation?.tokens("in").map {
                String(format: text("voice.timing.tokens.input", locale), locale: locale, $0)
            }
        case "gen":
            guard let output = span.tokens("out") else { return nil }
            let speed = span.durationMs > 0 ? Int((Double(output) / span.durationMs * 1000).rounded()) : 0
            return String(format: text("voice.timing.tokens.output", locale), locale: locale, output, speed)
        default:
            return nil
        }
    }

    private static func text(_ key: String, _ locale: Locale) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}
