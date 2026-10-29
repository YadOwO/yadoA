import Foundation

// 与 yado_ai `GET /v1/billing/wallet`、`GET /v1/billing/entries`、`GET /v1/models`（模型档位）对应的数据契约，结构以服务端 openapi.json 为准。
//
// 点数跨芽豆系列 App 共用，同一账号只有一个余额；点数是整数，不是金额。这里只解码客户端用得到的字段。
// 新用户赠送按产品各发一次：查询时带上本产品代号，服务端据此发放本产品的赠送，流水里记着赠送来自哪个产品。

// MARK: - 时间

/// 点数接口里的时间文本。
nonisolated enum AIBillingTimestamp {
    /// 解析服务端的 ISO 8601 时间；服务端用 `toISOString()` 输出，带毫秒，也兼容不带毫秒的写法。
    ///
    /// - Parameter text: 形如 `2026-10-28T02:32:00.000Z` 的时间文本。
    /// - Returns: 解析出的时间；格式不对时为 nil。
    static func parse(_ text: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(text)
    }
}

// MARK: - 余额

/// 当前账号的点数余额。
nonisolated struct AIWallet: Decodable, Equatable, Sendable {
    /// 当前点数余额，已扣除过期的点数。
    let balance: Int

    /// 各批未过期的点数，按过期时刻从早到晚，合计等于余额；服务端没有返回这个字段时为空。
    let lots: [AICreditLot]

    private enum CodingKeys: String, CodingKey {
        case balance, lots
    }

    /// 逐字段创建，供测试使用。
    init(balance: Int, lots: [AICreditLot] = []) {
        self.balance = balance
        self.lots = lots
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        balance = try container.decode(Int.self, forKey: .balance)
        lots = try container.decodeIfPresent([AICreditLot].self, forKey: .lots) ?? []
    }
}

/// 一批未过期的点数：每笔入账（赠送、退点、正数调整）各成一批，到期后剩余点数作废，扣点先用最早过期的。
nonisolated struct AICreditLot: Decodable, Equatable, Sendable {
    /// 本批剩余可用点数。
    let points: Int

    /// 过期时刻。
    let expiresAt: Date

    private enum CodingKeys: String, CodingKey {
        case points, expiresAt
    }

    /// 逐字段创建。
    init(points: Int, expiresAt: Date) {
        self.points = points
        self.expiresAt = expiresAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        points = try container.decode(Int.self, forKey: .points)
        let expiresAtText = try container.decode(String.self, forKey: .expiresAt)
        guard let expiresAt = AIBillingTimestamp.parse(expiresAtText) else {
            throw DecodingError.dataCorruptedError(
                forKey: .expiresAt,
                in: container,
                debugDescription: "expiresAt 不是 ISO 8601 时间：\(expiresAtText)"
            )
        }
        self.expiresAt = expiresAt
    }
}

// MARK: - 流水

/// 点数流水类型；服务端以后新增的类型归入 `unknown`，不让整页明细解码失败。
nonisolated enum AICreditEntryKind: String, Decodable, Equatable, Sendable {
    /// 赠送，例如新用户赠送。
    case grant

    /// 一轮 AI 对话扣点。
    case charge

    /// 退点。
    case refund

    /// 人工调整，可增可减。
    case adjust

    /// 到期作废，为负数。
    case expire

    /// 客户端还不认识的类型。
    case unknown

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }
}

/// 一条点数流水。
nonisolated struct AICreditEntry: Decodable, Equatable, Identifiable, Sendable {
    /// 流水 ID，也是分页游标。
    let id: String

    /// 流水类型。
    let kind: AICreditEntryKind

    /// 余额变动：正数增加，负数减少。
    let points: Int

    /// 本条流水生效后的余额。
    let balanceAfter: Int

    /// 扣点所属的能力，前缀为产品，例如 `yadoa.voice_session`；非扣点流水为 nil。
    let feature: String?

    /// 固定的原因标签，例如 `initial_grant`（新用户赠送）；没有时为 nil。
    let reason: String?

    /// 新用户赠送来自哪个产品，例如 `yadoa`；其他流水和服务端没有返回这个字段时为 nil。
    let product: String?

    /// 入账时间。
    let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, kind, points, balanceAfter, feature, reason, product, createdAt
    }

    /// 逐字段创建，供测试和预览使用。
    init(
        id: String,
        kind: AICreditEntryKind,
        points: Int,
        balanceAfter: Int,
        feature: String? = nil,
        reason: String? = nil,
        product: String? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.points = points
        self.balanceAfter = balanceAfter
        self.feature = feature
        self.reason = reason
        self.product = product
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(AICreditEntryKind.self, forKey: .kind)
        points = try container.decode(Int.self, forKey: .points)
        balanceAfter = try container.decode(Int.self, forKey: .balanceAfter)
        feature = try container.decodeIfPresent(String.self, forKey: .feature)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        product = try container.decodeIfPresent(String.self, forKey: .product)
        let createdAtText = try container.decode(String.self, forKey: .createdAt)
        guard let createdAt = AIBillingTimestamp.parse(createdAtText) else {
            throw DecodingError.dataCorruptedError(
                forKey: .createdAt,
                in: container,
                debugDescription: "createdAt 不是 ISO 8601 时间：\(createdAtText)"
            )
        }
        self.createdAt = createdAt
    }
}

/// 一页点数流水，按时间倒序。
nonisolated struct AICreditEntryPage: Decodable, Equatable, Sendable {
    /// 本页流水。
    let entries: [AICreditEntry]

    /// 下一页的游标；没有更多时为 nil。
    let nextCursor: String?
}

// MARK: - 模型档位

/// 客户端认识的模型档位，与 yado_ai `config/models.ts` 的 `MODEL_TIERS` 一致；服务端以后新增的档位客户端不展示。
///
/// 档位对应哪个具体模型由服务端决定，客户端只保存用户选的档位，随请求头 `X-AI-Tier` 发送。
nonisolated enum AIModelTier: String, CaseIterable, Identifiable, Sendable {
    /// 普通：速度快，每句扣的点数少。
    case standard

    /// 精准：用更强的模型，每句扣的点数多。
    case precise

    /// 在本机保存用户所选档位的偏好键。
    static let storageKey = "ai.modelTier"

    /// 选择项的稳定标识。
    var id: String { rawValue }

    /// 档位名称的本地化 key。
    var titleKey: String {
        switch self {
        case .standard: "ai.tier.standard"
        case .precise: "ai.tier.precise"
        }
    }
}

/// 模型档位列表：各档位每说一句扣的点数与服务端的默认档位。
nonisolated struct AIModelTierList: Decodable, Equatable, Sendable {
    /// 一个档位。
    nonisolated struct Tier: Decodable, Equatable, Sendable {
        /// 档位 id，例如 `standard`；客户端不认识的档位不展示。
        let id: String

        /// 使用该档位每说一句扣的点数。
        let pointsPerTurn: Int

        /// 服务端是否已配置好该档位的模型；为 false 时不让用户选。
        let isAvailable: Bool
    }

    /// 不带档位请求头时服务端使用的档位 id。
    let defaultTier: String

    /// 全部档位，按从普通到精准的顺序。
    let tiers: [Tier]

    /// 客户端认识且可用的档位，按服务端顺序，供用户选择。
    var selectableTiers: [AIModelTier] {
        tiers.compactMap { $0.isAvailable ? AIModelTier(rawValue: $0.id) : nil }
    }

    /// 某个档位每说一句扣的点数。
    ///
    /// - Parameter tierID: 档位 id。
    /// - Returns: 每轮点数；列表里没有这个档位时为 nil。
    func pointsPerTurn(for tierID: String) -> Int? {
        tiers.first { $0.id == tierID }?.pointsPerTurn
    }
}

// MARK: - 展示

extension AICreditEntry {
    /// 语音记账的能力标识，与 yado_ai `voice-session/routes.ts` 的 `FEATURE` 一致。
    static let voiceSessionFeature = "yadoa.voice_session"

    /// 新用户赠送的原因标签，与 yado_ai `shared/billing/wallet.ts` 一致。
    static let initialGrantReason = "initial_grant"

    /// 各产品名称的本地化 key，按 yado_ai `config/billing.ts` 的 `PRODUCT_CODES`；不在这里的产品显示不带产品名的标题。
    static let productNameKeys: [String: String] = [
        "yadoa": "ai.product.yadoa"
    ]

    /// 新用户赠送来源产品名称的本地化 key；不是新用户赠送、没有产品或不认识的产品为 nil。
    var grantProductNameKey: String? {
        guard kind == .grant, reason == Self.initialGrantReason, let product else { return nil }
        return Self.productNameKeys[product]
    }

    /// 明细标题的本地化 key：扣点按能力区分，赠送按原因区分（新用户赠送认识来源产品时带产品名），其余按类型；
    /// 不认识的能力或原因用类型兜底。
    var titleKey: String {
        switch kind {
        case .charge:
            feature == Self.voiceSessionFeature ? "ai.entry.voiceSession" : "ai.entry.charge"
        case .grant:
            if grantProductNameKey != nil {
                "ai.entry.grant.initial.product"
            } else if reason == Self.initialGrantReason {
                "ai.entry.grant.initial"
            } else {
                "ai.entry.grant"
            }
        case .refund:
            "ai.entry.refund"
        case .adjust:
            "ai.entry.adjust"
        case .expire:
            "ai.entry.expire"
        case .unknown:
            "ai.entry.other"
        }
    }

    /// 明细行图标。
    var symbol: String {
        switch kind {
        case .charge:
            feature == Self.voiceSessionFeature ? "mic" : "sparkles"
        case .grant:
            "gift"
        case .refund:
            "arrow.uturn.backward"
        case .adjust:
            "slider.horizontal.3"
        case .expire:
            "hourglass"
        case .unknown:
            "circle.dashed"
        }
    }

    /// 明细标题，例如“语音记账”“芽豆资产新用户赠送”。
    ///
    /// - Parameter locale: 文案使用的语言环境。
    /// - Returns: 本地化后的标题。
    func title(locale: Locale) -> String {
        guard let grantProductNameKey else {
            return AccountLocalization.string(titleKey, locale: locale)
        }
        return AccountLocalization.formatted(
            titleKey,
            value: AccountLocalization.string(grantProductNameKey, locale: locale),
            locale: locale
        )
    }

    /// 带正负号的变动点数，例如 `+100`、`-2`。
    ///
    /// - Parameter locale: 数字格式使用的语言环境。
    /// - Returns: 格式化后的点数。
    func signedPoints(locale: Locale) -> String {
        points.formatted(.number.sign(strategy: .always(includingZero: false)).locale(locale))
    }
}
