import Foundation
import Testing
@testable import yadoA

/// 验证点数充值：商品契约解码、上传结果映射，以及“服务端确认入账后才结束交易”的购买流程。
@Suite("点数充值")
@MainActor
struct AIPointsShopTests {
    /// 测试用的 appAccountToken。
    static let token = UUID(uuidString: "7F1C2A8E-5B6D-4C3F-9A2B-1E4D5C6B7A89")!

    // MARK: - 契约

    @Test("商品列表解码：token 转成 UUID，不认识的角标不显示，没开放购买时为空，带上价值锚点")
    func decodesCatalog() throws {
        let json = """
        {"enabled":true,"appAccountToken":"7f1c2a8e-5b6d-4c3f-9a2b-1e4d5c6b7a89","items":[
          {"productId":"top.yado1225.yadoA.points_s","kind":"consumable","points":60,"badge":null},
          {"productId":"top.yado1225.yadoA.points_m","kind":"consumable","points":180,"badge":"popular"},
          {"productId":"top.yado1225.yadoA.points_l","kind":"consumable","points":450,"badge":"best_value"},
          {"productId":"top.yado1225.yadoA.vip_month","kind":"subscription","points":0,"badge":"limited_time"}
        ],"valueAnchorProductId":"top.yado1225.yadoA.points_s"}
        """
        let catalog = try JSONDecoder().decode(AIStoreCatalog.self, from: Data(json.utf8))
        #expect(catalog.isEnabled)
        #expect(catalog.appAccountToken == Self.token)
        #expect(catalog.items.map(\.points) == [60, 180, 450, 0])
        #expect(catalog.items.map(\.badge) == [nil, .popular, .bestValue, nil])
        #expect(catalog.items[1].id == "top.yado1225.yadoA.points_m")
        #expect(catalog.valueAnchorProductID == "top.yado1225.yadoA.points_s")

        let disabled = try JSONDecoder().decode(
            AIStoreCatalog.self,
            from: Data(#"{"enabled":false,"appAccountToken":null,"items":[],"valueAnchorProductId":null}"#.utf8)
        )
        #expect(!disabled.isEnabled)
        #expect(disabled.appAccountToken == nil)
        #expect(disabled.items.isEmpty)
        #expect(disabled.valueAnchorProductID == nil)
    }

    @Test("价值锚点解码：旧服务端没有这个字段、值为 null 或空字符串时都当作没有锚点，解码不失败")
    func decodesMissingValueAnchorAsNil() throws {
        let legacy = try JSONDecoder().decode(
            AIStoreCatalog.self,
            from: Data(
                #"{"enabled":true,"appAccountToken":"7f1c2a8e-5b6d-4c3f-9a2b-1e4d5c6b7a89","items":[{"productId":"top.yado1225.yadoA.points_s","kind":"consumable","points":60,"badge":null}]}"#.utf8
            )
        )
        #expect(legacy.items.map(\.points) == [60])
        #expect(legacy.valueAnchorProductID == nil)

        let empty = try JSONDecoder().decode(
            AIStoreCatalog.self,
            from: Data(#"{"enabled":true,"appAccountToken":null,"items":[],"valueAnchorProductId":""}"#.utf8)
        )
        #expect(empty.valueAnchorProductID == nil)
    }

    @Test("活动字段解码：新人包带资格到期时间，限时多送带多送点数和结束时间，普通商品三个字段为 nil / 0 / nil")
    func decodesPromotionFields() throws {
        let json = """
        {"enabled":true,"appAccountToken":"7f1c2a8e-5b6d-4c3f-9a2b-1e4d5c6b7a89","items":[
          {"productId":"top.yado1225.yadoA.points_starter","kind":"consumable","points":100,"badge":null,
           "promotion":"starter","bonusPoints":0,"promotionEndsAt":"2026-12-15T00:00:00.000Z"},
          {"productId":"top.yado1225.yadoA.points_s","kind":"consumable","points":60,"badge":null,
           "promotion":null,"bonusPoints":0,"promotionEndsAt":null},
          {"productId":"top.yado1225.yadoA.points_m","kind":"consumable","points":180,"badge":"popular",
           "promotion":"bonus","bonusPoints":40,"promotionEndsAt":"2026-11-30T15:59:59.000Z"}
        ],"valueAnchorProductId":"top.yado1225.yadoA.points_s"}
        """
        let items = try JSONDecoder().decode(AIStoreCatalog.self, from: Data(json.utf8)).items
        #expect(items.map(\.promotion) == [.starter, nil, .bonus])
        #expect(items.map(\.bonusPoints) == [0, 0, 40])
        #expect(items.map(\.promotionEndsAt) == [Date(timeIntervalSince1970: 1_797_292_800), nil, Date(timeIntervalSince1970: 1_796_054_399)])
        #expect(items.map(\.isStarter) == [true, false, false])
        #expect(items.map(\.activeBonusPoints) == [nil, nil, 40])
        // points 仍是基础点数，角标不受活动字段影响
        #expect(items.map(\.points) == [100, 60, 180])
        #expect(items.map(\.badge) == [nil, nil, .popular])
    }

    @Test("活动字段缺失（旧服务端）：promotion 为 nil，多送点数为 0，没有结束时间，和没有活动时一样")
    func decodesMissingPromotionFieldsAsPlainItem() throws {
        let item = try JSONDecoder().decode(
            AIStoreItem.self,
            from: Data(#"{"productId":"top.yado1225.yadoA.points_m","kind":"consumable","points":180,"badge":"popular"}"#.utf8)
        )
        #expect(item.promotion == nil)
        #expect(item.bonusPoints == 0)
        #expect(item.promotionEndsAt == nil)
        #expect(!item.isStarter)
        #expect(item.activeBonusPoints == nil)
        #expect(item == AIStoreItem(productID: "top.yado1225.yadoA.points_m", points: 180, badge: .popular))
    }

    @Test("不认识的活动类型按普通商品处理，整个列表仍然能解码")
    func decodesUnknownPromotionAsPlainItem() throws {
        let json = """
        {"enabled":true,"appAccountToken":null,"items":[
          {"productId":"a","kind":"consumable","points":60,"promotion":"flash","bonusPoints":25,"promotionEndsAt":"2026-12-15T00:00:00.000Z"},
          {"productId":"b","kind":"consumable","points":180,"promotion":"bonus","bonusPoints":40,"promotionEndsAt":"2026-12-15T00:00:00.000Z"}
        ]}
        """
        let catalog = try JSONDecoder().decode(AIStoreCatalog.self, from: Data(json.utf8))
        #expect(catalog.items.map(\.points) == [60, 180])
        #expect(catalog.items[0].promotion == nil)
        #expect(!catalog.items[0].isStarter)
        // 不认识的类型即使带着多送点数，也不当作限时多送
        #expect(catalog.items[0].activeBonusPoints == nil)
        #expect(catalog.items[1].activeBonusPoints == 40)
    }

    @Test("多送点数为负数或类型不对时为 0；类型不对、时间格式不对的字段不让解码失败")
    func decodesMalformedPromotionFieldsLeniently() throws {
        let json = """
        {"enabled":true,"appAccountToken":null,"items":[
          {"productId":"negative","kind":"consumable","points":60,"promotion":"bonus","bonusPoints":-5},
          {"productId":"string","kind":"consumable","points":60,"promotion":"bonus","bonusPoints":"40"},
          {"productId":"fraction","kind":"consumable","points":60,"promotion":"bonus","bonusPoints":1.5},
          {"productId":"nulls","kind":"consumable","points":60,"promotion":null,"bonusPoints":null,"promotionEndsAt":null},
          {"productId":"wrongTypes","kind":"consumable","points":60,"promotion":7,"bonusPoints":[],"promotionEndsAt":12345},
          {"productId":"badDate","kind":"consumable","points":60,"promotion":"starter","bonusPoints":0,"promotionEndsAt":"soon"}
        ]}
        """
        let items = try JSONDecoder().decode(AIStoreCatalog.self, from: Data(json.utf8)).items
        #expect(items.map(\.productID) == ["negative", "string", "fraction", "nulls", "wrongTypes", "badDate"])
        #expect(items.map(\.bonusPoints) == [0, 0, 0, 0, 0, 0])
        #expect(items.map(\.activeBonusPoints) == [nil, nil, nil, nil, nil, nil])
        #expect(items.map(\.promotion) == [.bonus, .bonus, .bonus, nil, nil, .starter])
        #expect(items.map(\.promotionEndsAt) == [nil, nil, nil, nil, nil, nil])
    }

    @Test("上传结果映射：200 解码，409 区分别的账号与已注销账号，400 是拒绝入账，其余按状态码")
    func mapsPurchaseResponses() throws {
        let ok = try AIBillingAPI.purchaseResult(
            statusCode: 200,
            data: Data(#"{"status":"credited","points":300,"balance":398}"#.utf8)
        )
        #expect(ok == AIStorePurchaseResult(status: .credited, points: 300, balance: 398))
        let future = try AIBillingAPI.purchaseResult(
            statusCode: 200,
            data: Data(#"{"status":"queued","points":0,"balance":98}"#.utf8)
        )
        #expect(future.status == .unknown)

        func failure(_ statusCode: Int, _ body: String) -> Error? {
            do {
                _ = try AIBillingAPI.purchaseResult(statusCode: statusCode, data: Data(body.utf8))
                return nil
            } catch {
                return error
            }
        }
        let mismatch = #"{"code":"PURCHASE_ACCOUNT_MISMATCH","message":"x","details":{"reason":"other_account"}}"#
        #expect(failure(409, mismatch) as? AIStoreUploadError == .otherAccount)
        let unknown = #"{"code":"PURCHASE_ACCOUNT_MISMATCH","message":"x","details":{"reason":"unknown_account"}}"#
        #expect(failure(409, unknown) as? AIStoreUploadError == .unknownAccount)
        let invalid = #"{"code":"PURCHASE_INVALID","message":"x","details":{"reason":"unknown_product"}}"#
        #expect(failure(400, invalid) as? AIStoreUploadError == .rejected(reason: "unknown_product"))
        #expect(failure(503, #"{"code":"BILLING_UNAVAILABLE","message":"x"}"#) as? AIBillingAPIError == .serviceUnavailable)
        #expect(failure(409, "not json") as? AIBillingAPIError == .invalidContract)

        #expect(AIStoreUploadError.unknownAccount.shouldFinishTransaction)
        #expect(!AIStoreUploadError.otherAccount.shouldFinishTransaction)
        #expect(!AIStoreUploadError.rejected(reason: "unknown_product").shouldFinishTransaction)
        #expect(!AIStoreUploadError.billing(.network).shouldFinishTransaction)
    }

    // MARK: - 商品

    @Test("只展示服务端列出、StoreKit 也查得到的商品，按服务端顺序；没开放购买时不查 StoreKit")
    func showsOffersAvailableOnBothSides() async {
        let api = FakeStoreAPI()
        let storeKit = FakeStoreKit()
        storeKit.products = [Self.product("p3000", displayPrice: "¥45.00", price: 45), Self.product("p300", displayPrice: "¥6.00")]
        api.catalogResults = [.success(Self.catalog(["p300", "p1000", "p3000"]))]
        let shop = AIPointsShop(api: api, storeKit: storeKit, currentUserID: { "user-1" })

        await shop.refresh()
        #expect(shop.offers.map(\.id) == ["p300", "p3000"])
        #expect(shop.offers.map(\.product.displayPrice) == ["¥6.00", "¥45.00"])
        #expect(storeKit.requestedProductIDs == [["p300", "p1000", "p3000"]])
        #expect(!shop.hasSubscriptions)

        api.catalogResults = [.success(AIStoreCatalog(isEnabled: false, appAccountToken: nil, items: []))]
        await shop.refresh()
        #expect(shop.offers.isEmpty)
        #expect(storeKit.requestedProductIDs.count == 1)
    }

    @Test("新人包排到第一个，其他商品保持服务端顺序；starterOffer 取出它；StoreKit 查不到新人包时不显示")
    func putsStarterOfferFirst() async {
        let api = FakeStoreAPI()
        let storeKit = FakeStoreKit()
        storeKit.products = ["p60", "p180", "starter", "p450"].map { Self.product($0) }
        api.catalogResults = [
            .success(
                AIStoreCatalog(
                    isEnabled: true,
                    appAccountToken: Self.token,
                    items: [
                        AIStoreItem(productID: "p60", points: 60),
                        AIStoreItem(productID: "p180", points: 180, badge: .popular),
                        // starterOffer 按当前时间判断资格有没有到期，所以到期时间取相对现在的将来，不写死
                        AIStoreItem(productID: "starter", points: 100, promotion: .starter, promotionEndsAt: Self.futureStarterEndsAt),
                        AIStoreItem(productID: "p450", points: 450, badge: .bestValue),
                    ],
                    valueAnchorProductID: "p60"
                )
            )
        ]
        let shop = AIPointsShop(api: api, storeKit: storeKit, currentUserID: { "user-1" })
        #expect(shop.starterOffer == nil)

        await shop.refresh()
        #expect(shop.offers.map(\.id) == ["starter", "p60", "p180", "p450"])
        #expect(shop.starterOffer?.id == "starter")
        // 价值锚点仍按服务端指定的平价档折算，不受新人包影响
        #expect(shop.pointValue?.anchorPoints == 60)

        // 纯函数：没有新人包时顺序不变
        let items = [AIStoreItem(productID: "p60", points: 60), AIStoreItem(productID: "p180", points: 180)]
        #expect(AIPointsShop.offers(items: items, products: items.map { Self.product($0.productID) }).map(\.id) == ["p60", "p180"])

        // StoreKit 里没有新人包商品时它不出现，其余照常
        storeKit.products = ["p60", "p180"].map { Self.product($0) }
        await shop.refresh()
        #expect(shop.offers.map(\.id) == ["p60", "p180"])
        #expect(shop.starterOffer == nil)
    }

    @Test("新人包资格剩余天数：不足一天按 1 天，刚好 14 天是 14，向上取整，已到期为 nil")
    func countsStarterDaysLeft() {
        let now = Date(timeIntervalSince1970: 1_796_000_000)
        func daysLeft(after seconds: TimeInterval) -> Int? {
            AIPointsShop.starterDaysLeft(endsAt: now.addingTimeInterval(seconds), now: now)
        }
        let day: TimeInterval = 86_400
        #expect(daysLeft(after: 14 * day) == 14)
        #expect(daysLeft(after: 14 * day - 1) == 14)
        #expect(daysLeft(after: 13 * day + 1) == 14)
        #expect(daysLeft(after: 13 * day) == 13)
        #expect(daysLeft(after: 2 * day + 3_600) == 3)
        #expect(daysLeft(after: day) == 1)
        #expect(daysLeft(after: day - 1) == 1)
        #expect(daysLeft(after: 1) == 1)
        // 到期的那一刻和已经过了都没有剩余天数
        #expect(daysLeft(after: 0) == nil)
        #expect(daysLeft(after: -1) == nil)
        #expect(daysLeft(after: -3 * day) == nil)
    }

    @Test("visibleOffers：新人包资格到期的那一刻起不显示，其他商品原样保留、顺序不变；没有到期时间的新人包始终显示")
    func hidesExpiredStarterOffer() async {
        let endsAt = Date(timeIntervalSince1970: 1_797_292_800)
        let api = FakeStoreAPI()
        let storeKit = FakeStoreKit()
        storeKit.products = ["p60", "starter", "p180"].map { Self.product($0) }
        // 限时多送也带结束时间：就算过了，也不归 visibleOffers 管
        api.catalogResults = [
            .success(
                AIStoreCatalog(
                    isEnabled: true,
                    appAccountToken: Self.token,
                    items: [
                        AIStoreItem(productID: "p60", points: 60),
                        AIStoreItem(productID: "starter", points: 100, promotion: .starter, promotionEndsAt: endsAt),
                        AIStoreItem(productID: "p180", points: 180, promotion: .bonus, bonusPoints: 40, promotionEndsAt: endsAt),
                    ]
                )
            )
        ]
        let shop = AIPointsShop(api: api, storeKit: storeKit, currentUserID: { "user-1" })
        #expect(shop.visibleOffers(now: endsAt).isEmpty)

        await shop.refresh()
        #expect(shop.offers.map(\.id) == ["starter", "p60", "p180"])
        #expect(shop.visibleOffers(now: endsAt.addingTimeInterval(-1)).map(\.id) == ["starter", "p60", "p180"])
        // 到期的那一刻起就不再显示
        #expect(shop.visibleOffers(now: endsAt).map(\.id) == ["p60", "p180"])
        #expect(shop.visibleOffers(now: endsAt.addingTimeInterval(1)).map(\.id) == ["p60", "p180"])
        // 只是不显示：offers 本身要等下次刷新才更新
        #expect(shop.offers.map(\.id) == ["starter", "p60", "p180"])

        // 新人包没有到期时间时始终显示
        api.catalogResults = [
            .success(
                AIStoreCatalog(
                    isEnabled: true,
                    appAccountToken: Self.token,
                    items: [
                        AIStoreItem(productID: "p60", points: 60),
                        AIStoreItem(productID: "starter", points: 100, promotion: .starter),
                    ]
                )
            )
        ]
        await shop.refresh()
        #expect(shop.visibleOffers(now: endsAt).map(\.id) == ["starter", "p60"])
        #expect(shop.visibleOffers(now: .distantFuture).map(\.id) == ["starter", "p60"])
    }

    @Test("starterOffer 不含资格已到期的新人包，其他商品不受影响")
    func starterOfferIgnoresExpiredStarter() async {
        let api = FakeStoreAPI()
        let storeKit = FakeStoreKit()
        storeKit.products = ["starter", "p60"].map { Self.product($0) }
        api.catalogResults = [.success(Self.starterCatalog(endsAt: Date(timeIntervalSinceNow: -60)))]
        let shop = AIPointsShop(api: api, storeKit: storeKit, currentUserID: { "user-1" })

        await shop.refresh()
        #expect(shop.offers.map(\.id) == ["starter", "p60"])
        #expect(shop.starterOffer == nil)
        #expect(shop.visibleOffers(now: Date()).map(\.id) == ["p60"])
    }

    @Test("限时多送结束日期：结束时刻不含在活动内，显示日期取它前 1 秒；次日 00:00 结束显示前一天")
    func showsBonusLastMomentDate() throws {
        // 固定上海时区，不依赖运行机器的时区
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        func date(_ month: Int, _ day: Int, hour: Int, minute: Int, second: Int) throws -> Date {
            try #require(calendar.date(from: DateComponents(
                year: 2026, month: month, day: day, hour: hour, minute: minute, second: second
            )))
        }
        // 显示出来的 [月, 日]
        func shownDay(endsAt: Date) -> [Int?] {
            let components = calendar.dateComponents([.month, .day], from: AIPointsShop.bonusLastMoment(endsAt: endsAt))
            return [components.month, components.day]
        }

        // 2026-12-01T00:00:00+08:00 结束：活动到 11 月 30 日为止
        let midnight = try date(12, 1, hour: 0, minute: 0, second: 0)
        #expect(AIPointsShop.bonusLastMoment(endsAt: midnight) == midnight.addingTimeInterval(-1))
        #expect(shownDay(endsAt: midnight) == [11, 30])

        // 2026-11-30T23:59:59+08:00 结束：同样是 11 月 30 日
        #expect(shownDay(endsAt: try date(11, 30, hour: 23, minute: 59, second: 59)) == [11, 30])

        // 过了零点 1 秒结束：最后一刻刚好是新一天的 00:00:00
        #expect(shownDay(endsAt: try date(12, 1, hour: 0, minute: 0, second: 1)) == [12, 1])
    }

    @Test("拉商品列表时把 StoreKit 当前的商店地区交给服务端；取不到时传 nil")
    func passesStorefrontToCatalogRequest() async {
        let api = FakeStoreAPI()
        let storeKit = FakeStoreKit()
        api.catalogResults = [.success(Self.catalog(["p300"]))]
        let shop = AIPointsShop(api: api, storeKit: storeKit, currentUserID: { "user-1" })

        // 默认是 CHN
        await shop.refresh()
        #expect(api.requestedStorefronts == ["CHN"])

        storeKit.storefront = "USA"
        await shop.refresh()
        #expect(api.requestedStorefronts == ["CHN", "USA"])

        storeKit.storefront = nil
        await shop.refresh()
        #expect(api.requestedStorefronts == ["CHN", "USA", nil])
    }

    @Test("未登录或不能联网时不查商品、不补传交易")
    func staysIdleWhenSignedOutOrOffline() async {
        let api = FakeStoreAPI()
        let storeKit = FakeStoreKit()
        storeKit.unfinished = [Self.transaction(1)]
        var userID: String?
        var isNetworkAllowed = true
        let shop = AIPointsShop(
            api: api,
            storeKit: storeKit,
            currentUserID: { userID },
            isNetworkAllowed: { isNetworkAllowed }
        )

        await shop.refresh()
        await shop.processUnfinishedTransactions()
        #expect(api.catalogRequests == 0)
        #expect(api.uploads.isEmpty)

        userID = "user-1"
        isNetworkAllowed = false
        await shop.refresh()
        await shop.processUnfinishedTransactions()
        #expect(api.catalogRequests == 0)
        #expect(api.uploads.isEmpty)
        #expect(storeKit.finishedIDs.isEmpty)
    }

    // MARK: - 购买

    @Test("购买成功：带上账号 token 付款，上传入账后才结束交易，刷新余额并提示到账点数")
    func purchaseCreditsThenFinishes() async throws {
        let api = FakeStoreAPI()
        let storeKit = FakeStoreKit()
        storeKit.products = [Self.product("p300")]
        storeKit.purchaseOutcome = .success(Self.transaction(42, finishedIDs: storeKit))
        api.catalogResults = [.success(Self.catalog(["p300"]))]
        var creditCount = 0
        let shop = AIPointsShop(api: api, storeKit: storeKit, currentUserID: { "user-1" }, didCredit: { creditCount += 1 })
        api.onUpload = { #expect(storeKit.finishedIDs.isEmpty, "入账前不能结束交易") }

        await shop.refresh()
        let offer = try #require(shop.offers.first)
        await shop.purchase(offer)

        #expect(storeKit.purchases.map(\.productID) == ["p300"])
        #expect(storeKit.purchases.map(\.token) == [Self.token])
        #expect(api.uploads == ["jws-42"])
        #expect(storeKit.finishedIDs == [42])
        #expect(creditCount == 1)
        #expect(shop.notice == .credited(points: 300))
        #expect(shop.purchasingProductID == nil)

        shop.dismissNotice()
        #expect(shop.notice == nil)
    }

    @Test("买了别的商品入账后新人包马上下架：不再显示也不再有引导，其他商品还在，也不重新拉商品列表")
    func removesStarterOfferAfterPurchase() async throws {
        let api = FakeStoreAPI()
        let storeKit = FakeStoreKit()
        storeKit.products = ["starter", "p60"].map { Self.product($0) }
        storeKit.purchaseOutcome = .success(Self.transaction(42, finishedIDs: storeKit))
        api.catalogResults = [.success(Self.starterCatalog())]
        let shop = AIPointsShop(api: api, storeKit: storeKit, currentUserID: { "user-1" })

        await shop.refresh()
        #expect(shop.offers.map(\.id) == ["starter", "p60"])
        #expect(shop.starterOffer != nil)
        #expect(api.catalogRequests == 1)

        await shop.purchase(try #require(shop.offers.first { $0.id == "p60" }))
        #expect(api.uploads == ["jws-42"])
        #expect(storeKit.finishedIDs == [42])
        #expect(shop.notice == .credited(points: 300))
        #expect(shop.offers.map(\.id) == ["p60"])
        #expect(shop.starterOffer == nil)
        // 只在本地去掉，不重新拉列表（重新拉会再补传交易，和 deliver 互相调用）
        #expect(api.catalogRequests == 1)
    }

    @Test("直接补传一笔交易：服务端处理完（入账、重复、已退款）新人包都下架；没传成或账号已注销时新人包还在")
    func removesStarterOfferOnlyWhenDelivered() async {
        let delivered: [AIStorePurchaseResult.Status] = [.credited, .duplicate, .revoked]
        for status in delivered {
            let result = AIStorePurchaseResult(status: status, points: status == .revoked ? 0 : 300, balance: 398)
            let (shop, storeKit) = await Self.shopShowingStarter(uploadResult: .success(result))
            #expect(shop.starterOffer != nil)

            #expect(await shop.deliver(Self.transaction(1, finishedIDs: storeKit)) == .delivered(result))
            #expect(storeKit.finishedIDs == [1], "\(status)")
            #expect(shop.offers.map(\.id) == ["p60"], "\(status)")
            #expect(shop.starterOffer == nil, "\(status)")
        }

        // 交易还留着（没传成、别的账号）或者不可能入账（账号已注销）：新人包不动
        let notDelivered: [(error: AIStoreUploadError, result: AIPointsShop.DeliveryResult)] = [
            (.billing(.network), .deferred(.billing(.network))),
            (.otherAccount, .deferred(.otherAccount)),
            (.unknownAccount, .abandoned),
        ]
        for (error, expected) in notDelivered {
            let (shop, storeKit) = await Self.shopShowingStarter(uploadResult: .failure(error))

            #expect(await shop.deliver(Self.transaction(2, finishedIDs: storeKit)) == expected, "\(error)")
            #expect(shop.offers.map(\.id) == ["starter", "p60"], "\(error)")
            #expect(shop.starterOffer != nil, "\(error)")
        }
    }

    @Test("付了款但没传成：交易不结束，提示稍后到账；下次补传成功后结束")
    func keepsTransactionWhenUploadFails() async throws {
        let api = FakeStoreAPI()
        let storeKit = FakeStoreKit()
        storeKit.products = [Self.product("p300")]
        let transaction = Self.transaction(7, finishedIDs: storeKit)
        storeKit.purchaseOutcome = .success(transaction)
        api.catalogResults = [.success(Self.catalog(["p300"]))]
        api.uploadResults = [.failure(.billing(.network))]
        let shop = AIPointsShop(api: api, storeKit: storeKit, currentUserID: { "user-1" })

        await shop.refresh()
        await shop.purchase(try #require(shop.offers.first))
        #expect(api.uploads == ["jws-7"])
        #expect(storeKit.finishedIDs.isEmpty)
        #expect(shop.notice == .creditDelayed)

        api.uploadResults = [.success(AIStorePurchaseResult(status: .duplicate, points: 300, balance: 398))]
        storeKit.unfinished = [transaction]
        await shop.processUnfinishedTransactions()
        #expect(api.uploads == ["jws-7", "jws-7"])
        #expect(storeKit.finishedIDs == [7])
    }

    @Test("交易属于别的账号时留着等那个账号登录；买它的账号已注销时结束交易；服务端拒绝入账时留着")
    func decidesFinishByUploadError() async {
        let api = FakeStoreAPI()
        let storeKit = FakeStoreKit()
        let shop = AIPointsShop(api: api, storeKit: storeKit, currentUserID: { "user-1" })

        api.uploadResults = [.failure(.otherAccount)]
        #expect(await shop.deliver(Self.transaction(1, finishedIDs: storeKit)) == .deferred(.otherAccount))
        #expect(storeKit.finishedIDs.isEmpty)
        #expect(AIPointsShop.notice(for: .deferred(.otherAccount)) == .otherAccount)

        api.uploadResults = [.failure(.rejected(reason: "unknown_product"))]
        #expect(await shop.deliver(Self.transaction(2, finishedIDs: storeKit)) == .deferred(.rejected(reason: "unknown_product")))
        #expect(storeKit.finishedIDs.isEmpty)

        api.uploadResults = [.failure(.unknownAccount)]
        #expect(await shop.deliver(Self.transaction(3, finishedIDs: storeKit)) == .abandoned)
        #expect(AIPointsShop.notice(for: .abandoned) == .cannotCredit)
        #expect(storeKit.finishedIDs == [3])

        api.uploadResults = [.success(AIStorePurchaseResult(status: .revoked, points: 0, balance: 98))]
        let revoked = await shop.deliver(Self.transaction(4, finishedIDs: storeKit))
        #expect(storeKit.finishedIDs == [3, 4])
        #expect(AIPointsShop.notice(for: revoked) == nil)
    }

    @Test("取消购买不提示；等待批准提示批准后到账；没能发起购买提示没有扣款")
    func mapsStoreKitOutcomes() async throws {
        let api = FakeStoreAPI()
        let storeKit = FakeStoreKit()
        storeKit.products = [Self.product("p300")]
        api.catalogResults = [.success(Self.catalog(["p300"]))]
        let shop = AIPointsShop(api: api, storeKit: storeKit, currentUserID: { "user-1" })
        await shop.refresh()
        let offer = try #require(shop.offers.first)

        storeKit.purchaseOutcome = .cancelled
        await shop.purchase(offer)
        #expect(shop.notice == nil)

        storeKit.purchaseOutcome = .pending
        await shop.purchase(offer)
        #expect(shop.notice == .pending)

        storeKit.purchaseError = AIStoreKitError.productUnavailable
        await shop.purchase(offer)
        #expect(shop.notice == .failed)
        #expect(api.uploads.isEmpty)
    }

    @Test("换了账号后旧账号的商品清空，购买不会用旧账号的 token")
    func clearsOffersWhenAccountChanges() async throws {
        let api = FakeStoreAPI()
        let storeKit = FakeStoreKit()
        storeKit.products = [Self.product("p300")]
        api.catalogResults = [.success(Self.catalog(["p300"]))]
        var userID: String? = "user-1"
        let shop = AIPointsShop(api: api, storeKit: storeKit, currentUserID: { userID })
        await shop.refresh()
        let offer = try #require(shop.offers.first)

        userID = "user-2"
        await shop.purchase(offer)
        #expect(storeKit.purchases.isEmpty)

        userID = nil
        await shop.refresh()
        #expect(shop.offers.isEmpty)
    }

    @Test("订阅商品：识别为订阅，界面据此显示续订说明")
    func detectsSubscriptions() async {
        let api = FakeStoreAPI()
        let storeKit = FakeStoreKit()
        storeKit.products = [
            Self.product("p300"),
            AIStoreProduct(
                id: "vip",
                displayName: "会员",
                displayPrice: "¥18.00",
                price: 18,
                currencyCode: "CNY",
                priceLocale: Locale(identifier: "zh_CN"),
                subscriptionPeriod: (unit: .month, value: 1)
            ),
        ]
        api.catalogResults = [.success(Self.catalog(["p300", "vip"]))]
        let shop = AIPointsShop(api: api, storeKit: storeKit, currentUserID: { "user-1" })
        await shop.refresh()
        #expect(shop.offers.map(\.product.isSubscription) == [false, true])
        #expect(shop.hasSubscriptions)
    }

    // MARK: - 点数价值

    @Test("锚点商品在 StoreKit 里查得到：按它的价格折算，12 点 = ¥1.20，点数不大于 0 不折算")
    func computesPointValueFromAnchor() async throws {
        let api = FakeStoreAPI()
        let storeKit = FakeStoreKit()
        storeKit.products = [Self.product("p60"), Self.product("p180", displayPrice: "¥18.00", price: 18)]
        api.catalogResults = [.success(Self.catalog(["p60", "p180"], points: 60, anchor: "p60"))]
        let shop = AIPointsShop(api: api, storeKit: storeKit, currentUserID: { "user-1" })
        #expect(shop.pointValue == nil)

        await shop.refresh()
        let value = try #require(shop.pointValue)
        // 和自己格式化的结果比，不写死字符串，避免不同系统的格式差异
        let expected = Decimal(string: "1.2")!.formatted(Decimal.FormatStyle.Currency(code: "CNY", locale: Locale(identifier: "zh_CN")))
        #expect(value.amountText(points: 12) == expected)
        #expect(value.amountText(points: 60) == Decimal(6).formatted(Decimal.FormatStyle.Currency(code: "CNY", locale: Locale(identifier: "zh_CN"))))
        #expect(value.amountText(points: 0) == nil)
        #expect(value.amountText(points: -5) == nil)
    }

    @Test("美区价格折算：US$0.99 对 60 点，12 点是 $0.20；先乘后除，不先取整每点价格")
    func formatsDollarValue() throws {
        let item = AIStoreItem(productID: "p60", points: 60)
        let product = AIStoreProduct(
            id: "p60",
            displayName: "p60",
            displayPrice: "$0.99",
            price: Decimal(string: "0.99")!,
            currencyCode: "USD",
            priceLocale: Locale(identifier: "en_US")
        )
        let value = try #require(AIPointValue(item: item, product: product))
        #expect(value.amountText(points: 12) == "$0.20")
        // 先把每点价格（0.0165）取整成 0.02 再乘的话，12 点会是 $0.24、60 点会是 $1.20
        #expect(value.amountText(points: 60) == "$0.99")
    }

    @Test("折算依据不合法时没有价值：商品对不上、点数或价格不大于 0")
    func rejectsInvalidPointValueAnchor() {
        let product = Self.product("p60")
        #expect(AIPointValue(item: AIStoreItem(productID: "p60", points: 60), product: product) != nil)
        #expect(AIPointValue(item: AIStoreItem(productID: "p180", points: 60), product: product) == nil)
        #expect(AIPointValue(item: AIStoreItem(productID: "p60", points: 0), product: product) == nil)
        #expect(AIPointValue(item: AIStoreItem(productID: "p60", points: -60), product: product) == nil)
        #expect(AIPointValue(item: AIStoreItem(productID: "p60", points: 60), product: Self.product("p60", price: 0)) == nil)
    }

    @Test("拿不到价值时为 nil：后端没给锚点、锚点不在 StoreKit 结果里、锚点不在商品列表里、没开放购买")
    func hasNoPointValueWithoutAnchor() async {
        let api = FakeStoreAPI()
        let storeKit = FakeStoreKit()
        storeKit.products = [Self.product("p60")]
        let shop = AIPointsShop(api: api, storeKit: storeKit, currentUserID: { "user-1" })

        // 后端没给锚点
        api.catalogResults = [.success(Self.catalog(["p60"], points: 60))]
        await shop.refresh()
        #expect(shop.offers.map(\.id) == ["p60"])
        #expect(shop.pointValue == nil)

        // 锚点商品 StoreKit 查不到
        api.catalogResults = [.success(Self.catalog(["p60", "p180"], points: 60, anchor: "p180"))]
        await shop.refresh()
        #expect(shop.pointValue == nil)

        // 没开放购买：就算后端给了锚点也不折算，也不查 StoreKit
        let requestsBefore = storeKit.requestedProductIDs.count
        api.catalogResults = [.success(AIStoreCatalog(isEnabled: false, appAccountToken: nil, items: [], valueAnchorProductID: "p60"))]
        await shop.refresh()
        #expect(shop.pointValue == nil)
        #expect(storeKit.requestedProductIDs.count == requestsBefore)

        // 锚点不在商品列表里（后端配置有误）：就算 StoreKit 里有同名商品也不折算
        let catalog = Self.catalog(["p60"], points: 60, anchor: "p180")
        let products = [Self.product("p60"), Self.product("p180")]
        #expect(AIPointsShop.pointValue(catalog: catalog, products: products) == nil)
        #expect(AIPointsShop.pointValue(catalog: Self.catalog(["p60"], points: 60, anchor: "p60"), products: products) != nil)
    }

    @Test("拿到价值后退出登录：价值清空；刷新失败时保留上一次的价值")
    func clearsPointValueOnSignOut() async {
        let api = FakeStoreAPI()
        let storeKit = FakeStoreKit()
        storeKit.products = [Self.product("p60")]
        api.catalogResults = [.success(Self.catalog(["p60"], points: 60, anchor: "p60"))]
        var userID: String? = "user-1"
        let shop = AIPointsShop(api: api, storeKit: storeKit, currentUserID: { userID })

        await shop.refresh()
        #expect(shop.pointValue != nil)

        api.catalogResults = [.failure(.network)]
        await shop.refresh()
        #expect(shop.pointValue != nil)

        userID = nil
        await shop.refresh()
        #expect(shop.pointValue == nil)
    }

    @Test("refreshIfNeeded：没加载过时加载，加载失败下次再试，成功后不再查询商品列表，换账号后重新加载")
    func refreshesOnlyWhenNeeded() async {
        let api = FakeStoreAPI()
        let storeKit = FakeStoreKit()
        storeKit.products = [Self.product("p60")]
        api.catalogResults = [.failure(.network), .success(Self.catalog(["p60"], points: 60, anchor: "p60"))]
        var userID: String? = "user-1"
        let shop = AIPointsShop(api: api, storeKit: storeKit, currentUserID: { userID })

        await shop.refreshIfNeeded()
        #expect(api.catalogRequests == 1)
        #expect(shop.pointValue == nil)

        await shop.refreshIfNeeded()
        #expect(api.catalogRequests == 2)
        #expect(shop.pointValue != nil)

        await shop.refreshIfNeeded()
        #expect(api.catalogRequests == 2)

        userID = "user-2"
        await shop.refreshIfNeeded()
        #expect(api.catalogRequests == 3)
    }

    @Test("礼包规则的最高点数合计：把所有开启次数的上限加起来，不计负数")
    func sumsGiftRuleMaxPoints() {
        let weekly = AICheckInGiftRule(
            tier: .weekly,
            everyDays: 7,
            openings: [AICheckInGiftOpening(minPoints: 21, maxPoints: 50)],
            validDays: 7
        )
        let yearly = AICheckInGiftRule(
            tier: .yearly,
            everyDays: 365,
            openings: [AICheckInGiftOpening(minPoints: 365, maxPoints: 365), AICheckInGiftOpening(minPoints: 100, maxPoints: 365)],
            validDays: 365
        )
        let broken = AICheckInGiftRule(
            tier: .monthly,
            everyDays: 30,
            openings: [AICheckInGiftOpening(minPoints: 0, maxPoints: -10), AICheckInGiftOpening(minPoints: 0, maxPoints: 20)],
            validDays: 30
        )
        let empty = AICheckInGiftRule(tier: .monthly, everyDays: 30, openings: [], validDays: 30)
        #expect(weekly.maxTotalPoints == 50)
        #expect(yearly.maxTotalPoints == 730)
        #expect(broken.maxTotalPoints == 20)
        #expect(empty.maxTotalPoints == 0)
    }

    // MARK: - 测试数据

    /// 在售商品列表，每个商品默认 300 点。
    ///
    /// - Parameters:
    ///   - ids: 商品 ID，按展示顺序。
    ///   - points: 每个商品的点数。
    ///   - anchor: 价值锚点的商品 ID；不传表示后端没给锚点。
    static func catalog(_ ids: [String], points: Int = 300, anchor: String? = nil) -> AIStoreCatalog {
        AIStoreCatalog(
            isEnabled: true,
            appAccountToken: token,
            items: ids.map { AIStoreItem(productID: $0, points: points) },
            valueAnchorProductID: anchor
        )
    }

    /// 新人包资格的到期时间：两周后。
    ///
    /// `starterOffer` 按当前时间判断资格有没有到期，所以测试里的到期时间取相对现在的将来，不写死日期。
    static var futureStarterEndsAt: Date {
        Date(timeIntervalSinceNow: 14 * 86_400)
    }

    /// 有新人包的在售商品列表：普通商品 `p60`（60 点）和新人包 `starter`（100 点）；界面上新人包会排在最前。
    ///
    /// - Parameter endsAt: 新人包资格的到期时间；不传表示两周后。默认值用 nil，不在默认参数里取值，避开 MainActor 隔离问题。
    static func starterCatalog(endsAt: Date? = nil) -> AIStoreCatalog {
        AIStoreCatalog(
            isEnabled: true,
            appAccountToken: token,
            items: [
                AIStoreItem(productID: "p60", points: 60),
                AIStoreItem(productID: "starter", points: 100, promotion: .starter, promotionEndsAt: endsAt ?? futureStarterEndsAt),
            ]
        )
    }

    /// 已经加载好商品的充值状态：列表里有新人包和 `p60`，上传交易时返回 `uploadResult`。
    ///
    /// - Parameter uploadResult: 上传交易的结果。
    /// - Returns: 充值状态，和它用的假 StoreKit（用来看交易有没有结束）。
    static func shopShowingStarter(
        uploadResult: Result<AIStorePurchaseResult, AIStoreUploadError>
    ) async -> (shop: AIPointsShop, storeKit: FakeStoreKit) {
        let api = FakeStoreAPI()
        let storeKit = FakeStoreKit()
        storeKit.products = ["starter", "p60"].map { Self.product($0) }
        api.catalogResults = [.success(starterCatalog())]
        api.uploadResults = [uploadResult]
        let shop = AIPointsShop(api: api, storeKit: storeKit, currentUserID: { "user-1" })
        await shop.refresh()
        return (shop, storeKit)
    }

    /// StoreKit 商品，默认是 ¥6.00（中国大陆）。
    static func product(
        _ id: String,
        displayPrice: String = "¥6.00",
        price: Decimal = 6,
        currencyCode: String = "CNY",
        localeIdentifier: String = "zh_CN"
    ) -> AIStoreProduct {
        AIStoreProduct(
            id: id,
            displayName: id,
            displayPrice: displayPrice,
            price: price,
            currencyCode: currencyCode,
            priceLocale: Locale(identifier: localeIdentifier)
        )
    }

    /// 待入账的交易；结束时记进 `finishedIDs`。
    static func transaction(_ id: UInt64, finishedIDs storeKit: FakeStoreKit? = nil) -> AIStoreTransaction {
        AIStoreTransaction(id: id, productID: "p300", signedTransaction: "jws-\(id)") { [weak storeKit] in
            await MainActor.run { storeKit?.finishedIDs.append(id) }
        }
    }
}

/// 假的服务端接口：按顺序返回预设结果，记下上传过的交易。
@MainActor
final class FakeStoreAPI: AIStorePurchasing {
    /// 依次返回的商品列表结果；用完后重复最后一个。
    var catalogResults: [Result<AIStoreCatalog, AIBillingAPIError>] = [
        .success(AIStoreCatalog(isEnabled: false, appAccountToken: nil, items: []))
    ]

    /// 依次返回的上传结果；用完后重复最后一个。
    var uploadResults: [Result<AIStorePurchaseResult, AIStoreUploadError>] = [
        .success(AIStorePurchaseResult(status: .credited, points: 300, balance: 398))
    ]

    /// 上传时调用，用来检查上传那一刻的状态。
    var onUpload: () -> Void = {}

    /// 查询商品列表的次数。
    private(set) var catalogRequests = 0

    /// 依次查询商品列表时带的商店地区。
    private(set) var requestedStorefronts: [String?] = []

    /// 依次上传过的签名交易。
    private(set) var uploads: [String] = []

    func fetchStoreCatalog(storefront: String?) async throws -> AIStoreCatalog {
        catalogRequests += 1
        requestedStorefronts.append(storefront)
        let result = catalogResults.count > 1 ? catalogResults.removeFirst() : catalogResults[0]
        return try result.get()
    }

    func submitPurchase(signedTransaction: String) async throws -> AIStorePurchaseResult {
        onUpload()
        uploads.append(signedTransaction)
        let result = uploadResults.count > 1 ? uploadResults.removeFirst() : uploadResults[0]
        return try result.get()
    }
}

/// 假的 StoreKit：预设商品与购买结果，记下购买请求和结束过的交易。
@MainActor
final class FakeStoreKit: AIStoreKitProviding {
    /// 查得到的商品。
    var products: [AIStoreProduct] = []

    /// 购买结果。
    var purchaseOutcome: AIStoreKitPurchaseOutcome = .cancelled

    /// 设置后购买直接抛出这个错误。
    var purchaseError: Error?

    /// 没结束的交易。
    var unfinished: [AIStoreTransaction] = []

    /// 当前 Storefront 的国家代码；nil 表示取不到。
    var storefront: String? = "CHN"

    /// 依次查询过的商品 ID。
    private(set) var requestedProductIDs: [[String]] = []

    /// 依次发起的购买。
    private(set) var purchases: [(productID: String, token: UUID)] = []

    /// 结束过的交易 ID。
    var finishedIDs: [UInt64] = []

    func products(for ids: [String]) async throws -> [AIStoreProduct] {
        requestedProductIDs.append(ids)
        return products.filter { ids.contains($0.id) }
    }

    func purchase(productID: String, appAccountToken: UUID) async throws -> AIStoreKitPurchaseOutcome {
        if let purchaseError { throw purchaseError }
        purchases.append((productID, appAccountToken))
        return purchaseOutcome
    }

    func unfinishedTransactions() async -> [AIStoreTransaction] {
        unfinished
    }

    func observeTransactionUpdates(_ handler: @escaping @MainActor (AIStoreTransaction) async -> Void) -> Task<Void, Never> {
        Task {}
    }

    func storefrontCountryCode() async -> String? {
        storefront
    }
}
