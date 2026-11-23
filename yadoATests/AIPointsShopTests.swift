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

    @Test("商品列表解码：token 转成 UUID，不认识的角标不显示，没开放购买时为空")
    func decodesCatalog() throws {
        let json = """
        {"enabled":true,"appAccountToken":"7f1c2a8e-5b6d-4c3f-9a2b-1e4d5c6b7a89","items":[
          {"productId":"top.yado1225.yadoA.points_300","kind":"consumable","points":300,"badge":null},
          {"productId":"top.yado1225.yadoA.points_1000","kind":"consumable","points":1000,"badge":"popular"},
          {"productId":"top.yado1225.yadoA.points_3000","kind":"consumable","points":3000,"badge":"best_value"},
          {"productId":"top.yado1225.yadoA.vip_month","kind":"subscription","points":0,"badge":"limited_time"}
        ]}
        """
        let catalog = try JSONDecoder().decode(AIStoreCatalog.self, from: Data(json.utf8))
        #expect(catalog.isEnabled)
        #expect(catalog.appAccountToken == Self.token)
        #expect(catalog.items.map(\.points) == [300, 1000, 3000, 0])
        #expect(catalog.items.map(\.badge) == [nil, .popular, .bestValue, nil])
        #expect(catalog.items[1].id == "top.yado1225.yadoA.points_1000")

        let disabled = try JSONDecoder().decode(
            AIStoreCatalog.self,
            from: Data(#"{"enabled":false,"appAccountToken":null,"items":[]}"#.utf8)
        )
        #expect(!disabled.isEnabled)
        #expect(disabled.appAccountToken == nil)
        #expect(disabled.items.isEmpty)
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
        storeKit.products = [Self.product("p3000", price: "¥45.00"), Self.product("p300", price: "¥6.00")]
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
            AIStoreProduct(id: "vip", displayName: "会员", displayPrice: "¥18.00", subscriptionPeriod: (unit: .month, value: 1)),
        ]
        api.catalogResults = [.success(Self.catalog(["p300", "vip"]))]
        let shop = AIPointsShop(api: api, storeKit: storeKit, currentUserID: { "user-1" })
        await shop.refresh()
        #expect(shop.offers.map(\.product.isSubscription) == [false, true])
        #expect(shop.hasSubscriptions)
    }

    // MARK: - 测试数据

    /// 在售商品列表，每个商品 300 点。
    static func catalog(_ ids: [String]) -> AIStoreCatalog {
        AIStoreCatalog(isEnabled: true, appAccountToken: token, items: ids.map { AIStoreItem(productID: $0, points: 300) })
    }

    /// StoreKit 商品。
    static func product(_ id: String, price: String = "¥6.00") -> AIStoreProduct {
        AIStoreProduct(id: id, displayName: id, displayPrice: price)
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

    /// 依次上传过的签名交易。
    private(set) var uploads: [String] = []

    func fetchStoreCatalog() async throws -> AIStoreCatalog {
        catalogRequests += 1
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
}
