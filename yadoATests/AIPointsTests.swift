import Foundation
import Testing
@testable import yadoA

/// 验证 AI 点数：契约解码、明细展示映射、查询请求构造、余额状态与流水分页。
@Suite("AI 点数")
@MainActor
struct AIPointsTests {
    // MARK: - 契约

    @Test("余额、流水与模型列表解码：时间带毫秒，过期流水可识别，未知流水类型兜底，默认模型取每轮点数")
    func decodesBillingContract() throws {
        let walletJSON = """
        {"mode":"enforce","balance":98,"lots":[
          {"points":90,"expiresAt":"2027-01-26T02:32:00.000Z"},{"points":8,"expiresAt":"2027-02-01T00:00:00Z"}
        ],"ruleVersion":"2026-10-28.3"}
        """
        let wallet = try JSONDecoder().decode(AIWallet.self, from: Data(walletJSON.utf8))
        #expect(wallet.balance == 98)
        #expect(wallet.lots.map(\.points) == [90, 8])
        #expect(wallet.lots[0].expiresAt == Date(timeIntervalSince1970: 1_800_930_720))

        let walletWithoutLots = try JSONDecoder().decode(
            AIWallet.self,
            from: Data(#"{"mode":"enforce","balance":98,"ruleVersion":"2026-10-28.2"}"#.utf8)
        )
        #expect(walletWithoutLots.lots.isEmpty)

        let pageJSON = """
        {"entries":[
          {"id":"12","kind":"charge","points":-2,"balanceAfter":98,"feature":"yadoa.voice_session",
           "model":"qwen3.8-27b","reason":null,"createdAt":"2026-10-28T02:32:00.000Z"},
          {"id":"3","kind":"grant","points":100,"balanceAfter":100,"feature":null,"model":null,
           "reason":"initial_grant","createdAt":"2026-10-27T09:10:00Z"},
          {"id":"2","kind":"bonus_v2","points":5,"balanceAfter":0,"feature":null,"model":null,
           "reason":null,"createdAt":"2026-10-27T09:00:00.000Z"},
          {"id":"1","kind":"expire","points":-5,"balanceAfter":0,"feature":null,"model":null,
           "reason":"expired","createdAt":"2026-10-27T08:00:00.000Z"}
        ],"nextCursor":"1"}
        """
        let page = try JSONDecoder().decode(AICreditEntryPage.self, from: Data(pageJSON.utf8))
        #expect(page.nextCursor == "1")
        #expect(page.entries.map(\.kind) == [.charge, .grant, .unknown, .expire])
        #expect(page.entries[0].feature == AICreditEntry.voiceSessionFeature)
        #expect(page.entries[0].createdAt == Date(timeIntervalSince1970: 1_793_154_720))
        #expect(page.entries[1].reason == AICreditEntry.initialGrantReason)
        #expect(page.entries[1].createdAt == Date(timeIntervalSince1970: 1_793_092_200))

        let lastPage = try JSONDecoder().decode(
            AICreditEntryPage.self,
            from: Data(#"{"entries":[],"nextCursor":null}"#.utf8)
        )
        #expect(lastPage.entries.isEmpty)
        #expect(lastPage.nextCursor == nil)

        let modelsJSON = """
        {"defaults":{"text":"qwen3.8-27b","vision":"qwen3.8-27b"},"models":[
          {"id":"qwen3.8-27b","provider":"modelscope","modelId":"Qwen/Qwen3.8-27B","capabilities":["text","vision"],
           "isAvailable":true,"pointsPerTurn":2},
          {"id":"qwen3.8-flash-next","provider":"modelscope","modelId":"Qwen/Qwen3.8-Flash","capabilities":["text"],
           "isAvailable":true,"pointsPerTurn":1}
        ]}
        """
        let models = try JSONDecoder().decode(AIModelList.self, from: Data(modelsJSON.utf8))
        #expect(models.defaultTextPointsPerTurn == 2)

        let missingDefault = AIModelList(defaults: .init(text: "gone"), models: models.models)
        #expect(missingDefault.defaultTextPointsPerTurn == nil)
    }

    @Test("流水时间不是 ISO 8601 时整页解码失败")
    func rejectsMalformedTimestamp() {
        let json = #"{"entries":[{"id":"1","kind":"grant","points":1,"balanceAfter":1,"createdAt":"yesterday"}],"nextCursor":null}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AICreditEntryPage.self, from: Data(json.utf8))
        }
    }

    @Test("明细标题与图标：扣点按能力、赠送按原因区分，不认识的用类型兜底")
    func mapsEntryPresentation() {
        let voice = Self.entry(kind: .charge, points: -2, feature: AICreditEntry.voiceSessionFeature)
        let otherCharge = Self.entry(kind: .charge, points: -1, feature: "yadoi.item_extract")
        let welcome = Self.entry(kind: .grant, points: 100, reason: AICreditEntry.initialGrantReason)
        let compensation = Self.entry(kind: .grant, points: 50, reason: "compensation")

        #expect(voice.titleKey == "ai.entry.voiceSession")
        #expect(voice.symbol == "mic")
        #expect(otherCharge.titleKey == "ai.entry.charge")
        #expect(otherCharge.symbol == "sparkles")
        #expect(welcome.titleKey == "ai.entry.grant.initial")
        #expect(compensation.titleKey == "ai.entry.grant")
        #expect(Self.entry(kind: .refund, points: 2).titleKey == "ai.entry.refund")
        #expect(Self.entry(kind: .adjust, points: -20).titleKey == "ai.entry.adjust")
        #expect(Self.entry(kind: .expire, points: -5, reason: "expired").titleKey == "ai.entry.expire")
        #expect(Self.entry(kind: .expire, points: -5).symbol == "hourglass")
        #expect(Self.entry(kind: .unknown, points: 1).titleKey == "ai.entry.other")

        let english = Locale(identifier: "en_US")
        #expect(welcome.signedPoints(locale: english) == "+100")
        #expect(voice.signedPoints(locale: english) == "-2")
    }

    @Test("点数文案有中英文")
    func localizesPointsCopy() {
        let english = Locale(identifier: "en")
        let simplifiedChinese = Locale(identifier: "zh-Hans")
        #expect(AccountLocalization.string("ai.points.title", locale: english) == "AI Points")
        #expect(AccountLocalization.string("ai.points.title", locale: simplifiedChinese) == "AI 点数")
        #expect(AccountLocalization.formatted("ai.rules.perTurn", value: "2", locale: simplifiedChinese) == "语音记账每说一句扣 2 点")
        #expect(AccountLocalization.string("ai.points.exhausted", locale: simplifiedChinese) == "点数已用完，暂时无法使用 AI 记账。")
        let expiry = AccountLocalization.string("ai.points.expiry", locale: simplifiedChinese)
        #expect(String(format: expiry, locale: simplifiedChinese, "98", "2027年1月26日") == "98 点将于 2027年1月26日 过期")
        #expect(AccountLocalization.string("ai.entry.expire", locale: english) == "Expired")
    }

    // MARK: - 接口

    @Test("查询请求的路径、分页参数与鉴权头")
    func buildsBillingRequests() throws {
        let endpoint = try #require(URL(string: "https://example.invalid"))
        let api = AIBillingAPI(endpoint: endpoint) { "token" }

        let wallet = api.makeURLRequest(.wallet, token: "abc")
        #expect(wallet.httpMethod == "GET")
        #expect(wallet.url?.absoluteString == "https://example.invalid/v1/billing/wallet")
        #expect(wallet.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
        #expect(wallet.timeoutInterval == AIBillingAPI.requestTimeout)

        let firstPage = api.makeURLRequest(.entries(cursor: nil, limit: 20), token: "abc")
        #expect(firstPage.url?.path() == "/v1/billing/entries")
        #expect(firstPage.url?.query() == "limit=20")

        let nextPage = api.makeURLRequest(.entries(cursor: "41", limit: 20), token: "abc")
        #expect(nextPage.url?.query() == "limit=20&cursor=41")

        let models = api.makeURLRequest(.models, token: "abc")
        #expect(models.url?.absoluteString == "https://example.invalid/v1/models")
    }

    @Test("查询接口错误状态码映射")
    func mapsBillingErrorStatusCodes() {
        #expect(AIBillingAPI.error(statusCode: 401) == .unauthorized)
        #expect(AIBillingAPI.error(statusCode: 429) == .serviceUnavailable)
        #expect(AIBillingAPI.error(statusCode: 503) == .serviceUnavailable)
        #expect(AIBillingAPI.error(statusCode: 400) == .invalidContract)
    }

    @Test("语音记账响应带回余额：200 读响应头，402 读错误详情，其余不读")
    func readsBalanceFromVoiceResponses() throws {
        let url = try #require(URL(string: "https://example.invalid/v1/yadoa/voice-session/turn"))
        let charged = try #require(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["X-AI-Points-Charged": "2", "X-AI-Points-Balance": "96"]
        ))
        #expect(VoiceSessionAPI.pointsBalance(from: charged, body: Data()) == 96)

        let simulated = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:]))
        #expect(VoiceSessionAPI.pointsBalance(from: simulated, body: Data()) == nil)

        let insufficient = try #require(HTTPURLResponse(url: url, statusCode: 402, httpVersion: nil, headerFields: [:]))
        let body = Data(#"{"code":"INSUFFICIENT_POINTS","message":"点数余额不足","details":{"required":2,"balance":1}}"#.utf8)
        #expect(VoiceSessionAPI.pointsBalance(from: insufficient, body: body) == 1)

        let unavailable = try #require(HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: [:]))
        #expect(VoiceSessionAPI.pointsBalance(from: unavailable, body: body) == nil)
    }

    // MARK: - 余额状态

    @Test("刷新取到余额与每轮点数，每轮点数只查一次")
    func refreshLoadsBalanceAndPointsPerTurn() async {
        let api = FakeAIBillingAPI()
        api.walletResults = [.success(AIWallet(balance: 100)), .success(AIWallet(balance: 98))]
        let store = AIPointsStore(api: api) { "user-1" }

        await store.refresh()
        #expect(store.balance == 100)
        #expect(store.pointsPerTurn == 2)
        #expect(!store.isExhausted)

        await store.refresh()
        #expect(store.balance == 98)
        #expect(api.modelCalls == 1)
    }

    @Test("刷新失败保留已有余额，未登录时清空余额")
    func refreshFailureKeepsBalanceAndSignOutClears() async {
        let api = FakeAIBillingAPI()
        api.walletResults = [.success(AIWallet(balance: 50)), .failure(.timeout)]
        var userID: String? = "user-1"
        let store = AIPointsStore(api: api) { userID }

        await store.refresh()
        await store.refresh()
        #expect(store.balance == 50)
        #expect(store.failure == .timeout)

        userID = nil
        await store.refresh()
        #expect(store.balance == nil)
        #expect(store.failure == nil)
        #expect(store.pointsPerTurn == 2)
    }

    @Test("语音记账带回的余额就地更新；换账号后不展示旧账号余额")
    func reportsBalanceAndClearsOnAccountSwitch() async {
        let api = FakeAIBillingAPI()
        api.walletResults = [.success(AIWallet(balance: 10))]
        var userID: String? = "user-1"
        let store = AIPointsStore(api: api) { userID }

        await store.refresh()
        store.balanceReporter()(1)
        #expect(store.balance == 1)
        #expect(store.isExhausted)

        userID = "user-2"
        api.walletResults = [.failure(.network)]
        await store.refresh()
        #expect(store.balance == nil)
        #expect(!store.isExhausted)

        userID = nil
        store.balanceReporter()(5)
        #expect(store.balance == nil)
    }

    @Test("语音请求期间换了账号或退出登录，带回的余额丢弃")
    func dropsBalanceReportedForPreviousAccount() async {
        let api = FakeAIBillingAPI()
        api.walletResults = [.success(AIWallet(balance: 80))]
        var userID: String? = "user-1"
        let store = AIPointsStore(api: api) { userID }

        let reportForUser1 = store.balanceReporter()
        userID = "user-2"
        await store.refresh()
        reportForUser1(3)
        #expect(store.balance == 80)

        let reportBeforeSignOut = store.balanceReporter()
        userID = nil
        await store.refresh()
        reportBeforeSignOut(3)
        #expect(store.balance == nil)
    }

    @Test("刷新进行中换了账号：新账号另起一次请求，旧账号结果丢弃；退出登录立即清空")
    func refreshInFlightDoesNotLeakAcrossAccounts() async {
        let api = FakeAIBillingAPI()
        let gate = AsyncSaveGate()
        api.walletGate = gate
        api.walletResults = [.success(AIWallet(balance: 100)), .success(AIWallet(balance: 7))]
        var userID: String? = "user-1"
        let store = AIPointsStore(api: api) { userID }

        let user1Refresh = Task { await store.refresh() }
        while !gate.hasStarted {
            await Task.yield()
        }
        // 第一个账号的查询已挂起；去掉闸门，新账号的查询直接返回
        api.walletGate = nil

        userID = "user-2"
        await store.refresh()
        #expect(api.walletCalls == 2)
        #expect(store.balance == 7)

        gate.resume()
        await user1Refresh.value
        #expect(store.balance == 7)

        userID = nil
        await store.refresh()
        #expect(store.balance == nil)
    }

    @Test("刷新进行中语音回报了更新的余额，晚到的刷新不再覆盖余额和批次")
    func staleRefreshDoesNotOverwriteReportedBalance() async {
        let soon = Date(timeIntervalSince1970: 1_800_930_720)
        let later = soon.addingTimeInterval(86_400)
        let lots = [AICreditLot(points: 3, expiresAt: soon), AICreditLot(points: 10, expiresAt: later)]
        let api = FakeAIBillingAPI()
        api.walletResults = [.success(AIWallet(balance: 13, lots: lots))]
        let store = AIPointsStore(api: api) { "user-1" }
        await store.refresh()

        let gate = AsyncSaveGate()
        api.walletGate = gate
        api.walletResults.append(.success(AIWallet(balance: 13, lots: lots)))
        let refresh = Task { await store.refresh() }
        while !gate.hasStarted {
            await Task.yield()
        }

        store.balanceReporter()(11)
        #expect(store.balance == 11)
        let deducted = [AICreditLot(points: 1, expiresAt: soon), AICreditLot(points: 10, expiresAt: later)]
        #expect(store.lots == deducted)

        gate.resume()
        await refresh.value
        #expect(store.balance == 11)
        #expect(store.lots == deducted)
        #expect(store.failure == nil)
    }

    @Test("语音请求期间完成的刷新读的是扣点前的余额，语音回报随后回来时照常覆盖")
    func reportAfterRefreshDuringRequestOverwritesRefresh() async {
        let api = FakeAIBillingAPI()
        api.walletResults = [.success(AIWallet(balance: 40))]
        let store = AIPointsStore(api: api) { "user-1" }

        let report = store.balanceReporter()
        await store.refresh()
        #expect(store.balance == 40)
        report(38)
        #expect(store.balance == 38)

        // 回报之后才发起的刷新仍可覆盖
        api.walletResults = [.success(AIWallet(balance: 30))]
        await store.refresh()
        #expect(store.balance == 30)
    }

    @Test("不知道每轮点数时按 1 点判断是否用完")
    func exhaustedFallsBackToOnePoint() {
        let api = FakeAIBillingAPI()
        let store = AIPointsStore(api: api) { "user-1" }

        store.balanceReporter()(1)
        #expect(!store.isExhausted)
        store.balanceReporter()(0)
        #expect(store.isExhausted)
    }

    @Test("最近过期的一批：扣点先扣最早过期的批次，已到期的批次不算")
    func tracksNextExpiringLot() async {
        let soon = Date(timeIntervalSince1970: 1_800_930_720)
        let later = soon.addingTimeInterval(86_400 * 30)
        let api = FakeAIBillingAPI()
        api.walletResults = [.success(AIWallet(
            balance: 13,
            lots: [AICreditLot(points: 3, expiresAt: soon), AICreditLot(points: 10, expiresAt: later)]
        ))]
        let store = AIPointsStore(api: api) { "user-1" }
        let now = soon.addingTimeInterval(-86_400)

        await store.refresh()
        #expect(store.nextExpiringLot(now: now) == AICreditLot(points: 3, expiresAt: soon))

        store.balanceReporter()(11)
        #expect(store.lots == [AICreditLot(points: 1, expiresAt: soon), AICreditLot(points: 10, expiresAt: later)])

        store.balanceReporter()(9)
        #expect(store.nextExpiringLot(now: now) == AICreditLot(points: 9, expiresAt: later))
        #expect(store.nextExpiringLot(now: later) == nil)

        store.balanceReporter()(0)
        #expect(store.nextExpiringLot(now: now) == nil)
    }

    @Test("同时发起的刷新共用一次请求")
    func concurrentRefreshesShareOneRequest() async {
        let api = FakeAIBillingAPI()
        let gate = AsyncSaveGate()
        api.walletGate = gate
        api.walletResults = [.success(AIWallet(balance: 100))]
        let store = AIPointsStore(api: api) { "user-1" }

        let first = Task { await store.refresh() }
        while !gate.hasStarted {
            await Task.yield()
        }
        // 第一次查询已挂起；去掉闸门，第二次若真的再发请求只会让断言失败，不会卡住用例
        api.walletGate = nil
        #expect(store.isRefreshing)

        let second = Task { await store.refresh() }
        for _ in 0..<5 {
            await Task.yield()
        }
        gate.resume()
        await first.value
        await second.value

        #expect(api.walletCalls == 1)
        #expect(store.balance == 100)
        #expect(!store.isRefreshing)
    }

    // MARK: - 流水分页

    @Test("流水分页：第一页替换，下一页追加并按 ID 去重，最后一页后不再加载")
    func feedPaginates() async {
        let api = FakeAIBillingAPI()
        api.entryPages = [
            nil: .success(AICreditEntryPage(entries: [Self.entry(id: "5"), Self.entry(id: "4")], nextCursor: "4")),
            "4": .success(AICreditEntryPage(entries: [Self.entry(id: "4"), Self.entry(id: "3")], nextCursor: nil)),
        ]
        let feed = AICreditEntryFeed(api: api)
        #expect(!feed.hasMore)

        await feed.reload()
        #expect(feed.entries.map(\.id) == ["5", "4"])
        #expect(feed.hasLoaded)
        #expect(feed.hasMore)

        await feed.loadMore()
        #expect(feed.entries.map(\.id) == ["5", "4", "3"])
        #expect(!feed.hasMore)

        await feed.loadMore()
        #expect(api.requestedCursors == [nil, "4"])

        await feed.reload()
        #expect(feed.entries.map(\.id) == ["5", "4"])
    }

    @Test("流水加载失败：第一页失败可重试，下一页失败后不自动加载、重试时接着加载")
    func feedRetriesAfterFailure() async {
        let api = FakeAIBillingAPI()
        api.entryPages = [nil: .failure(.network)]
        let feed = AICreditEntryFeed(api: api)

        await feed.reload()
        #expect(feed.failure == .network)
        #expect(!feed.hasLoaded)

        api.entryPages = [
            nil: .success(AICreditEntryPage(entries: [Self.entry(id: "2")], nextCursor: "2")),
            "2": .failure(.timeout),
        ]
        await feed.retry()
        #expect(feed.entries.map(\.id) == ["2"])
        #expect(feed.failure == nil)

        await feed.loadMore()
        #expect(feed.failure == .timeout)
        await feed.loadMore()
        #expect(api.requestedCursors == [nil, nil, "2"])

        api.entryPages["2"] = .success(AICreditEntryPage(entries: [Self.entry(id: "1")], nextCursor: nil))
        await feed.retry()
        #expect(feed.entries.map(\.id) == ["2", "1"])
        #expect(feed.failure == nil)
        #expect(!feed.hasMore)
    }

    @Test("下拉刷新失败后重试：重新加载第一页，不去拉下一页")
    func feedRetryAfterRefreshFailureReloadsFirstPage() async {
        let api = FakeAIBillingAPI()
        api.entryPages = [
            nil: .success(AICreditEntryPage(entries: [Self.entry(id: "5")], nextCursor: "5")),
            "5": .success(AICreditEntryPage(entries: [Self.entry(id: "4")], nextCursor: nil)),
        ]
        let feed = AICreditEntryFeed(api: api)
        await feed.reload()

        api.entryPages[nil] = .failure(.timeout)
        await feed.reload()
        #expect(feed.failure == .timeout)
        #expect(feed.entries.map(\.id) == ["5"])

        api.entryPages[nil] = .success(AICreditEntryPage(entries: [Self.entry(id: "6"), Self.entry(id: "5")], nextCursor: "5"))
        await feed.retry()
        #expect(feed.failure == nil)
        #expect(feed.entries.map(\.id) == ["6", "5"])
        #expect(api.requestedCursors == [nil, nil, nil])
    }

    @Test("流水第一页为空时已加载且没有更多")
    func feedHandlesEmptyHistory() async {
        let api = FakeAIBillingAPI()
        api.entryPages = [nil: .success(AICreditEntryPage(entries: [], nextCursor: nil))]
        let feed = AICreditEntryFeed(api: api)

        await feed.reload()
        #expect(feed.hasLoaded)
        #expect(feed.entries.isEmpty)
        #expect(!feed.hasMore)
    }

    // MARK: - 辅助

    /// 构造一条流水。
    private static func entry(
        id: String = "1",
        kind: AICreditEntryKind = .charge,
        points: Int = -2,
        feature: String? = nil,
        reason: String? = nil
    ) -> AICreditEntry {
        AICreditEntry(
            id: id,
            kind: kind,
            points: points,
            balanceAfter: 0,
            feature: feature,
            reason: reason,
            createdAt: Date(timeIntervalSince1970: 1_793_154_720)
        )
    }
}

/// 按预设结果返回的点数查询接口，并记录调用次数。
@MainActor
private final class FakeAIBillingAPI: AIBillingFetching {
    /// 依次返回的余额结果；用完后重复最后一个。
    var walletResults: [Result<AIWallet, AIBillingAPIError>] = [.success(AIWallet(balance: 0))]

    /// 按游标返回的流水结果；游标为 nil 表示第一页。
    var entryPages: [String?: Result<AICreditEntryPage, AIBillingAPIError>] = [:]

    /// 模型列表结果；默认模型每轮 2 点。
    var modelsResult: Result<AIModelList, AIBillingAPIError> = .success(
        AIModelList(defaults: .init(text: "qwen3.8-27b"), models: [.init(id: "qwen3.8-27b", pointsPerTurn: 2)])
    )

    /// 设置后查询余额时先挂起，直到用例恢复。
    var walletGate: AsyncSaveGate?

    /// 查询余额的次数。
    private(set) var walletCalls = 0

    /// 查询模型列表的次数。
    private(set) var modelCalls = 0

    /// 依次请求过的流水游标。
    private(set) var requestedCursors: [String?] = []

    func fetchWallet() async throws -> AIWallet {
        let index = min(walletCalls, walletResults.count - 1)
        walletCalls += 1
        if let walletGate {
            await walletGate.wait()
        }
        return try walletResults[index].get()
    }

    func fetchEntries(cursor: String?) async throws -> AICreditEntryPage {
        requestedCursors.append(cursor)
        guard let result = entryPages[cursor] else { throw AIBillingAPIError.invalidContract }
        return try result.get()
    }

    func fetchModels() async throws -> AIModelList {
        modelCalls += 1
        return try modelsResult.get()
    }
}
