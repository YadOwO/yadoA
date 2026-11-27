import Foundation
import Testing
@testable import yadoA

/// 验证数据联动：汇总契约、接口请求与错误码映射、估值计算与设置、联动状态，以及 `DataLinkStore` 的缓存、节流和换账号隔离。
///
/// 全程用假接口和独立的 UserDefaults，不发真实网络请求。金额都从字符串构造 `Decimal`，不用小数字面量，避免二进制小数带来误差。
@Suite("数据联动")
@MainActor
struct DataLinkTests {
    /// 汇总里最近一次物品更新时间 2026-11-23T10:00:00Z。
    private static let lastUpdatedAt = Date(timeIntervalSince1970: 1_795_428_000)

    /// hub 取到汇总的时刻 2026-11-24T08:00:00Z。
    private static let fetchedAt = Date(timeIntervalSince1970: 1_795_507_200)

    /// 芽豆有物已授权的联动列表。
    private static let grantedLinks = DataLinkList(links: [DataLinkStatus(granted: true, grantedAt: DataLinkTests.fetchedAt)])

    /// 芽豆有物没授权的联动列表。
    private static let notGrantedLinks = DataLinkList(links: [DataLinkStatus(granted: false)])

    // MARK: - 汇总契约

    @Test("汇总解码：金额从字符串转成 Decimal，时间带不带毫秒都行，lastItemUpdatedAt 可以为 null")
    func decodesSummary() throws {
        let json = """
        {"inServicePurchaseTotal":"1234.50","retiredPurchaseTotal":"300.00","pricedItemCount":12,"unpricedItemCount":2,
         "lastItemUpdatedAt":"2026-11-23T10:00:00Z","fetchedAt":"2026-11-24T08:00:00.000Z"}
        """
        let summary = try JSONDecoder().decode(ItemValueSummary.self, from: Data(json.utf8))
        #expect(summary.inServicePurchaseTotal == Self.decimal("1234.50"))
        #expect(summary.retiredPurchaseTotal == Self.decimal("300.00"))
        #expect(summary.pricedItemCount == 12)
        #expect(summary.unpricedItemCount == 2)
        #expect(summary.lastItemUpdatedAt == Self.lastUpdatedAt)
        #expect(summary.fetchedAt == Self.fetchedAt)

        let empty = """
        {"inServicePurchaseTotal":"0.00","retiredPurchaseTotal":"0.00","pricedItemCount":0,"unpricedItemCount":0,
         "lastItemUpdatedAt":null,"fetchedAt":"2026-11-24T08:00:00.000Z"}
        """
        let zero = try JSONDecoder().decode(ItemValueSummary.self, from: Data(empty.utf8))
        #expect(zero.inServicePurchaseTotal == 0)
        #expect(zero.retiredPurchaseTotal == 0)
        #expect(zero.pricedItemCount == 0)
        #expect(zero.unpricedItemCount == 0)
        #expect(zero.lastItemUpdatedAt == nil)
    }

    @Test("汇总解码：金额写成 number、金额不是数字或时间格式不对都按契约错误整个失败")
    func rejectsMalformedSummary() {
        let numberTotal = """
        {"inServicePurchaseTotal":1234.5,"retiredPurchaseTotal":"0.00","pricedItemCount":1,"unpricedItemCount":0,
         "lastItemUpdatedAt":null,"fetchedAt":"2026-11-24T08:00:00.000Z"}
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ItemValueSummary.self, from: Data(numberTotal.utf8))
        }

        let notMoney = """
        {"inServicePurchaseTotal":"abc","retiredPurchaseTotal":"0.00","pricedItemCount":1,"unpricedItemCount":0,
         "lastItemUpdatedAt":null,"fetchedAt":"2026-11-24T08:00:00.000Z"}
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ItemValueSummary.self, from: Data(notMoney.utf8))
        }

        let badTime = """
        {"inServicePurchaseTotal":"1.00","retiredPurchaseTotal":"0.00","pricedItemCount":1,"unpricedItemCount":0,
         "lastItemUpdatedAt":null,"fetchedAt":"yesterday"}
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ItemValueSummary.self, from: Data(badTime.utf8))
        }

        let missingField = #"{"inServicePurchaseTotal":"1.00","retiredPurchaseTotal":"0.00","pricedItemCount":1}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ItemValueSummary.self, from: Data(missingField.utf8))
        }
    }

    @Test("汇总编码再解码结果不变，金额和时间写成字符串，没有更新时间时不写这个字段")
    func summaryRoundTrips() throws {
        let summary = ItemValueSummary(
            inServicePurchaseTotal: Self.decimal("1234.56"),
            retiredPurchaseTotal: Self.decimal("100.01"),
            pricedItemCount: 7,
            unpricedItemCount: 3,
            lastItemUpdatedAt: Self.lastUpdatedAt,
            fetchedAt: Self.fetchedAt
        )
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(ItemValueSummary.self, from: data)
        #expect(decoded == summary)

        let json = try JSONSerialization.jsonObject(with: data)
        let object = try #require(json as? [String: Any])
        #expect(object["inServicePurchaseTotal"] is String)
        #expect(object["retiredPurchaseTotal"] is String)
        #expect(object["lastItemUpdatedAt"] is String)
        #expect(object["fetchedAt"] is String)
        #expect(object["pricedItemCount"] as? Int == 7)

        let noDate = Self.summary(lastUpdatedAt: nil)
        let noDateData = try JSONEncoder().encode(noDate)
        let noDateDecoded = try JSONDecoder().decode(ItemValueSummary.self, from: noDateData)
        #expect(noDateDecoded == noDate)
        let noDateJSON = try JSONSerialization.jsonObject(with: noDateData)
        let noDateObject = try #require(noDateJSON as? [String: Any])
        #expect(noDateObject["lastItemUpdatedAt"] == nil)
    }

    @Test("联动状态解码：授权时刻可以为 null，时间格式不对整项失败，代号常量与服务端一致")
    func decodesLinkStatus() throws {
        let json = """
        {"links":[
          {"source":"yadoi","target":"yadoa","scope":"item_value_summary","granted":true,"grantedAt":"2026-11-24T08:00:00.000Z"},
          {"source":"yadoi","target":"yadoa","scope":"item_value_summary","granted":false,"grantedAt":null}
        ]}
        """
        let list = try JSONDecoder().decode(DataLinkList.self, from: Data(json.utf8))
        #expect(list.links.count == 2)
        #expect(list.links[0].granted)
        #expect(list.links[0].grantedAt == Self.fetchedAt)
        #expect(!list.links[1].granted)
        #expect(list.links[1].grantedAt == nil)
        #expect(list.links[0].source == DataLinkCode.source)
        #expect(list.links[0].target == DataLinkCode.target)
        #expect(list.links[0].scope == DataLinkCode.scope)

        let empty = try JSONDecoder().decode(DataLinkList.self, from: Data(#"{"links":[]}"#.utf8))
        #expect(empty.links.isEmpty)

        let badTime = #"{"source":"yadoi","target":"yadoa","scope":"item_value_summary","granted":true,"grantedAt":"yesterday"}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DataLinkStatus.self, from: Data(badTime.utf8))
        }

        #expect(DataLinkCode.source == "yadoi")
        #expect(DataLinkCode.target == "yadoa")
        #expect(DataLinkCode.scope == "item_value_summary")
    }

    // MARK: - 接口

    @Test("接口的方法和路径")
    func routesMethodAndPath() {
        #expect(DataLinkAPI.Route.list.method == "GET")
        #expect(DataLinkAPI.Route.list.path == "v1/links")
        #expect(DataLinkAPI.Route.grant.method == "PUT")
        #expect(DataLinkAPI.Route.grant.path == "v1/links/yadoi/yadoa")
        #expect(DataLinkAPI.Route.revoke.method == "DELETE")
        #expect(DataLinkAPI.Route.revoke.path == "v1/links/yadoi/yadoa")
        #expect(DataLinkAPI.Route.itemValueSummary.method == "GET")
        #expect(DataLinkAPI.Route.itemValueSummary.path == "v1/links/yadoi/yadoa/item-value-summary")
    }

    @Test("请求构造：带 Bearer、Accept 和版本头，没有请求体，超时 15 秒")
    func buildsRequests() throws {
        let endpoint = try #require(URL(string: "https://example.invalid"))
        let api = DataLinkAPI(endpoint: endpoint) { "token" }

        let summary = api.makeURLRequest(.itemValueSummary, token: "abc")
        #expect(summary.httpMethod == "GET")
        #expect(summary.url?.absoluteString == "https://example.invalid/v1/links/yadoi/yadoa/item-value-summary")
        #expect(summary.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
        #expect(summary.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(summary.value(forHTTPHeaderField: AppVersion.headerName) == AppVersion.current)
        #expect(summary.httpBody == nil)
        #expect(summary.timeoutInterval == DataLinkAPI.requestTimeout)
        #expect(DataLinkAPI.requestTimeout == 15)

        let list = api.makeURLRequest(.list, token: "abc")
        #expect(list.httpMethod == "GET")
        #expect(list.url?.absoluteString == "https://example.invalid/v1/links")

        let grant = api.makeURLRequest(.grant, token: "abc")
        #expect(grant.httpMethod == "PUT")
        #expect(grant.url?.path() == "/v1/links/yadoi/yadoa")

        let revoke = api.makeURLRequest(.revoke, token: "abc")
        #expect(revoke.httpMethod == "DELETE")
        #expect(revoke.url?.path() == "/v1/links/yadoi/yadoa")
    }

    @Test("错误状态码映射：403 没授权，404 来源没开，502 上游失败，429 限流，401 未授权，426 要升级，其他 5xx 暂时不可用")
    func mapsErrorStatusCodes() {
        #expect(DataLinkAPI.error(statusCode: 403) == .notGranted)
        #expect(DataLinkAPI.error(statusCode: 404) == .unavailable)
        #expect(DataLinkAPI.error(statusCode: 502) == .upstreamFailed)
        #expect(DataLinkAPI.error(statusCode: 429) == .rateLimited)
        #expect(DataLinkAPI.error(statusCode: 401) == .unauthorized)
        #expect(DataLinkAPI.error(statusCode: 426) == .upgradeRequired)
        #expect(DataLinkAPI.error(statusCode: 500) == .serviceUnavailable)
        #expect(DataLinkAPI.error(statusCode: 503) == .serviceUnavailable)
        #expect(DataLinkAPI.error(statusCode: 400) == .invalidContract)
    }

    @Test("经会话发出请求：取汇总解码成功，授权和取消授权各发一个对应方法的请求")
    func performsRequestsThroughSession() async throws {
        let summaryBody = Data("""
        {"inServicePurchaseTotal":"1234.50","retiredPurchaseTotal":"300.00","pricedItemCount":12,"unpricedItemCount":2,
         "lastItemUpdatedAt":null,"fetchedAt":"2026-11-24T08:00:00.000Z"}
        """.utf8)
        let summaryEndpoint = StubURLProtocol.register(statusCode: 200, body: summaryBody)
        let summaryAPI = DataLinkAPI(endpoint: summaryEndpoint, session: StubURLProtocol.makeSession()) { "hub-token" }

        let summary = try await summaryAPI.fetchItemValueSummary()

        #expect(summary.inServicePurchaseTotal == Self.decimal("1234.50"))
        #expect(summary.pricedItemCount == 12)
        let summaryRequests = StubURLProtocol.recordedRequests(for: summaryEndpoint)
        #expect(summaryRequests.count == 1)
        #expect(summaryRequests.first?.httpMethod == "GET")
        #expect(summaryRequests.first?.url?.path() == "/v1/links/yadoi/yadoa/item-value-summary")
        #expect(summaryRequests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer hub-token")

        let grantedBody = Data(
            #"{"source":"yadoi","target":"yadoa","scope":"item_value_summary","granted":true,"grantedAt":"2026-11-24T08:00:00.000Z"}"#.utf8
        )
        let grantEndpoint = StubURLProtocol.register(statusCode: 200, body: grantedBody)
        let grantAPI = DataLinkAPI(endpoint: grantEndpoint, session: StubURLProtocol.makeSession()) { "t" }
        let granted = try await grantAPI.grantItemValue()
        #expect(granted.granted)
        #expect(StubURLProtocol.recordedRequests(for: grantEndpoint).first?.httpMethod == "PUT")

        let revokedBody = Data(
            #"{"source":"yadoi","target":"yadoa","scope":"item_value_summary","granted":false,"grantedAt":null}"#.utf8
        )
        let revokeEndpoint = StubURLProtocol.register(statusCode: 200, body: revokedBody)
        let revokeAPI = DataLinkAPI(endpoint: revokeEndpoint, session: StubURLProtocol.makeSession()) { "t" }
        let revoked = try await revokeAPI.revokeItemValue()
        #expect(!revoked.granted)
        #expect(StubURLProtocol.recordedRequests(for: revokeEndpoint).first?.httpMethod == "DELETE")
    }

    @Test("经会话发出请求：非 200 按状态码映射错误，200 但响应不合契约是契约错误")
    func mapsFailuresThroughSession() async {
        let cases: [(Int, DataLinkAPIError)] = [
            (403, .notGranted), (404, .unavailable), (502, .upstreamFailed), (429, .rateLimited), (401, .unauthorized)
        ]
        for (statusCode, expected) in cases {
            let body = Data(#"{"code":"X","message":"m"}"#.utf8)
            let endpoint = StubURLProtocol.register(statusCode: statusCode, body: body)
            let api = DataLinkAPI(endpoint: endpoint, session: StubURLProtocol.makeSession()) { "t" }
            await #expect(throws: expected) {
                _ = try await api.fetchItemValueSummary()
            }
        }

        let numberTotal = Data("""
        {"inServicePurchaseTotal":1234.5,"retiredPurchaseTotal":"0.00","pricedItemCount":1,"unpricedItemCount":0,
         "lastItemUpdatedAt":null,"fetchedAt":"2026-11-24T08:00:00.000Z"}
        """.utf8)
        let endpoint = StubURLProtocol.register(statusCode: 200, body: numberTotal)
        let api = DataLinkAPI(endpoint: endpoint, session: StubURLProtocol.makeSession()) { "t" }
        await #expect(throws: DataLinkAPIError.invalidContract) {
            _ = try await api.fetchItemValueSummary()
        }
    }

    @Test("拿不到 hub 的 token：按登录状态归类，不发请求")
    func mapsTokenFailures() async {
        let endpoint = StubURLProtocol.register(statusCode: 200, body: Data(#"{"links":[]}"#.utf8))
        let signedOut = DataLinkAPI(endpoint: endpoint, session: StubURLProtocol.makeSession()) {
            throw ServiceAuthError.notSignedIn
        }
        await #expect(throws: DataLinkAPIError.notSignedIn) {
            _ = try await signedOut.fetchLinks()
        }

        let expired = DataLinkAPI(endpoint: endpoint, session: StubURLProtocol.makeSession()) {
            throw ServiceAuthError.sessionExpired
        }
        await #expect(throws: DataLinkAPIError.sessionExpired) {
            _ = try await expired.fetchLinks()
        }
        #expect(StubURLProtocol.recordedRequests(for: endpoint).isEmpty)
    }

    // MARK: - 估值计算

    @Test("估值：(1234.56 + 100.01) × 75% = 1000.9275，四舍五入到分是 1000.93")
    func valuationRoundsToCents() {
        let summary = Self.summary(inService: Self.decimal("1234.56"), retired: Self.decimal("100.01"))
        #expect(ItemValuation.amount(summary: summary, discountPercent: 75) == Self.decimal("1000.93"))
    }

    @Test("估值舍入到分的边界：半分进位，不到半分舍去，在用和退役一起算")
    func valuationRoundingBoundaries() {
        // 0.05 × 10% = 0.005，正好半分，进到 0.01
        let half = Self.summary(inService: Self.decimal("0.05"), retired: 0)
        #expect(ItemValuation.amount(summary: half, discountPercent: 10) == Self.decimal("0.01"))

        // 0.04 × 10% = 0.004，不到半分，舍成 0
        let below = Self.summary(inService: Self.decimal("0.04"), retired: 0)
        #expect(ItemValuation.amount(summary: below, discountPercent: 10) == 0)

        // 12.35 × 70% = 8.645，进到 8.65
        let seventy = Self.summary(inService: Self.decimal("12.35"), retired: 0)
        #expect(ItemValuation.amount(summary: seventy, discountPercent: 70) == Self.decimal("8.65"))

        // 在用 1000 + 退役 200，七折 840；100% 是原价；全 0 是 0
        let both = Self.summary(inService: 1000, retired: 200)
        #expect(ItemValuation.amount(summary: both, discountPercent: 70) == 840)
        #expect(ItemValuation.amount(summary: both, discountPercent: 100) == 1200)
        #expect(ItemValuation.amount(summary: Self.summary(inService: 0, retired: 0, priced: 0, unpriced: 0), discountPercent: 70) == 0)
    }

    @Test("折扣取值：夹进 10%～100%，并对齐到 5 的倍数")
    func clampsDiscount() {
        #expect(ItemValuationSettings.clampedDiscount(7) == 10)
        #expect(ItemValuationSettings.clampedDiscount(103) == 100)
        #expect(ItemValuationSettings.clampedDiscount(72) == 70)
        #expect(ItemValuationSettings.clampedDiscount(73) == 75)
        #expect(ItemValuationSettings.clampedDiscount(10) == 10)
        #expect(ItemValuationSettings.clampedDiscount(100) == 100)
        #expect(ItemValuationSettings.clampedDiscount(0) == 10)
        #expect(ItemValuationSettings.clampedDiscount(-5) == 10)
        #expect(ItemValuationSettings.discountRange == 10...100)
        #expect(ItemValuationSettings.discountStep == 5)
    }

    @Test("估值设置：默认全开七折，缺字段取默认值，读出来的折扣也会夹进范围，编码再解码不变")
    func settingsDefaultsAndCoding() throws {
        let defaults = ItemValuationSettings()
        #expect(defaults.showsOnAccounts)
        #expect(defaults.countsInNetWorth)
        #expect(defaults.discountPercent == 70)

        let empty = try JSONDecoder().decode(ItemValuationSettings.self, from: Data("{}".utf8))
        #expect(empty == defaults)

        let wild = #"{"showsOnAccounts":false,"countsInNetWorth":false,"discountPercent":999}"#
        let clamped = try JSONDecoder().decode(ItemValuationSettings.self, from: Data(wild.utf8))
        #expect(clamped == ItemValuationSettings(showsOnAccounts: false, countsInNetWorth: false, discountPercent: 100))

        let custom = ItemValuationSettings(showsOnAccounts: false, countsInNetWorth: true, discountPercent: 85)
        let roundTripped = try JSONDecoder().decode(ItemValuationSettings.self, from: JSONEncoder().encode(custom))
        #expect(roundTripped == custom)
    }

    @Test("折扣文案：中文写「7 折」「7.5 折」「原价」，英文写百分比")
    func discountText() {
        let chinese = Locale(identifier: "zh-Hans")
        #expect(ItemValuation.discountText(percent: 70, locale: chinese) == "7 折")
        #expect(ItemValuation.discountText(percent: 75, locale: chinese) == "7.5 折")
        #expect(ItemValuation.discountText(percent: 100, locale: chinese) == "原价")

        let english = Locale(identifier: "en")
        #expect(ItemValuation.discountText(percent: 70, locale: english) == "70%")
        #expect(ItemValuation.discountText(percent: 100, locale: english) == "100%")
    }

    // MARK: - 联动状态与账户页的一行

    @Test("联动状态：没授权、已联动、没有物品、物品都没填价格四种")
    func linkStates() {
        #expect(ItemValueLinkState.state(isGranted: false, summary: nil) == .notGranted)
        #expect(ItemValueLinkState.state(isGranted: false, summary: Self.summary()) == .notGranted)
        // 已授权但还没取到汇总：按已联动
        #expect(ItemValueLinkState.state(isGranted: true, summary: nil) == .linked)
        #expect(ItemValueLinkState.state(isGranted: true, summary: Self.summary(priced: 3, unpriced: 2)) == .linked)
        #expect(ItemValueLinkState.state(isGranted: true, summary: Self.summary(priced: 0, unpriced: 0)) == .linkedNoItems)
        #expect(ItemValueLinkState.state(isGranted: true, summary: Self.summary(priced: 0, unpriced: 4)) == .linkedNoPrices)
    }

    @Test("账户页那一行：名称、副标题、金额标签；有没填价格的物品才接上「另有」；不计入净资产时换标签")
    func presentationRow() {
        let chinese = Locale(identifier: "zh-Hans")
        let summary = Self.summary(inService: 1000, retired: 200, priced: 5, unpriced: 1)

        let row = ItemValuationPresentation.row(summary: summary, settings: ItemValuationSettings(), locale: chinese)
        #expect(row.id == ItemValuationPresentation.rowID)
        #expect(row.name == "物品估值")
        #expect(row.detail.contains("7 折"))
        #expect(row.detail.contains("· 5 件"))
        #expect(row.detail.contains("另有 1 件没填价格"))
        #expect(row.formattedAmount.contains("840"))
        #expect(row.amountLabel == "估值")
        #expect(row.amountTone == .neutral)
        #expect(!row.isDefault)
        #expect(row.icon.symbolName == "shippingbox.fill")
        #expect(row.icon.brandImageName == nil)

        let notCounted = ItemValuationPresentation.row(
            summary: summary,
            settings: ItemValuationSettings(countsInNetWorth: false),
            locale: chinese
        )
        #expect(notCounted.amountLabel == "不计入净资产")

        // 关掉「显示在账户页」时实际不计入，标签跟着变
        let hidden = ItemValuationPresentation.row(
            summary: summary,
            settings: ItemValuationSettings(showsOnAccounts: false, countsInNetWorth: true),
            locale: chinese
        )
        #expect(hidden.amountLabel == "不计入净资产")

        let allPriced = Self.summary(priced: 5, unpriced: 0)
        let noUnpriced = ItemValuationPresentation.row(summary: allPriced, settings: ItemValuationSettings(), locale: chinese)
        #expect(!noUnpriced.detail.contains("另有"))

        let english = ItemValuationPresentation.row(summary: summary, settings: ItemValuationSettings(), locale: Locale(identifier: "en"))
        #expect(english.name == "Item Valuation")
        #expect(english.detail.contains("70%"))
    }

    // MARK: - Store：入口与请求

    @Test("没登录或不允许联网时不发请求，也没有任何联动入口")
    func skipsRequestsWhenSignedOutOrOffline() async {
        let env = DataLinkEnvironment()
        env.api.linksResult = .success(Self.grantedLinks)
        let store = env.makeStore()

        env.isNetworkAllowed = false
        await store.refreshLinks()
        await store.refreshItemValueIfStale()
        #expect(env.api.fetchLinksCalls == 0)
        #expect(env.api.summaryCalls == 0)
        #expect(store.links == nil)
        #expect(!store.isItemValueLinkAvailable)

        env.isNetworkAllowed = true
        env.userID = nil
        await store.refreshLinks()
        await store.refreshItemValueIfStale()
        #expect(env.api.fetchLinksCalls == 0)
        #expect(env.api.summaryCalls == 0)
        #expect(!store.isItemValueLinkAvailable)
        #expect(!store.isItemValueGranted)
    }

    @Test("联动列表里没有芽豆有物时不可用；有但没授权时可用、不取汇总")
    func availabilityFollowsLinks() async {
        let env = DataLinkEnvironment()
        let store = env.makeStore()

        // 还没拉到列表
        #expect(!store.isItemValueLinkAvailable)

        // 服务端没打开任何来源
        env.api.linksResult = .success(DataLinkList(links: []))
        await store.refreshLinks()
        #expect(store.links == [])
        #expect(!store.isItemValueLinkAvailable)
        #expect(store.accountValuation == nil)

        // 列表里只有别的来源
        env.api.linksResult = .success(DataLinkList(links: [DataLinkStatus(source: "other", granted: true)]))
        await store.refreshLinks()
        #expect(!store.isItemValueLinkAvailable)
        #expect(!store.isItemValueGranted)

        // 有芽豆有物但没授权
        env.api.linksResult = .success(Self.notGrantedLinks)
        await store.refreshLinks()
        #expect(store.isItemValueLinkAvailable)
        #expect(!store.isItemValueGranted)
        #expect(store.linkState == .notGranted)
        await store.refreshItemValueIfStale()
        #expect(env.api.summaryCalls == 0)

        // 已授权
        env.api.linksResult = .success(Self.grantedLinks)
        await store.refreshLinks()
        #expect(store.isItemValueGranted)

        // 隐私离线模式（不允许联网）下不显示
        env.isNetworkAllowed = false
        #expect(!store.isItemValueLinkAvailable)
        #expect(store.accountValuation == nil)
    }

    @Test("联动列表刷新失败时保留原值；刷新后没授权会清掉汇总缓存")
    func linksRefreshKeepsOrClears() async {
        let env = DataLinkEnvironment()
        env.api.linksResult = .success(Self.grantedLinks)
        env.api.summaryResult = .success(Self.summary())
        let store = env.makeStore()
        await store.refreshLinks()
        await store.refreshItemValueIfStale()
        #expect(store.cachedSummary != nil)

        env.api.linksResult = .failure(.network)
        await store.refreshLinks()
        #expect(store.isItemValueGranted)
        #expect(store.cachedSummary != nil)

        env.api.linksResult = .success(Self.notGrantedLinks)
        await store.refreshLinks()
        #expect(!store.isItemValueGranted)
        #expect(store.cachedSummary == nil)
        #expect(env.defaults.data(forKey: DataLinkStore.summaryKey(userID: "user-1")) == nil)
    }

    @Test("授权过的账号重新打开 App：还没问到 hub、断网或 hub 出错时照样用缓存显示；隐私离线模式下不显示")
    func showsCachedValuationBeforeHubConfirms() async {
        let env = DataLinkEnvironment()
        env.api.linksResult = .success(Self.grantedLinks)
        env.api.summaryResult = .success(Self.summary())
        let first = env.makeStore()
        await first.refreshLinks()
        await first.refreshItemValueIfStale()
        #expect(first.accountValuation == 840)

        // 重新打开 App：新的 store，还没问过 hub
        let relaunched = env.makeStore()
        #expect(relaunched.links == nil)
        #expect(relaunched.isItemValueLinkAvailable)
        #expect(relaunched.isItemValueGranted)
        #expect(relaunched.accountValuation == 840)
        #expect(relaunched.showsAccountRow)
        #expect(relaunched.netWorthValuation == 840)

        // 断网：列表拉不到，照样显示
        env.api.linksResult = .failure(.network)
        await relaunched.refreshLinks()
        #expect(relaunched.links == nil)
        #expect(relaunched.isItemValueGranted)
        #expect(relaunched.accountValuation == 840)

        // hub 或芽豆有物服务出错：汇总拉不到，保留缓存并记下原因
        env.now += 301
        env.api.summaryResult = .failure(.upstreamFailed)
        await relaunched.refreshItemValueIfStale()
        #expect(env.api.summaryCalls == 2)
        #expect(relaunched.lastSummaryFailure == .upstreamFailed)
        #expect(relaunched.accountValuation == 840)

        // 只靠缓存判定已授权时，拉到新的汇总照样写进缓存
        let newer = Self.summary(inService: 2000)
        env.api.summaryResult = .success(newer)
        await relaunched.refreshItemValueIfStale(force: true)
        #expect(relaunched.cachedSummary == newer)
        #expect(relaunched.lastSummaryFailure == nil)

        // 隐私离线模式下照旧什么都不显示
        env.isNetworkAllowed = false
        #expect(!relaunched.isItemValueLinkAvailable)
        #expect(!relaunched.isItemValueGranted)
        #expect(relaunched.accountValuation == nil)
    }

    @Test("授权过的账号重新打开 App：hub 说没授权、来源没开时隐藏并清缓存")
    func cachedValuationHiddenOnceHubSaysNo() async {
        let env = DataLinkEnvironment()
        env.api.linksResult = .success(Self.grantedLinks)
        env.api.summaryResult = .success(Self.summary())
        let first = env.makeStore()
        await first.refreshLinks()
        await first.refreshItemValueIfStale()

        // 列表显示没授权（例如在另一台设备上取消了）
        let relaunched = env.makeStore()
        #expect(relaunched.isItemValueGranted)
        env.api.linksResult = .success(Self.notGrantedLinks)
        await relaunched.refreshLinks()
        #expect(relaunched.isItemValueLinkAvailable)
        #expect(!relaunched.isItemValueGranted)
        #expect(relaunched.cachedSummary == nil)

        // 重新授权后再打开 App：列表拉不到，汇总接口说没授权
        env.api.grantResult = .success(DataLinkStatus(granted: true, grantedAt: Self.fetchedAt))
        _ = await relaunched.grant()
        #expect(relaunched.cachedSummary != nil)
        let second = env.makeStore()
        env.api.linksResult = .failure(.network)
        await second.refreshLinks()
        #expect(second.isItemValueGranted)
        env.now += 301
        env.api.summaryResult = .failure(.notGranted)
        await second.refreshItemValueIfStale()
        #expect(!second.isItemValueGranted)
        #expect(!second.isItemValueLinkAvailable)
        #expect(second.cachedSummary == nil)

        // 再授权一次，然后 hub 关掉了这个来源
        env.api.linksResult = .success(Self.grantedLinks)
        env.api.summaryResult = .success(Self.summary())
        await second.refreshLinks()
        await second.refreshItemValueIfStale()
        #expect(second.cachedSummary != nil)
        let third = env.makeStore()
        env.api.linksResult = .success(DataLinkList(links: []))
        await third.refreshLinks()
        #expect(!third.isItemValueLinkAvailable)
        #expect(!third.isItemValueGranted)
        #expect(third.cachedSummary == nil)
    }

    // MARK: - Store：缓存与节流

    @Test("5 分钟内不重复拉，force 会拉，过了 5 分钟再拉；本机时间往回调过时按过期处理")
    func throttlesSummaryRefresh() async {
        let env = DataLinkEnvironment()
        env.api.linksResult = .success(Self.grantedLinks)
        env.api.summaryResult = .success(Self.summary())
        let store = env.makeStore()
        await store.refreshLinks()

        await store.refreshItemValueIfStale()
        #expect(env.api.summaryCalls == 1)
        #expect(store.cachedSummary == Self.summary())

        env.now += 4 * 60 + 59
        await store.refreshItemValueIfStale()
        #expect(env.api.summaryCalls == 1)

        await store.refreshItemValueIfStale(force: true)
        #expect(env.api.summaryCalls == 2)

        // force 重新记了保存时刻，从这时起再过 5 分钟才算过期
        env.now += 4 * 60 + 59
        await store.refreshItemValueIfStale()
        #expect(env.api.summaryCalls == 2)
        env.now += 1
        await store.refreshItemValueIfStale()
        #expect(env.api.summaryCalls == 3)

        env.now -= 3600
        await store.refreshItemValueIfStale()
        #expect(env.api.summaryCalls == 4)
    }

    @Test("拉汇总失败时保留缓存并记下原因，之后成功再清空")
    func keepsCacheOnFailure() async {
        let env = DataLinkEnvironment()
        env.api.linksResult = .success(Self.grantedLinks)
        let first = Self.summary(inService: 1000)
        env.api.summaryResult = .success(first)
        let store = env.makeStore()
        await store.refreshLinks()
        await store.refreshItemValueIfStale()
        #expect(store.lastSummaryFailure == nil)

        env.now += 301
        env.api.summaryResult = .failure(.upstreamFailed)
        await store.refreshItemValueIfStale()
        #expect(env.api.summaryCalls == 2)
        #expect(store.cachedSummary == first)
        #expect(store.lastSummaryFailure == .upstreamFailed)
        #expect(store.isItemValueGranted)
        #expect(store.accountValuation == 840)

        env.now += 301
        let second = Self.summary(inService: 2000)
        env.api.summaryResult = .success(second)
        await store.refreshItemValueIfStale()
        #expect(store.cachedSummary == second)
        #expect(store.lastSummaryFailure == nil)
    }

    @Test("服务端说没授权：内存里变成未授权并清缓存；说来源没开：从列表里去掉并清缓存")
    func serverSaysNotGrantedOrUnavailable() async {
        let env = DataLinkEnvironment()
        env.api.linksResult = .success(Self.grantedLinks)
        env.api.summaryResult = .success(Self.summary())
        let store = env.makeStore()
        await store.refreshLinks()
        await store.refreshItemValueIfStale()
        #expect(store.cachedSummary != nil)

        env.now += 301
        env.api.summaryResult = .failure(.notGranted)
        await store.refreshItemValueIfStale()
        #expect(!store.isItemValueGranted)
        #expect(store.isItemValueLinkAvailable)
        #expect(store.linkState == .notGranted)
        #expect(store.links?.first?.granted == false)
        #expect(store.cachedSummary == nil)
        #expect(env.defaults.data(forKey: DataLinkStore.summaryKey(userID: "user-1")) == nil)
        #expect(store.lastSummaryFailure == nil)

        // 再授权回来，这次服务端说来源没开
        env.api.linksResult = .success(Self.grantedLinks)
        env.api.summaryResult = .success(Self.summary())
        await store.refreshLinks()
        await store.refreshItemValueIfStale()
        #expect(store.cachedSummary != nil)

        env.now += 301
        env.api.summaryResult = .failure(.unavailable)
        await store.refreshItemValueIfStale()
        #expect(!store.isItemValueLinkAvailable)
        #expect(store.links?.contains(where: { $0.source == DataLinkCode.source }) == false)
        #expect(store.cachedSummary == nil)
    }

    // MARK: - Store：授权与取消

    @Test("授权成功：更新列表并立即拉一次汇总；失败时带原因、不改状态；来源没开时把它从列表里去掉")
    func grantsAndFetchesSummary() async {
        let env = DataLinkEnvironment()
        env.api.linksResult = .success(Self.notGrantedLinks)
        let store = env.makeStore()
        await store.refreshLinks()

        env.api.grantResult = .failure(.rateLimited)
        let rejected = await store.grant()
        #expect(Self.failure(of: rejected) == .rateLimited)
        #expect(!store.isItemValueGranted)
        #expect(env.api.summaryCalls == 0)

        env.api.grantResult = .failure(.unavailable)
        let unavailable = await store.grant()
        #expect(Self.failure(of: unavailable) == .unavailable)
        #expect(!store.isItemValueLinkAvailable)

        env.api.linksResult = .success(Self.notGrantedLinks)
        await store.refreshLinks()
        env.api.grantResult = .success(DataLinkStatus(granted: true, grantedAt: Self.fetchedAt))
        env.api.summaryResult = .success(Self.summary())
        let granted = await store.grant()
        #expect(Self.isSuccess(granted))
        #expect(env.api.summaryCalls == 1)
        #expect(store.isItemValueGranted)
        #expect(store.cachedSummary == Self.summary())
        #expect(store.links?.first?.grantedAt == Self.fetchedAt)
    }

    @Test("没登录或不允许联网时授权、取消授权不发请求")
    func grantAndRevokeNeedSignInAndNetwork() async {
        let env = DataLinkEnvironment()
        let store = env.makeStore()

        env.userID = nil
        let signedOutGrant = await store.grant()
        let signedOutRevoke = await store.revoke()
        #expect(Self.failure(of: signedOutGrant) == .notSignedIn)
        #expect(Self.failure(of: signedOutRevoke) == .notSignedIn)

        env.userID = "user-1"
        env.isNetworkAllowed = false
        let offlineGrant = await store.grant()
        let offlineRevoke = await store.revoke()
        #expect(Self.failure(of: offlineGrant) == .network)
        #expect(Self.failure(of: offlineRevoke) == .network)
        #expect(env.api.grantCalls == 0)
        #expect(env.api.revokeCalls == 0)
    }

    @Test("取消授权成功后清掉汇总缓存、改成未授权，设置保留；失败时状态和缓存保持原样")
    func revokeClearsCache() async {
        let env = DataLinkEnvironment()
        env.api.linksResult = .success(Self.grantedLinks)
        env.api.summaryResult = .success(Self.summary())
        let store = env.makeStore()
        await store.refreshLinks()
        await store.refreshItemValueIfStale()
        store.settings = ItemValuationSettings(discountPercent: 85)

        env.api.revokeResult = .failure(.network)
        let failed = await store.revoke()
        #expect(Self.failure(of: failed) == .network)
        #expect(store.isItemValueGranted)
        #expect(store.cachedSummary != nil)

        env.api.revokeResult = .success(DataLinkStatus(granted: false))
        let revoked = await store.revoke()
        #expect(Self.isSuccess(revoked))
        #expect(env.api.revokeCalls == 2)
        #expect(!store.isItemValueGranted)
        #expect(store.linkState == .notGranted)
        #expect(store.cachedSummary == nil)
        #expect(env.defaults.data(forKey: DataLinkStore.summaryKey(userID: "user-1")) == nil)
        #expect(store.settings.discountPercent == 85)
        #expect(store.accountValuation == nil)
    }

    // MARK: - Store：换账号与清理

    @Test("换账号后内存清空，汇总缓存和设置按账号隔离")
    func isolatesAccounts() async {
        let env = DataLinkEnvironment()
        let store = env.makeStore()
        let summary1 = Self.summary(inService: 100)
        let summary2 = Self.summary(inService: 900)

        env.userID = "user-1"
        env.api.linksResult = .success(Self.grantedLinks)
        env.api.summaryResult = .success(summary1)
        await store.refreshLinks()
        await store.refreshItemValueIfStale()
        store.settings = ItemValuationSettings(discountPercent: 85)
        #expect(store.cachedSummary == summary1)

        // 换成 user-2：列表还没刷新就按不可用，刷新失败也不会沿用 user-1 的内存状态
        env.userID = "user-2"
        #expect(!store.isItemValueLinkAvailable)
        #expect(store.cachedSummary == nil)
        #expect(store.settings.discountPercent == 70)
        env.api.linksResult = .failure(.network)
        await store.refreshLinks()
        #expect(store.links == nil)
        #expect(!store.isItemValueLinkAvailable)

        env.api.linksResult = .success(Self.grantedLinks)
        env.api.summaryResult = .success(summary2)
        await store.refreshLinks()
        await store.refreshItemValueIfStale()
        #expect(store.cachedSummary == summary2)

        // 回到 user-1：缓存和设置都还是他自己的
        env.userID = "user-1"
        await store.refreshLinks()
        #expect(store.cachedSummary == summary1)
        #expect(store.settings.discountPercent == 85)
    }

    @Test("退出登录只清汇总缓存，注销账号连设置一起清")
    func clearsCurrentUserData() async {
        let env = DataLinkEnvironment()
        env.api.linksResult = .success(Self.grantedLinks)
        env.api.summaryResult = .success(Self.summary())
        let store = env.makeStore()
        await store.refreshLinks()
        await store.refreshItemValueIfStale()
        let custom = ItemValuationSettings(showsOnAccounts: false, countsInNetWorth: true, discountPercent: 85)
        store.settings = custom
        #expect(store.cachedSummary != nil)

        store.clearCurrentUserCache()
        #expect(store.cachedSummary == nil)
        #expect(env.defaults.data(forKey: DataLinkStore.summaryKey(userID: "user-1")) == nil)
        #expect(store.settings == custom)

        await store.refreshItemValueIfStale()
        #expect(store.cachedSummary != nil)

        store.forgetCurrentUser()
        #expect(store.cachedSummary == nil)
        #expect(store.settings == ItemValuationSettings())
        #expect(env.defaults.data(forKey: DataLinkStore.settingsKey(userID: "user-1")) == nil)

        // 清别的账号不会动到 user-2 的数据
        env.userID = "user-2"
        store.settings = custom
        env.userID = "user-1"
        store.forgetCurrentUser()
        env.userID = "user-2"
        #expect(store.settings == custom)
    }

    @Test("凭证被清掉后按被退出的账号清汇总缓存：已经取不到当前账号也能清，设置保留，不动别的账号")
    func clearsCacheForSignedOutUser() async {
        let env = DataLinkEnvironment()
        env.api.linksResult = .success(Self.grantedLinks)
        env.api.summaryResult = .success(Self.summary())
        let store = env.makeStore()
        await store.refreshLinks()
        await store.refreshItemValueIfStale()
        let custom = ItemValuationSettings(showsOnAccounts: false, countsInNetWorth: true, discountPercent: 85)
        store.settings = custom
        env.defaults.set(Data("other".utf8), forKey: DataLinkStore.summaryKey(userID: "user-2"))
        #expect(env.defaults.data(forKey: DataLinkStore.summaryKey(userID: "user-1")) != nil)

        // 凭证失效自动退出时 AuthStore 先清凭证再回调，此时已取不到当前账号
        env.userID = nil
        store.clearCache(forUserID: "user-1")
        #expect(env.defaults.data(forKey: DataLinkStore.summaryKey(userID: "user-1")) == nil)
        #expect(env.defaults.data(forKey: DataLinkStore.summaryKey(userID: "user-2")) != nil)

        env.userID = "user-1"
        #expect(store.settings == custom)
    }

    @Test("存储的键带账号 ID；设置写入时折扣夹进范围并对齐，没登录时写入被忽略")
    func settingsStorage() {
        #expect(DataLinkStore.summaryKey(userID: "u1") == "dataLink.yadoi.itemValue.summary.u1")
        #expect(DataLinkStore.settingsKey(userID: "u1") == "dataLink.yadoi.itemValue.settings.u1")

        let env = DataLinkEnvironment()
        let store = env.makeStore()
        #expect(store.settings == ItemValuationSettings())

        var settings = store.settings
        settings.discountPercent = 7
        store.settings = settings
        #expect(store.settings.discountPercent == 10)
        settings.discountPercent = 72
        store.settings = settings
        #expect(store.settings.discountPercent == 70)
        #expect(env.defaults.data(forKey: DataLinkStore.settingsKey(userID: "user-1")) != nil)

        env.userID = nil
        settings.discountPercent = 90
        store.settings = settings
        env.userID = "user-1"
        #expect(store.settings.discountPercent == 70)
    }

    // MARK: - Store：账户页和净资产怎么用估值

    @Test("没有一件填了购入价时没有估值，也不显示账户页那一行、不计入净资产")
    func noValuationWithoutPricedItems() async {
        let env = DataLinkEnvironment()
        env.api.linksResult = .success(Self.grantedLinks)
        let store = env.makeStore()
        await store.refreshLinks()

        env.api.summaryResult = .success(Self.summary(priced: 0, unpriced: 3))
        await store.refreshItemValueIfStale(force: true)
        #expect(store.accountValuation == nil)
        #expect(!store.showsAccountRow)
        #expect(store.netWorthValuation == nil)
        #expect(store.linkState == .linkedNoPrices)

        env.api.summaryResult = .success(Self.summary(priced: 0, unpriced: 0))
        await store.refreshItemValueIfStale(force: true)
        #expect(store.accountValuation == nil)
        #expect(store.linkState == .linkedNoItems)
    }

    @Test("关掉「显示在账户页」时也不计入净资产，原来的「计入净资产」选择保留；折扣改了估值跟着变")
    func hidingRowAlsoExcludesFromNetWorth() async {
        let env = DataLinkEnvironment()
        env.api.linksResult = .success(Self.grantedLinks)
        env.api.summaryResult = .success(Self.summary(inService: 1000, retired: 200, priced: 3, unpriced: 0))
        let store = env.makeStore()
        await store.refreshLinks()
        await store.refreshItemValueIfStale()

        // 默认都开、七折：(1000 + 200) × 70% = 840
        #expect(store.accountValuation == 840)
        #expect(store.showsAccountRow)
        #expect(store.netWorthValuation == 840)

        // 只关显示：账户页没有这一行，估值也不计入净资产；存的「计入净资产」仍是开
        store.settings = ItemValuationSettings(showsOnAccounts: false, countsInNetWorth: true, discountPercent: 70)
        #expect(!store.showsAccountRow)
        #expect(store.netWorthValuation == nil)
        #expect(store.settings.countsInNetWorth)
        #expect(!store.settings.countsTowardNetWorth)

        // 重新打开显示：恢复计入
        store.settings = ItemValuationSettings(showsOnAccounts: true, countsInNetWorth: true, discountPercent: 70)
        #expect(store.showsAccountRow)
        #expect(store.netWorthValuation == 840)

        // 只关计入：这一行还在，但不计入净资产
        store.settings = ItemValuationSettings(showsOnAccounts: true, countsInNetWorth: false, discountPercent: 70)
        #expect(store.showsAccountRow)
        #expect(store.netWorthValuation == nil)
        #expect(store.accountValuation == 840)

        // 都关
        store.settings = ItemValuationSettings(showsOnAccounts: false, countsInNetWorth: false, discountPercent: 70)
        #expect(!store.showsAccountRow)
        #expect(store.netWorthValuation == nil)

        // 折扣改成原价
        store.settings = ItemValuationSettings(showsOnAccounts: true, countsInNetWorth: true, discountPercent: 100)
        #expect(store.accountValuation == 1200)
        #expect(store.netWorthValuation == 1200)
    }

    // MARK: - Store：晚到的结果

    @Test("取汇总期间换了账号：旧账号晚到的结果直接丢掉，不写进任何账号的缓存")
    func dropsSummaryArrivingAfterAccountSwitch() async {
        let env = DataLinkEnvironment()
        env.api.linksResult = .success(Self.grantedLinks)
        env.api.summaryResult = .success(Self.summary())
        let store = env.makeStore()
        await store.refreshLinks()

        let gate = AsyncSaveGate()
        env.api.summaryGate = gate
        let refresh = Task { await store.refreshItemValueIfStale() }
        while !gate.hasStarted {
            await Task.yield()
        }
        env.userID = "user-2"
        gate.resume()
        await refresh.value

        #expect(env.defaults.data(forKey: DataLinkStore.summaryKey(userID: "user-1")) == nil)
        #expect(env.defaults.data(forKey: DataLinkStore.summaryKey(userID: "user-2")) == nil)
    }

    @Test("取汇总期间取消了授权：晚到的汇总不再写进缓存")
    func dropsSummaryArrivingAfterRevoke() async {
        let env = DataLinkEnvironment()
        env.api.linksResult = .success(Self.grantedLinks)
        env.api.summaryResult = .success(Self.summary())
        let store = env.makeStore()
        await store.refreshLinks()

        let gate = AsyncSaveGate()
        env.api.summaryGate = gate
        let refresh = Task { await store.refreshItemValueIfStale() }
        while !gate.hasStarted {
            await Task.yield()
        }
        env.api.revokeResult = .success(DataLinkStatus(granted: false))
        _ = await store.revoke()
        gate.resume()
        await refresh.value

        #expect(!store.isItemValueGranted)
        #expect(store.cachedSummary == nil)
    }

    @Test("授权成功后，更早发起的联动列表刷新晚到，不会盖掉已授权的状态")
    func staleLinksRefreshDoesNotOverrideGrant() async {
        let env = DataLinkEnvironment()
        env.api.linksResult = .success(Self.notGrantedLinks)
        env.api.summaryResult = .success(Self.summary())
        let store = env.makeStore()

        let gate = AsyncSaveGate()
        env.api.linksGate = gate
        let refresh = Task { await store.refreshLinks() }
        while !gate.hasStarted {
            await Task.yield()
        }
        env.api.grantResult = .success(DataLinkStatus(granted: true, grantedAt: Self.fetchedAt))
        let granted = await store.grant()
        gate.resume()
        await refresh.value

        #expect(Self.isSuccess(granted))
        #expect(store.isItemValueGranted)
    }

    // MARK: - 工具

    /// 从字符串构造金额，用 POSIX 区域按「.」解析，不经过二进制浮点。
    private static func decimal(_ text: String) -> Decimal {
        guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
            preconditionFailure("测试里的金额写错了：\(text)")
        }
        return value
    }

    /// 测试用的汇总：默认在用 1000、退役 200，5 件填了价格、1 件没填。
    private static func summary(
        inService: Decimal = 1000,
        retired: Decimal = 200,
        priced: Int = 5,
        unpriced: Int = 1,
        lastUpdatedAt: Date? = Date(timeIntervalSince1970: 1_795_428_000)
    ) -> ItemValueSummary {
        ItemValueSummary(
            inServicePurchaseTotal: inService,
            retiredPurchaseTotal: retired,
            pricedItemCount: priced,
            unpricedItemCount: unpriced,
            lastItemUpdatedAt: lastUpdatedAt,
            fetchedAt: DataLinkTests.fetchedAt
        )
    }

    /// 结果是不是成功。
    private static func isSuccess(_ result: Result<Void, DataLinkAPIError>) -> Bool {
        if case .success = result { return true }
        return false
    }

    /// 失败的原因；成功时为 nil。
    private static func failure(of result: Result<Void, DataLinkAPIError>) -> DataLinkAPIError? {
        if case let .failure(error) = result { return error }
        return nil
    }
}

/// 一个用例用到的全部可变环境：当前账号、联网许可、时钟、假接口和独立的 UserDefaults。
@MainActor
private final class DataLinkEnvironment {
    /// 当前登录账号；未登录时为 nil。
    var userID: String? = "user-1"

    /// 是否允许联网。
    var isNetworkAllowed = true

    /// 当前时间，用例里往前拨来验证 5 分钟节流。
    var now = Date(timeIntervalSince1970: 1_800_000_000)

    /// 假接口。
    let api = FakeDataLinkAPI()

    /// 只属于这个用例的本机存储。
    let defaults: UserDefaults

    init() {
        let suiteName = UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("无法创建测试用的偏好存储")
        }
        defaults.removePersistentDomain(forName: suiteName)
        self.defaults = defaults
    }

    /// 创建读这个环境的 `DataLinkStore`。
    func makeStore() -> DataLinkStore {
        DataLinkStore(
            api: api,
            currentUserID: { [self] in userID },
            isNetworkAllowed: { [self] in isNetworkAllowed },
            defaults: defaults,
            now: { [self] in now }
        )
    }
}

/// 数据联动接口的假实现。
@MainActor
private final class FakeDataLinkAPI: DataLinkServing {
    /// 拉联动列表的结果。
    var linksResult: Result<DataLinkList, DataLinkAPIError> = .success(DataLinkList(links: []))

    /// 授权的结果。
    var grantResult: Result<DataLinkStatus, DataLinkAPIError> = .success(DataLinkStatus(granted: true))

    /// 取消授权的结果。
    var revokeResult: Result<DataLinkStatus, DataLinkAPIError> = .success(DataLinkStatus(granted: false))

    /// 取汇总的结果；没设置时按契约错误处理。
    var summaryResult: Result<ItemValueSummary, DataLinkAPIError> = .failure(.invalidContract)

    /// 设置后拉联动列表时先挂起，直到用例恢复。
    var linksGate: AsyncSaveGate?

    /// 设置后取汇总时先挂起，直到用例恢复。
    var summaryGate: AsyncSaveGate?

    /// 拉联动列表的次数。
    private(set) var fetchLinksCalls = 0

    /// 授权的次数。
    private(set) var grantCalls = 0

    /// 取消授权的次数。
    private(set) var revokeCalls = 0

    /// 取汇总的次数。
    private(set) var summaryCalls = 0

    func fetchLinks() async throws -> DataLinkList {
        fetchLinksCalls += 1
        if let linksGate {
            await linksGate.wait()
        }
        return try linksResult.get()
    }

    func grantItemValue() async throws -> DataLinkStatus {
        grantCalls += 1
        return try grantResult.get()
    }

    func revokeItemValue() async throws -> DataLinkStatus {
        revokeCalls += 1
        return try revokeResult.get()
    }

    func fetchItemValueSummary() async throws -> ItemValueSummary {
        summaryCalls += 1
        if let summaryGate {
            await summaryGate.wait()
        }
        return try summaryResult.get()
    }
}
