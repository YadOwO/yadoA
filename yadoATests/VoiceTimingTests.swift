import Foundation
import Testing
@testable import yadoA

/// 验证语音记账耗时：Server-Timing 解析、耗时树拆解、本地记录的保留与读写。
@Suite("语音记账耗时")
@MainActor
struct VoiceTimingTests {
    private static let locale = Locale(identifier: "zh-Hans")

    @Test("解析 Server-Timing：阶段按顺序保留，total 单独取出，token 数从说明中读出")
    func parsesServerTiming() throws {
        let header = #"pre;dur=1.2, prepare;dur=0.4, ttft-1;dur=960, gen-1;dur=1280;desc="in=3100 out=98", check-1;dur=2.1, ttft-2;dur=800, gen-2;dur=400;desc="in=3300 out=30", check-2;dur=1, total;dur=3445"#
        let timing = try #require(VoiceServerTiming.parse(header))
        #expect(timing.spans.map(\.name) == ["pre", "prepare", "ttft-1", "gen-1", "check-1", "ttft-2", "gen-2", "check-2"])
        #expect(timing.totalMs == 3445)
        #expect(timing.outputTokens == 128)
        let generation = try #require(timing.spans.first { $0.name == "gen-1" })
        #expect(generation.kind == "gen")
        #expect(generation.step == 1)
        #expect(generation.tokens("in") == 3100)
        #expect(generation.tokens("out") == 98)
        #expect(timing.spans.first?.step == nil)

        #expect(VoiceServerTiming.parse(nil) == nil)
        #expect(VoiceServerTiming.parse("") == nil)
        #expect(VoiceServerTiming.parse("broken, also;broken") == nil)
    }

    @Test("耗时树：服务端阶段挂在请求下，网络往返为等待时间扣掉服务端处理，末行为总计")
    func buildsBreakdownRows() {
        let rows = VoiceTimingBreakdown.rows(for: Self.sampleTiming(), locale: Self.locale)
        let titles = rows.map(\.title)
        #expect(titles.first == text("voice.timing.speech"))
        #expect(titles.contains(String(format: text("voice.timing.request"), 1)))
        #expect(rows.last?.isTotal == true)
        #expect(rows.last?.durationMs == 2630)

        let server = rows.first { $0.title == text("voice.timing.server") }
        #expect(server?.depth == 1)
        #expect(server?.durationMs == 2260)
        let ttft = rows.first { $0.title == text("voice.timing.server.ttft") }
        #expect(ttft?.depth == 2)
        let roundTrip = rows.first { $0.title == text("voice.timing.roundTrip") }
        #expect(roundTrip?.durationMs == 30)
        let execute = rows.first { $0.title == text("voice.timing.execute") }
        #expect(execute?.depth == 0)
        #expect(execute?.durationMs == 60)
    }

    @Test("导出文本带会话、句序号与服务端请求标识，不含用户说的话")
    func exportsText() {
        let text = VoiceTimingBreakdown.exportText(for: [Self.sampleTiming()], locale: Self.locale)
        #expect(text.contains("session=11111111"))
        #expect(text.contains("turn=3"))
        #expect(text.contains("request 1: 8f2a-request"))
    }

    @Test("耗时文字与百分位")
    func formatsDurationsAndPercentiles() throws {
        #expect(VoiceTimingBreakdown.format(4.46) == "4.5ms")
        #expect(VoiceTimingBreakdown.format(180) == "180ms")
        #expect(VoiceTimingBreakdown.format(2630) == "2.63s")
        #expect(VoiceTimingBreakdown.percentiles([]) == nil)
        let stats = try #require(VoiceTimingBreakdown.percentiles([5, 1, 4, 2, 3]))
        #expect(stats.p50 == 3)
        #expect(stats.p95 == 5)
    }

    @Test("本地记录最多保留 50 句，写入文件后可重新读出，清空后为空")
    func storesRecords() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "VoiceTimingTests-\(UUID().uuidString)/records.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = VoiceTimingStore(fileURL: url)
        for index in 1...(VoiceTimingStore.maxRecords + 3) {
            store.append(Self.sampleTiming(turnIndex: index))
        }
        #expect(store.records.count == VoiceTimingStore.maxRecords)
        #expect(store.records.first?.turnIndex == 4)

        let reloaded = VoiceTimingStore(fileURL: url)
        #expect(reloaded.records == store.records)

        reloaded.clear()
        #expect(VoiceTimingStore(fileURL: url).records.isEmpty)
    }

    // MARK: - 辅助

    /// 一句话的样例耗时：识别收尾 180ms，一次请求 2390ms（服务端 2260ms），本地执行 60ms。
    private static func sampleTiming(turnIndex: Int = 3) -> VoiceTurnTiming {
        let server = VoiceServerTiming.parse(
            #"pre;dur=3, prepare;dur=2, ttft-1;dur=960, gen-1;dur=1280;desc="in=3100 out=98", check-1;dur=4, total;dur=2260"#
        )
        let network = VoiceNetworkTiming(connectMs: 40, isReusedConnection: false, uploadMs: 10, waitMs: 2290, downloadMs: 10)
        let request = VoiceRequestTiming(
            index: 1, durationMs: 2390, buildMs: 3, tokenMs: 1, transportMs: 2350, network: network, server: server,
            requestID: "8f2a-request", statusCode: 200, outcome: .toolCalls, toolCallCount: 3, executionMs: 60
        )
        return VoiceTurnTiming(
            id: UUID(), recordedAt: Date(timeIntervalSince1970: 1_792_470_600),
            sessionID: "11111111-2222-3333-4444-555555555555", turnIndex: turnIndex,
            speechFinalizeMs: 180, processingMs: 2450, requests: [request], outcome: .reply
        )
    }

    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: Self.locale)
    }
}
