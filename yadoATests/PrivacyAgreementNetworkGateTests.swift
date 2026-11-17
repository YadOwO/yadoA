import Foundation
import Testing
@testable import yadoA

/// 用记录请求的假 `URLProtocol` 证明：不允许联网时各 store 一个请求都不发，允许后才会发。
@Suite("同意前不联网", .serialized)
@MainActor
struct PrivacyAgreementNetworkGateTests {
    /// 每个用例一份隔离的本机存储。
    private func makeDefaults(_ name: String) throws -> UserDefaults {
        let suiteName = "PrivacyAgreementNetworkGateTests.\(name)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("产品目录：不允许联网时不发请求，允许后请求 series.json")
    func catalogRespectsGate() async throws {
        RecordingURLProtocol.reset()
        var allowed = false
        let store = SeriesCatalogStore(
            fetcher: SeriesCatalogAPI(session: RecordingURLProtocol.makeSession()),
            defaults: try makeDefaults("catalog"),
            isNetworkAllowed: { allowed }
        )

        await store.refresh()
        #expect(RecordingURLProtocol.recordedRequests.isEmpty)

        allowed = true
        await store.refresh()
        let requests = RecordingURLProtocol.recordedRequests
        #expect(requests.count == 1)
        #expect(requests.first?.url?.lastPathComponent == "series.json")
    }

    @Test("意见反馈未读数：不允许联网时不发请求，允许后发请求")
    func feedbackRespectsGate() async {
        RecordingURLProtocol.reset()
        var allowed = false
        let store = FeedbackStore(
            api: FeedbackAPI(session: RecordingURLProtocol.makeSession(), accessToken: { "token" }),
            currentUserID: { "user-1" },
            isNetworkAllowed: { allowed }
        )

        await store.refreshUnread()
        #expect(RecordingURLProtocol.recordedRequests.isEmpty)

        allowed = true
        await store.refreshUnread()
        // 响应体解码是否成功不影响结论，只数请求
        #expect(RecordingURLProtocol.recordedRequests.count == 1)
    }

    @Test("AI 点数和签到状态：不允许联网时不发请求，允许后发请求")
    func aiPointsRespectsGate() async throws {
        RecordingURLProtocol.reset()
        var allowed = false
        let store = AIPointsStore(
            api: AIBillingAPI(session: RecordingURLProtocol.makeSession(), accessToken: { "token" }),
            defaults: try makeDefaults("points"),
            currentUserID: { "user-1" },
            isNetworkAllowed: { allowed }
        )

        await store.refresh()
        await store.refreshCheckInStatus()
        #expect(RecordingURLProtocol.recordedRequests.isEmpty)

        allowed = true
        await store.refreshCheckInStatus()
        #expect(!RecordingURLProtocol.recordedRequests.isEmpty)
        let afterCheckIn = RecordingURLProtocol.recordedRequests.count
        await store.refresh()
        #expect(RecordingURLProtocol.recordedRequests.count > afterCheckIn)
    }

    @Test("接到同意状态上：同意前目录 store 不发请求，同意后才发")
    func catalogFollowsAgreementStore() async throws {
        RecordingURLProtocol.reset()
        let agreement = PrivacyAgreementStore(defaults: try makeDefaults("agreement"), requiresAgreement: true)
        let store = SeriesCatalogStore(
            fetcher: SeriesCatalogAPI(session: RecordingURLProtocol.makeSession()),
            defaults: try makeDefaults("agreement-catalog"),
            isNetworkAllowed: { agreement.allowsNetwork }
        )

        await store.refresh()
        #expect(RecordingURLProtocol.recordedRequests.isEmpty)

        agreement.decline()
        await store.refresh()
        #expect(RecordingURLProtocol.recordedRequests.isEmpty)

        agreement.agree()
        await store.refresh()
        #expect(RecordingURLProtocol.recordedRequests.count == 1)
    }
}
