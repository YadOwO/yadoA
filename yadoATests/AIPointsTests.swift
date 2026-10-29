import Foundation
import Testing
@testable import yadoA

/// 验证 AI 点数：契约解码、明细展示映射、查询请求构造、余额状态与流水分页。
@Suite("AI 点数")
@MainActor
struct AIPointsTests {
    // MARK: - 契约

    @Test("余额、流水与档位列表解码：时间带毫秒，过期流水可识别，未知流水类型兜底，不认识或不可用的档位不让选")
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
           "reason":"initial_grant","product":"yadoa","createdAt":"2026-10-27T09:10:00Z"},
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
        #expect(page.entries[1].product == "yadoa")
        #expect(page.entries[0].product == nil)
        #expect(page.entries[1].createdAt == Date(timeIntervalSince1970: 1_793_092_200))

        let lastPage = try JSONDecoder().decode(
            AICreditEntryPage.self,
            from: Data(#"{"entries":[],"nextCursor":null}"#.utf8)
        )
        #expect(lastPage.entries.isEmpty)
        #expect(lastPage.nextCursor == nil)

        let tiersJSON = """
        {"defaultTier":"standard","tiers":[
          {"id":"standard","isAvailable":true,"pointsPerTurn":1},
          {"id":"precise","isAvailable":true,"pointsPerTurn":2},
          {"id":"turbo","isAvailable":true,"pointsPerTurn":5}
        ]}
        """
        let tierList = try JSONDecoder().decode(AIModelTierList.self, from: Data(tiersJSON.utf8))
        #expect(tierList.defaultTier == "standard")
        #expect(tierList.selectableTiers == [.standard, .precise])
        #expect(tierList.pointsPerTurn(for: "precise") == 2)
        #expect(tierList.pointsPerTurn(for: "gone") == nil)

        let preciseUnavailable = AIModelTierList(defaultTier: "standard", tiers: [
            .init(id: "standard", pointsPerTurn: 1, isAvailable: true),
            .init(id: "precise", pointsPerTurn: 2, isAvailable: false),
        ])
        #expect(preciseUnavailable.selectableTiers == [.standard])
    }

    @Test("流水时间不是 ISO 8601 时整页解码失败")
    func rejectsMalformedTimestamp() {
        let json = #"{"entries":[{"id":"1","kind":"grant","points":1,"balanceAfter":1,"createdAt":"yesterday"}],"nextCursor":null}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AICreditEntryPage.self, from: Data(json.utf8))
        }
    }

    @Test("明细标题与图标：扣点按能力、赠送按原因区分，新用户赠送带来源产品名，不认识的用类型兜底")
    func mapsEntryPresentation() {
        let voice = Self.entry(kind: .charge, points: -2, feature: AICreditEntry.voiceSessionFeature)
        let otherCharge = Self.entry(kind: .charge, points: -1, feature: "yadoi.item_extract")
        let welcome = Self.entry(kind: .grant, points: 100, reason: AICreditEntry.initialGrantReason, product: "yadoa")
        let welcomeWithoutProduct = Self.entry(kind: .grant, points: 100, reason: AICreditEntry.initialGrantReason)
        let welcomeFromUnknownProduct = Self.entry(
            kind: .grant,
            points: 100,
            reason: AICreditEntry.initialGrantReason,
            product: "yadox"
        )
        let compensation = Self.entry(kind: .grant, points: 50, reason: "compensation", product: "yadoa")

        #expect(voice.titleKey == "ai.entry.voiceSession")
        #expect(voice.symbol == "mic")
        #expect(otherCharge.titleKey == "ai.entry.charge")
        #expect(otherCharge.symbol == "sparkles")
        #expect(welcome.titleKey == "ai.entry.grant.initial.product")
        #expect(welcomeWithoutProduct.titleKey == "ai.entry.grant.initial")
        #expect(welcomeFromUnknownProduct.titleKey == "ai.entry.grant.initial")
        #expect(compensation.titleKey == "ai.entry.grant")
        #expect(Self.entry(kind: .refund, points: 2).titleKey == "ai.entry.refund")
        #expect(Self.entry(kind: .adjust, points: -20).titleKey == "ai.entry.adjust")
        #expect(Self.entry(kind: .expire, points: -5, reason: "expired").titleKey == "ai.entry.expire")
        #expect(Self.entry(kind: .expire, points: -5).symbol == "hourglass")
        #expect(Self.entry(kind: .unknown, points: 1).titleKey == "ai.entry.other")

        let simplifiedChinese = Locale(identifier: "zh-Hans")
        #expect(welcome.title(locale: simplifiedChinese) == "芽豆资产新用户赠送")
        #expect(welcome.title(locale: Locale(identifier: "en")) == "Yado Asset welcome bonus")
        #expect(welcomeWithoutProduct.title(locale: simplifiedChinese) == "新用户赠送")
        #expect(welcomeFromUnknownProduct.title(locale: simplifiedChinese) == "新用户赠送")
        #expect(voice.title(locale: simplifiedChinese) == "语音记账")

        let english = Locale(identifier: "en_US")
        #expect(welcome.signedPoints(locale: english) == "+100")
        #expect(voice.signedPoints(locale: english) == "-2")
    }

    @Test("批次解码：带来源、入账点数与获得时间；存量批次没有来源；服务端没返回这些字段时为空")
    func decodesCreditLots() throws {
        let walletJSON = """
        {"mode":"enforce","balance":101,"lots":[
          {"points":92,"originalPoints":100,"kind":"grant","reason":"initial_grant","product":"yadoa",
           "createdAt":"2026-10-28T02:32:00.000Z","expiresAt":"2027-01-26T02:32:00.000Z"},
          {"points":4,"originalPoints":4,"kind":null,"reason":null,"product":null,
           "createdAt":"2026-10-27T09:10:00Z","expiresAt":"2027-01-27T00:00:00Z"},
          {"points":5,"expiresAt":"2027-02-01T00:00:00Z"}
        ],"ruleVersion":"2026-10-29.1"}
        """
        let lots = try JSONDecoder().decode(AIWallet.self, from: Data(walletJSON.utf8)).lots
        #expect(lots.count == 3)
        #expect(lots[0].originalPoints == 100)
        #expect(lots[0].kind == .grant)
        #expect(lots[0].reason == AICreditEntry.initialGrantReason)
        #expect(lots[0].product == "yadoa")
        #expect(lots[0].createdAt == Date(timeIntervalSince1970: 1_793_154_720))
        #expect(lots[0].expiresAt == Date(timeIntervalSince1970: 1_800_930_720))
        #expect(lots[1].kind == nil)
        #expect(lots[1].createdAt == Date(timeIntervalSince1970: 1_793_092_200))
        #expect(lots[2] == AICreditLot(points: 5, expiresAt: Date(timeIntervalSince1970: 1_801_440_000)))

        let badTime = #"{"balance":1,"lots":[{"points":1,"createdAt":"昨天","expiresAt":"2027-02-01T00:00:00Z"}]}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AIWallet.self, from: Data(badTime.utf8))
        }
    }

    @Test("批次标题与图标和生成它的入账流水一致，存量批次显示早期点数")
    func mapsLotPresentation() {
        let expiresAt = Date(timeIntervalSince1970: 1_800_930_720)
        let welcome = AICreditLot(
            points: 92,
            expiresAt: expiresAt,
            kind: .grant,
            reason: AICreditEntry.initialGrantReason,
            product: "yadoa"
        )
        let refund = AICreditLot(points: 2, expiresAt: expiresAt, kind: .refund, reason: "compensation")
        let legacy = AICreditLot(points: 4, expiresAt: expiresAt)

        #expect(welcome.titleKey == "ai.entry.grant.initial.product")
        #expect(welcome.symbol == "gift")
        #expect(refund.titleKey == "ai.entry.refund")
        #expect(refund.symbol == "arrow.uturn.backward")
        #expect(legacy.titleKey == AICreditLot.legacyTitleKey)
        #expect(legacy.symbol == "tray")

        let simplifiedChinese = Locale(identifier: "zh-Hans")
        #expect(welcome.title(locale: simplifiedChinese) == "芽豆资产新用户赠送")
        #expect(legacy.title(locale: simplifiedChinese) == "早期点数")
        #expect(legacy.title(locale: Locale(identifier: "en")) == "Earlier points")
    }

    @Test("点数文案有中英文")
    func localizesPointsCopy() {
        let english = Locale(identifier: "en")
        let simplifiedChinese = Locale(identifier: "zh-Hans")
        #expect(AccountLocalization.string("ai.points.title", locale: english) == "AI Points")
        #expect(AccountLocalization.string("ai.points.title", locale: simplifiedChinese) == "AI 点数")
        #expect(AccountLocalization.formatted("ai.rules.perTurn", value: "2", locale: simplifiedChinese) == "语音记账每说一句扣 2 点")
        #expect(AccountLocalization.string("ai.points.exhausted", locale: simplifiedChinese) == "点数已用完，暂时无法使用 AI 记账。")
        #expect(AccountLocalization.string("ai.points.switchTier", locale: simplifiedChinese) == "余额不够当前模型每句扣的点数，切换到扣点更少的模型可继续使用。")
        let expiry = AccountLocalization.string("ai.points.expiry", locale: simplifiedChinese)
        #expect(String(format: expiry, locale: simplifiedChinese, "98", "2027年1月26日") == "98 点将于 2027年1月26日 过期")
        #expect(AccountLocalization.string("ai.entry.expire", locale: english) == "Expired")
        #expect(AccountLocalization.string("ai.lots.title", locale: simplifiedChinese) == "到期明细")
        #expect(AccountLocalization.string("ai.lots.title", locale: english) == "Expiry Details")
        #expect(AccountLocalization.formatted("ai.lots.expiresOn", value: "2027年1月26日", locale: simplifiedChinese) == "2027年1月26日 过期")
        #expect(AccountLocalization.formatted("ai.lots.receivedOn", value: "Oct 28, 2026", locale: english) == "Received Oct 28, 2026")
        #expect(AccountLocalization.formatted("ai.lots.original", value: "100", locale: simplifiedChinese) == "共 100 点")
        #expect(AccountLocalization.formatted("ai.tier.perTurn", value: "2", locale: simplifiedChinese) == "每句 2 点")
        #expect(AccountLocalization.formatted("ai.tier.perTurn", value: "2", locale: english) == "2 pts per sentence")
    }

    @Test("模型选择页：每个档位都有名称、一句话特点和不重复的具体特点，且有中英文")
    func describesEveryModelTier() {
        let locales = [Locale(identifier: "en"), Locale(identifier: "zh-Hans")]
        for tier in AIModelTier.allCases {
            #expect(!tier.highlights.isEmpty, "\(tier) 缺少特点")
            #expect(Set(tier.highlights.map(\.id)).count == tier.highlights.count, "\(tier) 的特点重复")

            let keys = [tier.titleKey, tier.summaryKey] + tier.highlights.map(\.textKey)
            for key in keys {
                for locale in locales {
                    // 缺文案时返回 key 本身
                    #expect(AccountLocalization.string(key, locale: locale) != key, "\(key) 缺少 \(locale.identifier) 文案")
                }
            }
        }
        #expect(AccountLocalization.string("ai.tier.standard.summary", locale: Locale(identifier: "zh-Hans")) == "均衡之选：速度快、扣点少，日常记账够用。")
    }

    // MARK: - 接口

    @Test("查询请求的路径、产品代号、分页参数与鉴权头")
    func buildsBillingRequests() throws {
        let endpoint = try #require(URL(string: "https://example.invalid"))
        let api = AIBillingAPI(endpoint: endpoint) { "token" }

        let wallet = api.makeURLRequest(.wallet, token: "abc")
        #expect(wallet.httpMethod == "GET")
        #expect(wallet.url?.absoluteString == "https://example.invalid/v1/billing/wallet?product=yadoa")
        #expect(wallet.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
        #expect(wallet.timeoutInterval == AIBillingAPI.requestTimeout)

        let firstPage = api.makeURLRequest(.entries(cursor: nil, limit: 20), token: "abc")
        #expect(firstPage.url?.path() == "/v1/billing/entries")
        #expect(firstPage.url?.query() == "product=yadoa&limit=20")

        let nextPage = api.makeURLRequest(.entries(cursor: "41", limit: 20), token: "abc")
        #expect(nextPage.url?.query() == "product=yadoa&limit=20&cursor=41")

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

    @Test("刷新取到余额与档位列表，没选过档位时按服务端默认档位算每轮点数，每次刷新都重新查档位列表")
    func refreshLoadsBalanceAndPointsPerTurn() async {
        let api = FakeAIBillingAPI()
        api.walletResults = [.success(AIWallet(balance: 100)), .success(AIWallet(balance: 98))]
        let store = AIPointsStore(api: api, defaults: .isolated()) { "user-1" }

        await store.refresh()
        #expect(store.balance == 100)
        #expect(store.requestTier == nil)
        #expect(store.displayTier == .standard)
        #expect(store.pointsPerTurn == 1)
        #expect(!store.isExhausted)

        await store.refresh()
        #expect(store.balance == 98)
        #expect(api.tierCalls == 2)
    }

    @Test("运行期间服务端停用所选档位：下次刷新后不再带档位；档位列表查询失败时沿用上次的")
    func refreshPicksUpTierAvailabilityChanges() async {
        let api = FakeAIBillingAPI()
        let store = AIPointsStore(api: api, defaults: .isolated()) { "user-1" }
        store.selectTier(.precise)
        await store.refresh()
        #expect(store.requestTier == .precise)

        let preciseDisabled = AIModelTierList(defaultTier: "standard", tiers: [
            .init(id: "standard", pointsPerTurn: 1, isAvailable: true),
            .init(id: "precise", pointsPerTurn: 2, isAvailable: false),
        ])
        api.tiersResult = .success(preciseDisabled)
        await store.refresh()
        #expect(store.requestTier == nil)
        #expect(store.pointsPerTurn == 1)

        api.tiersResult = .failure(.network)
        await store.refresh()
        #expect(store.tierList == preciseDisabled)
        #expect(store.requestTier == nil)
    }

    @Test("余额不够所用档位但够更便宜的档位时提示切换，连最便宜的档位都不够才算真正用完")
    func distinguishesSwitchTierFromExhausted() async {
        let api = FakeAIBillingAPI()
        api.walletResults = [.success(AIWallet(balance: 1))]
        let store = AIPointsStore(api: api, defaults: .isolated()) { "user-1" }
        await store.refresh()
        #expect(!store.isExhausted)
        #expect(!store.canAffordCheaperTier)

        store.selectTier(.precise)
        #expect(store.isExhausted)
        #expect(store.canAffordCheaperTier)

        store.balanceReporter()(0)
        #expect(store.isExhausted)
        #expect(!store.canAffordCheaperTier)
    }

    @Test("选档位：保存在本机，每轮点数随之变化，重新创建后仍记得")
    func selectsTierAndPersists() async {
        let api = FakeAIBillingAPI()
        api.walletResults = [.success(AIWallet(balance: 2))]
        let defaults = UserDefaults.isolated()
        let store = AIPointsStore(api: api, defaults: defaults) { "user-1" }
        await store.refresh()

        store.selectTier(.precise)
        #expect(store.requestTier == .precise)
        #expect(store.displayTier == .precise)
        #expect(store.pointsPerTurn == 2)

        store.balanceReporter()(1)
        #expect(store.isExhausted)

        let reopened = AIPointsStore(api: api, defaults: defaults) { "user-1" }
        #expect(reopened.selectedTier == .precise)
        // 还没取到档位列表时先按所选档位发送
        #expect(reopened.requestTier == .precise)
        #expect(reopened.pointsPerTurn == nil)
    }

    @Test("所选档位服务端已不可用时不带档位，按服务端默认档位显示与计点")
    func unavailableSelectedTierFallsBackToDefault() async {
        let api = FakeAIBillingAPI()
        api.tiersResult = .success(AIModelTierList(defaultTier: "standard", tiers: [
            .init(id: "standard", pointsPerTurn: 1, isAvailable: true),
            .init(id: "precise", pointsPerTurn: 2, isAvailable: false),
        ]))
        let store = AIPointsStore(api: api, defaults: .isolated()) { "user-1" }
        store.selectTier(.precise)

        await store.refresh()
        #expect(store.selectedTier == .precise)
        #expect(store.requestTier == nil)
        #expect(store.displayTier == .standard)
        #expect(store.pointsPerTurn == 1)
    }

    @Test("刷新失败保留已有余额，未登录时清空余额")
    func refreshFailureKeepsBalanceAndSignOutClears() async {
        let api = FakeAIBillingAPI()
        api.walletResults = [.success(AIWallet(balance: 50)), .failure(.timeout)]
        var userID: String? = "user-1"
        let store = AIPointsStore(api: api, defaults: .isolated()) { userID }

        await store.refresh()
        await store.refresh()
        #expect(store.balance == 50)
        #expect(store.failure == .timeout)

        userID = nil
        await store.refresh()
        #expect(store.balance == nil)
        #expect(store.failure == nil)
        #expect(store.pointsPerTurn == 1)
    }

    @Test("语音记账带回的余额就地更新；换账号后不展示旧账号余额")
    func reportsBalanceAndClearsOnAccountSwitch() async {
        let api = FakeAIBillingAPI()
        api.walletResults = [.success(AIWallet(balance: 10))]
        var userID: String? = "user-1"
        let store = AIPointsStore(api: api, defaults: .isolated()) { userID }

        await store.refresh()
        store.balanceReporter()(0)
        #expect(store.balance == 0)
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
        let store = AIPointsStore(api: api, defaults: .isolated()) { userID }

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
        let store = AIPointsStore(api: api, defaults: .isolated()) { userID }

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
        let store = AIPointsStore(api: api, defaults: .isolated()) { "user-1" }
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
        let store = AIPointsStore(api: api, defaults: .isolated()) { "user-1" }

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
        let store = AIPointsStore(api: api, defaults: .isolated()) { "user-1" }

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
        let store = AIPointsStore(api: api, defaults: .isolated()) { "user-1" }
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

    @Test("到期明细：只列有剩余且未到期的批次；语音扣点后批次保留来源与入账信息")
    func listsActiveLotsKeepingSource() async {
        let soon = Date(timeIntervalSince1970: 1_800_930_720)
        let later = soon.addingTimeInterval(86_400 * 30)
        let createdAt = soon.addingTimeInterval(-86_400 * 90)
        let welcome = AICreditLot(
            points: 3,
            expiresAt: soon,
            originalPoints: 100,
            kind: .grant,
            reason: AICreditEntry.initialGrantReason,
            product: "yadoa",
            createdAt: createdAt
        )
        let refund = AICreditLot(points: 10, expiresAt: later, originalPoints: 10, kind: .refund, createdAt: createdAt)
        let api = FakeAIBillingAPI()
        api.walletResults = [.success(AIWallet(balance: 13, lots: [welcome, refund]))]
        let store = AIPointsStore(api: api, defaults: .isolated()) { "user-1" }
        let now = soon.addingTimeInterval(-86_400)

        #expect(store.activeLots(now: now).isEmpty)
        await store.refresh()
        #expect(store.activeLots(now: now) == [welcome, refund])
        #expect(store.activeLots(now: soon) == [refund])

        store.balanceReporter()(11)
        let deducted = store.activeLots(now: now)
        #expect(deducted == [welcome.withPoints(1), refund])
        #expect(deducted.first?.originalPoints == 100)
        #expect(deducted.first?.kind == .grant)
        #expect(deducted.first?.product == "yadoa")
        #expect(deducted.first?.createdAt == createdAt)

        store.balanceReporter()(0)
        #expect(store.activeLots(now: now).isEmpty)
    }

    @Test("同时发起的刷新共用一次请求")
    func concurrentRefreshesShareOneRequest() async {
        let api = FakeAIBillingAPI()
        let gate = AsyncSaveGate()
        api.walletGate = gate
        api.walletResults = [.success(AIWallet(balance: 100))]
        let store = AIPointsStore(api: api, defaults: .isolated()) { "user-1" }

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
        reason: String? = nil,
        product: String? = nil
    ) -> AICreditEntry {
        AICreditEntry(
            id: id,
            kind: kind,
            points: points,
            balanceAfter: 0,
            feature: feature,
            reason: reason,
            product: product,
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

    /// 档位列表结果；默认普通档每轮 1 点，精准档每轮 2 点。
    var tiersResult: Result<AIModelTierList, AIBillingAPIError> = .success(AIModelTierList(defaultTier: "standard", tiers: [
        .init(id: "standard", pointsPerTurn: 1, isAvailable: true),
        .init(id: "precise", pointsPerTurn: 2, isAvailable: true),
    ]))

    /// 设置后查询余额时先挂起，直到用例恢复。
    var walletGate: AsyncSaveGate?

    /// 查询余额的次数。
    private(set) var walletCalls = 0

    /// 查询档位列表的次数。
    private(set) var tierCalls = 0

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

    func fetchModelTiers() async throws -> AIModelTierList {
        tierCalls += 1
        return try tiersResult.get()
    }
}

private extension UserDefaults {
    /// 每个用例独立的本机偏好，不读到模拟器里 App 保存的档位，用例之间也互不影响。
    ///
    /// - Returns: 空的偏好存储。
    static func isolated() -> UserDefaults {
        let suiteName = "AIPointsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("无法创建测试用的偏好存储")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
