import Foundation

// 与 yado_ai `GET /v1/store/catalog`（在售商品）、`POST /v1/store/purchases`（上传交易入账）对应的数据契约，结构以服务端 openapi.json 为准。
//
// 充值相关的都由服务端控制：卖哪些商品、每个给多少点由服务端列出；价格在 App Store Connect 设置，App 显示 StoreKit 返回的当地价格。
// App 只展示「服务端列出、且 StoreKit 查得到」的商品，以后加商品、调整点数甚至加订阅，旧版 App 不用更新也能看到。

// MARK: - 在售商品

/// 当前账号可以买的商品列表。
nonisolated struct AIStoreCatalog: Decodable, Equatable, Sendable {
    /// 本产品在当前环境是否开放 App 内购买；为 false 时不显示充值。
    let isEnabled: Bool

    /// 购买时交给 StoreKit 的 appAccountToken，每个账号固定一个；服务端靠它确认交易属于哪个账号。没开放购买时为 nil。
    let appAccountToken: UUID?

    /// 在售商品，按展示顺序。
    let items: [AIStoreItem]

    /// 用来折算点数价值的商品 ID，一定在 `items` 里；服务端没给（旧服务端）、为 null 或空字符串时为 nil，表示不显示价值。
    let valueAnchorProductID: String?

    private enum CodingKeys: String, CodingKey {
        case isEnabled = "enabled"
        case appAccountToken, items
        case valueAnchorProductID = "valueAnchorProductId"
    }

    /// 逐字段创建，供测试使用。
    init(isEnabled: Bool, appAccountToken: UUID?, items: [AIStoreItem], valueAnchorProductID: String? = nil) {
        self.isEnabled = isEnabled
        self.appAccountToken = appAccountToken
        self.items = items
        self.valueAnchorProductID = valueAnchorProductID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        appAccountToken = try container.decodeIfPresent(String.self, forKey: .appAccountToken).flatMap(UUID.init(uuidString:))
        items = try container.decodeIfPresent([AIStoreItem].self, forKey: .items) ?? []
        // 旧服务端没有这个字段，null 或空字符串也都表示没有锚点，不让整个列表解码失败
        valueAnchorProductID = try container.decodeIfPresent(String.self, forKey: .valueAnchorProductID).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// 一个在售商品：服务端只给商品 ID 和入账点数，名称、价格、是不是订阅都以 StoreKit 为准。
nonisolated struct AIStoreItem: Decodable, Equatable, Identifiable, Sendable {
    /// 完整的 App Store 商品 ID，例如 `top.yado1225.yadoA.points_s`。
    let productID: String

    /// 买一次入账的点数，永不过期。
    let points: Int

    /// 角标；服务端没给或客户端不认识时为 nil。
    let badge: AIStoreItemBadge?

    /// 活动类型；服务端没给（旧服务端、没有活动）或客户端不认识时为 nil，按普通商品显示。
    let promotion: AIStoreItemPromotion?

    /// 限时多送的点数；`points` 仍是基础点数，实际入账 = `points` + `bonusPoints`。缺字段或小于 0 时为 0。
    let bonusPoints: Int

    /// 活动的结束时刻：新人包是这个账号资格到期的时刻，限时多送是活动结束的时刻（不含）；没有或解析失败时为 nil。
    let promotionEndsAt: Date?

    var id: String { productID }

    /// 是否是新人包。
    var isStarter: Bool {
        promotion == .starter
    }

    /// 限时多送的点数；只有 `promotion` 为 `.bonus` 且多送点数大于 0 时有值，其余为 nil。
    var activeBonusPoints: Int? {
        promotion == .bonus && bonusPoints > 0 ? bonusPoints : nil
    }

    private enum CodingKeys: String, CodingKey {
        case productID = "productId"
        case points, badge, promotion, bonusPoints, promotionEndsAt
    }

    /// 逐字段创建，供测试使用。
    init(
        productID: String,
        points: Int,
        badge: AIStoreItemBadge? = nil,
        promotion: AIStoreItemPromotion? = nil,
        bonusPoints: Int = 0,
        promotionEndsAt: Date? = nil
    ) {
        self.productID = productID
        self.points = points
        self.badge = badge
        self.promotion = promotion
        self.bonusPoints = bonusPoints
        self.promotionEndsAt = promotionEndsAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        productID = try container.decode(String.self, forKey: .productID)
        points = try container.decode(Int.self, forKey: .points)
        // 服务端以后新增的角标客户端不认识，不显示，不让整个列表解码失败
        badge = try container.decodeIfPresent(String.self, forKey: .badge).flatMap(AIStoreItemBadge.init(rawValue:))
        // 活动字段都只是附加信息：缺字段、类型不对、值不认识都按普通商品处理，不抛错，不让整个列表解码失败
        promotion = ((try? container.decodeIfPresent(String.self, forKey: .promotion)) ?? nil)
            .flatMap(AIStoreItemPromotion.init(rawValue:))
        bonusPoints = max(((try? container.decodeIfPresent(Int.self, forKey: .bonusPoints)) ?? nil) ?? 0, 0)
        promotionEndsAt = ((try? container.decodeIfPresent(String.self, forKey: .promotionEndsAt)) ?? nil)
            .flatMap(AIBillingTimestamp.parse)
    }
}

/// 商品的活动类型，与 yado_ai `config/store.ts` 的 `STORE_ITEM_PROMOTIONS` 一致；以后可能增加，客户端不认识的值按普通商品显示。
nonisolated enum AIStoreItemPromotion: String, Equatable, Sendable {
    /// 新人专享：只有有资格的账号的商品列表里才有这个商品。
    case starter

    /// 限时多送：活动期间入账点数 = 基础点数 + 多送点数。
    case bonus
}

/// 商品角标，与 yado_ai `config/store.ts` 的 `STORE_ITEM_BADGES` 一致。
nonisolated enum AIStoreItemBadge: String, Equatable, Sendable {
    /// 最受欢迎。
    case popular

    /// 最划算。
    case bestValue = "best_value"

    /// 角标文案的本地化 key。
    var titleKey: String {
        switch self {
        case .popular: "ai.store.badge.popular"
        case .bestValue: "ai.store.badge.bestValue"
        }
    }
}

// MARK: - 上传交易

/// 上传交易后的入账结果；三种状态 App 都可以结束（finish）这笔交易。
nonisolated struct AIStorePurchaseResult: Decodable, Equatable, Sendable {
    /// 入账状态。
    nonisolated enum Status: String, Decodable, Equatable, Sendable {
        /// 本次入账。
        case credited

        /// 之前已经入账过（重传，或 Apple 的通知先到了），没有变动。
        case duplicate

        /// 交易已经退款，不入账。
        case revoked

        /// 客户端还不认识的状态；服务端返回 200 就表示交易已处理完，照样可以结束交易。
        case unknown

        init(from decoder: Decoder) throws {
            let rawValue = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: rawValue) ?? .unknown
        }
    }

    /// 入账状态。
    let status: Status

    /// 这笔交易入账的点数；已退款时为 0。
    let points: Int

    /// 操作后的余额。
    let balance: Int
}

/// 上传交易失败的原因，决定这笔交易要不要结束（finish）。
///
/// 原则：只要点数可能还没入账，就不结束交易，留着下次启动、登录或打开点数页时再传；
/// StoreKit 会一直保留没结束的交易，不会丢。
enum AIStoreUploadError: Error, Equatable {
    /// 网络、登录、服务端暂时不可用等通用错误，稍后再传。
    case billing(AIBillingAPIError)

    /// 交易是另一个芽豆账号买的；换回那个账号登录后会入账，交易要留着。
    case otherAccount

    /// 买它的账号已经注销，或不是这套环境的账号，永远入不了账；可以结束交易，用户需要找 Apple 退款。
    case unknownAccount

    /// 服务端拒绝入账（签名、环境、商品不对，或还不支持这种商品）；可能是服务端配置没跟上，交易留着等修好。
    case rejected(reason: String?)

    /// 是否应当结束这笔交易。
    var shouldFinishTransaction: Bool {
        self == .unknownAccount
    }
}
