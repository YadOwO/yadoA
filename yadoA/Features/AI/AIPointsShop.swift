import Foundation
import Observation

/// 点数充值：在售商品、购买和交易入账。只有登录后才有，未登录时什么都不显示。
///
/// 一笔购买分两步：StoreKit 付款成功 → 把 Apple 签名的交易上传给 yado_ai 入账，服务端确认后才结束（finish）交易。
/// 上传失败（断网、服务端暂时不可用、登录的是别的账号）时交易留在 StoreKit 里，下次 App 启动、换账号登录或打开点数页时再传，
/// 付了钱的点数不会丢。服务端也会收到 Apple 的购买通知，App 没来得及上传时由它兜底入账，两边重复也只入账一次。
///
/// 商品由服务端列出（入账点数、角标），名称和价格以 StoreKit 为准；只展示两边都有的商品。
/// 以后服务端开卖订阅时，这里按 StoreKit 的商品类型显示周期和续订说明，旧版 App 不用更新也能买（入账由服务端处理）。
///
/// 同一次加载还会算出 `pointValue`：服务端指定的锚点商品在 StoreKit 里的当地价格，用来在得到点数的地方（签到、开礼包、
/// 礼包里程碑、点数页余额）显示这些点数值多少钱。拿不到价值时它是 nil，各处整行不显示，也不影响签到和页面加载。
@Observable
final class AIPointsShop {
    /// 界面上的一个商品：服务端给的点数和角标，加上 StoreKit 给的名称和价格。
    struct Offer: Equatable, Identifiable {
        /// 服务端的商品信息。
        let item: AIStoreItem

        /// StoreKit 的商品信息。
        let product: AIStoreProduct

        var id: String { item.productID }
    }

    /// 一次购买的结果，界面据此弹出提示；用户关掉提示后清空。
    enum PurchaseNotice: Equatable, Identifiable {
        /// 已入账，带入账的点数。
        case credited(points: Int)

        /// 等待批准（询问购买、银行验证），批准后自动入账。
        case pending

        /// 已付款，但点数还没入账（网络或服务暂时不可用）；稍后自动重试，不用再买。
        case creditDelayed

        /// 已付款，但这笔购买属于另一个芽豆账号；换回那个账号登录后入账。
        case otherAccount

        /// 已付款，但这笔购买永远入不了账（买它的账号已注销，或不属于这套环境），交易已结束，用户需要向 Apple 申请退款。
        case cannotCredit

        /// 没能发起购买（商品已下架、App Store 暂时不可用等），没有扣款。
        case failed

        var id: String {
            switch self {
            case let .credited(points): "credited-\(points)"
            case .pending: "pending"
            case .creditDelayed: "creditDelayed"
            case .otherAccount: "otherAccount"
            case .cannotCredit: "cannotCredit"
            case .failed: "failed"
            }
        }
    }

    /// 可以买的商品，按服务端的顺序；未登录、没开放购买或还没加载时为空。
    private(set) var offers: [Offer] = []

    /// 点数价值的折算依据；未登录、没开放购买、后端没给锚点、StoreKit 查不到锚点商品或还没加载时为 nil。
    private(set) var pointValue: AIPointValue?

    /// 是否正在加载商品。
    private(set) var isLoading = false

    /// 正在购买的商品 ID；用来显示转圈并拦住重复点击。
    private(set) var purchasingProductID: String?

    /// 最近一次购买的结果提示；界面展示后调用 `dismissNotice()` 清空。
    private(set) var notice: PurchaseNotice?

    /// 在售商品列表；`offers` 的服务端来源，也带着本账号的 appAccountToken。
    private var catalog: AIStoreCatalog?

    /// 当前商品列表所属的账号；换账号或退出登录时清空。
    private var ownerUserID: String?

    /// 正在上传的交易 ID；同一笔交易同时从购买结果和交易更新两条路过来时只传一次。
    private var uploadingTransactionIDs: Set<UInt64> = []

    /// 交易更新的监听任务；整个 App 生命周期只有一个。
    private var updatesTask: Task<Void, Never>?

    /// 服务端接口。
    private let api: AIStorePurchasing

    /// StoreKit。
    private let storeKit: AIStoreKitProviding

    /// 读取当前登录账号 ID 的动作；未登录时返回 nil。
    private let currentUserID: () -> String?

    /// 当前是否允许联网：中国大陆地区同意隐私政策之前为 false，此时不查商品、不上传交易（交易留到能联网后再传）。
    private let isNetworkAllowed: () -> Bool

    /// 入账成功后刷新余额的动作。
    private let didCredit: () async -> Void

    /// 创建充值状态。
    ///
    /// - Parameters:
    ///   - api: 服务端接口。
    ///   - storeKit: StoreKit。
    ///   - currentUserID: 读取当前登录账号 ID 的动作。
    ///   - isNetworkAllowed: 查询当前是否允许联网的动作。
    ///   - didCredit: 入账成功后调用，用来刷新余额。
    init(
        api: AIStorePurchasing,
        storeKit: AIStoreKitProviding,
        currentUserID: @escaping () -> String?,
        isNetworkAllowed: @escaping () -> Bool = { true },
        didCredit: @escaping () async -> Void = {}
    ) {
        self.api = api
        self.storeKit = storeKit
        self.currentUserID = currentUserID
        self.isNetworkAllowed = isNetworkAllowed
        self.didCredit = didCredit
    }

    /// 用登录状态和点数状态创建：凭证取自 AI 服务的 access token，入账后刷新 `aiPoints` 的余额。
    ///
    /// - Parameters:
    ///   - authStore: 全局登录状态。
    ///   - aiPoints: 当前账号的点数。
    ///   - isNetworkAllowed: 查询当前是否允许联网的动作。
    convenience init(authStore: AuthStore, aiPoints: AIPointsStore, isNetworkAllowed: @escaping () -> Bool) {
        self.init(
            api: AIBillingAPI { try await authStore.accessTokenForAIService() },
            storeKit: AIStoreKitClient(),
            currentUserID: { authStore.userID },
            isNetworkAllowed: isNetworkAllowed,
            didCredit: { await aiPoints.refresh() }
        )
    }

    /// 是否有订阅类商品；有时界面要显示续订说明、管理订阅和恢复购买。
    var hasSubscriptions: Bool {
        offers.contains { $0.product.isSubscription }
    }

    // MARK: - 生命周期

    /// 开始监听交易更新（询问购买获批、银行验证完成、订阅续订等），App 启动时调用一次，重复调用无效。
    func startObservingTransactions() {
        guard updatesTask == nil else { return }
        updatesTask = storeKit.observeTransactionUpdates { [weak self] transaction in
            await self?.deliver(transaction)
        }
    }

    /// 补传还没结束的交易：App 启动、换账号登录、打开点数页时调用。未登录或不能联网时什么都不做。
    func processUnfinishedTransactions() async {
        guard isNetworkAllowed(), currentUserID() != nil else { return }
        for transaction in await storeKit.unfinishedTransactions() {
            await deliver(transaction)
        }
    }

    /// 刷新在售商品，并补传还没结束的交易。未登录或不能联网时清空商品。
    ///
    /// 失败时保留上一次的商品，不提示错误：充值区只是不出现或保持原样，不影响点数页的其他内容。
    func refresh() async {
        guard isNetworkAllowed(), let userID = currentUserID() else {
            clear()
            return
        }
        if ownerUserID != userID {
            clear()
            ownerUserID = userID
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let catalog = try await api.fetchStoreCatalog()
            var products: [AIStoreProduct] = []
            if catalog.isEnabled, catalog.appAccountToken != nil {
                products = try await storeKit.products(for: catalog.items.map(\.productID))
            }
            guard currentUserID() == userID else { return }
            self.catalog = catalog
            offers = Self.offers(items: catalog.items, products: products)
            pointValue = Self.pointValue(catalog: catalog, products: products)
        } catch {
            // 保留上一次的商品，下次进入页面再试
        }
        await processUnfinishedTransactions()
    }

    /// 签到页和「我的」页用：本账号还没成功加载过商品列表、也没在加载时才刷新一次，失败不提示，下次进页面再试。
    ///
    /// 调用方不要让签到、余额、日历等加载等它：它只是在后台准备点数价值。
    func refreshIfNeeded() async {
        guard !isLoading, catalog == nil || ownerUserID != currentUserID() else { return }
        await refresh()
    }

    /// 关掉购买结果提示。
    func dismissNotice() {
        notice = nil
    }

    // MARK: - 购买

    /// 购买一个商品：StoreKit 付款成功后马上上传入账，结果放进 `notice`。
    ///
    /// - Parameter offer: 要买的商品。
    func purchase(_ offer: Offer) async {
        guard purchasingProductID == nil,
              let userID = currentUserID(),
              userID == ownerUserID,
              let token = catalog?.appAccountToken else { return }
        purchasingProductID = offer.id
        defer { purchasingProductID = nil }
        do {
            switch try await storeKit.purchase(productID: offer.id, appAccountToken: token) {
            case let .success(transaction):
                notice = Self.notice(for: await deliver(transaction))
            case .pending:
                notice = .pending
            case .cancelled:
                break
            }
        } catch {
            notice = .failed
        }
    }

    // MARK: - 入账

    /// 一笔交易的上传结果。
    enum DeliveryResult: Equatable {
        /// 服务端已处理（入账、重复或已退款），交易已结束。
        case delivered(AIStorePurchaseResult)

        /// 永远入不了账（买它的账号已注销），交易已结束。
        case abandoned

        /// 这次没传成，交易留着下次再传。
        case deferred(AIStoreUploadError?)
    }

    /// 上传一笔交易，服务端确认后结束它；没传成时交易留着。同一笔交易正在上传时直接返回 `.deferred(nil)`。
    ///
    /// - Parameter transaction: 待入账的交易。
    /// - Returns: 上传结果。
    @discardableResult
    func deliver(_ transaction: AIStoreTransaction) async -> DeliveryResult {
        guard isNetworkAllowed(), currentUserID() != nil else { return .deferred(.billing(.notSignedIn)) }
        guard uploadingTransactionIDs.insert(transaction.id).inserted else { return .deferred(nil) }
        defer { uploadingTransactionIDs.remove(transaction.id) }
        do {
            let result = try await api.submitPurchase(signedTransaction: transaction.signedTransaction)
            await transaction.finish()
            await didCredit()
            return .delivered(result)
        } catch let error as AIStoreUploadError {
            if error.shouldFinishTransaction {
                await transaction.finish()
                return .abandoned
            }
            return .deferred(error)
        } catch {
            return .deferred(nil)
        }
    }

    // MARK: - 私有

    /// 清空与账号相关的状态。正在进行的购买不打断，它的结果仍会提示。
    private func clear() {
        catalog = nil
        offers = []
        pointValue = nil
        ownerUserID = nil
    }

    /// 按服务端的顺序，留下 StoreKit 也查得到的商品。
    ///
    /// - Parameters:
    ///   - items: 服务端列出的商品。
    ///   - products: StoreKit 查到的商品。
    /// - Returns: 界面上展示的商品。
    static func offers(items: [AIStoreItem], products: [AIStoreProduct]) -> [Offer] {
        let productsByID = Dictionary(products.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return items.compactMap { item in
            productsByID[item.productID].map { Offer(item: item, product: $0) }
        }
    }

    /// 找出点数价值的折算依据：服务端指定的锚点商品，要在商品列表和 StoreKit 结果里都找得到。
    ///
    /// - Parameters:
    ///   - catalog: 服务端的在售商品列表。
    ///   - products: StoreKit 查到的商品。
    /// - Returns: 折算依据；没开放购买、没有锚点或任一边找不到锚点商品时为 nil。
    static func pointValue(catalog: AIStoreCatalog, products: [AIStoreProduct]) -> AIPointValue? {
        guard catalog.isEnabled,
              let anchorID = catalog.valueAnchorProductID,
              let item = catalog.items.first(where: { $0.productID == anchorID }),
              let product = products.first(where: { $0.id == anchorID }) else { return nil }
        return AIPointValue(item: item, product: product)
    }

    /// 把购买后的上传结果转成提示。
    ///
    /// - Parameter result: 上传结果。
    /// - Returns: 要展示的提示；入账后已退款等不用打扰用户的情况为 nil。
    static func notice(for result: DeliveryResult) -> PurchaseNotice? {
        switch result {
        case let .delivered(purchase):
            purchase.status == .revoked ? nil : .credited(points: purchase.points)
        case .abandoned:
            .cannotCredit
        case .deferred(.otherAccount):
            .otherAccount
        case .deferred:
            .creditDelayed
        }
    }
}

/// 按锚点商品的当地价格折算点数价值，只在得到点数的地方显示。
///
/// 算法：N 点的价值 = 锚点价格 × N ÷ 锚点点数，全程用 `Decimal`，按锚点商品的币种和地区格式输出，小数位跟着货币走。
nonisolated struct AIPointValue: Equatable, Sendable {
    /// 锚点商品在 StoreKit 里的当地价格。
    let anchorPrice: Decimal

    /// 锚点商品入账的点数。
    let anchorPoints: Int

    /// 价格的币种代码，例如 `CNY`、`USD`。
    let currencyCode: String

    /// 价格的地区格式，决定货币符号和小数位的写法。
    let priceLocale: Locale

    /// 用服务端的锚点商品和 StoreKit 的同一个商品创建。
    ///
    /// - Parameters:
    ///   - item: 服务端列出的锚点商品。
    ///   - product: StoreKit 查到的锚点商品。
    /// - Returns: 折算依据；两边不是同一个商品、点数或价格不大于 0 时为 nil（除数为 0 或价格为 0 都算不出有意义的价值）。
    init?(item: AIStoreItem, product: AIStoreProduct) {
        guard item.productID == product.id, item.points > 0, product.price > 0 else { return nil }
        anchorPrice = product.price
        anchorPoints = item.points
        currencyCode = product.currencyCode
        priceLocale = product.priceLocale
    }

    /// 折算 N 点值多少钱，已按币种格式化。
    ///
    /// 先乘后除，不先把每点的价格取整，小数位由货币的格式决定。
    ///
    /// - Parameter points: 点数。
    /// - Returns: 例如 `¥1.20`；点数不大于 0 时为 nil。
    func amountText(points: Int) -> String? {
        guard points > 0 else { return nil }
        let amount = anchorPrice * Decimal(points) / Decimal(anchorPoints)
        return amount.formatted(Decimal.FormatStyle.Currency(code: currencyCode, locale: priceLocale))
    }
}
