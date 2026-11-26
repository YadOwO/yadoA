import Foundation

// 与 yado_hub `/v1/links/*`（数据联动用户端）对应的数据契约，结构以服务端 openapi.json 为准。
//
// 数据联动：用户在芽豆资产里授权后，hub 用机器凭证向芽豆有物（yadoI_be）要这个用户的物品购入价汇总，
// 只有合计与件数，没有任何物品明细。金额在接口里是两位小数的字符串，不用 JSON number，避免浮点误差。

// MARK: - 代号

/// 联动的产品与数据范围代号，与 yado_hub 一致；路径里的 `yadoi/yadoa` 和 `scope` 都来自这里。
nonisolated enum DataLinkCode {
    /// 数据来源：芽豆有物。
    static let source = "yadoi"

    /// 数据使用方：芽豆资产（本 App）。
    static let target = "yadoa"

    /// 授权的数据范围：物品购入价汇总。
    static let scope = "item_value_summary"
}

// MARK: - 授权状态

/// 一项联动授权的状态（`GET /v1/links` 的一项，也是授权、取消授权的返回）。
nonisolated struct DataLinkStatus: Decodable, Equatable {
    /// 数据来源的产品代号，例如 `yadoi`。
    let source: String

    /// 数据使用方的产品代号，例如 `yadoa`。
    let target: String

    /// 授权的数据范围，例如 `item_value_summary`。
    let scope: String

    /// 当前用户是否已授权。
    let granted: Bool

    /// 最近一次授权生效的时刻；未授权时为 nil。
    let grantedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case source, target, scope, granted, grantedAt
    }

    /// 逐字段创建，供测试和本机更新状态使用。
    init(
        source: String = DataLinkCode.source,
        target: String = DataLinkCode.target,
        scope: String = DataLinkCode.scope,
        granted: Bool,
        grantedAt: Date? = nil
    ) {
        self.source = source
        self.target = target
        self.scope = scope
        self.granted = granted
        self.grantedAt = grantedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(String.self, forKey: .source)
        target = try container.decode(String.self, forKey: .target)
        scope = try container.decode(String.self, forKey: .scope)
        granted = try container.decode(Bool.self, forKey: .granted)
        if let text = try container.decodeIfPresent(String.self, forKey: .grantedAt) {
            guard let date = AIBillingTimestamp.parse(text) else {
                throw DecodingError.dataCorruptedError(forKey: .grantedAt, in: container, debugDescription: "不是 ISO 8601 时间：\(text)")
            }
            grantedAt = date
        } else {
            grantedAt = nil
        }
    }
}

/// 联动列表（`GET /v1/links`）：只含服务端打开的来源，没打开任何来源时为空。
nonisolated struct DataLinkList: Decodable, Equatable {
    /// 当前打开的联动及用户是否已授权。
    let links: [DataLinkStatus]
}

// MARK: - 物品购入价汇总

/// 芽豆有物物品的购入价汇总（`GET /v1/links/yadoi/yadoa/item-value-summary`），同一个类型也当本机缓存用。
///
/// 口径：只算在用和退役、未删除的物品；没填购入价的只计入 `unpricedItemCount`，填了 0 元算有价。
/// 解码时金额从字符串转成 `Decimal`，不是字符串（例如写成 number）或格式不对都按契约不符处理；
/// 编码时把金额和时间写回字符串，缓存读出来与原来相等。
nonisolated struct ItemValueSummary: Codable, Equatable {
    /// 在用物品的购入价合计。
    let inServicePurchaseTotal: Decimal

    /// 退役物品的购入价合计。
    let retiredPurchaseTotal: Decimal

    /// 填了购入价的物品件数。
    let pricedItemCount: Int

    /// 没填购入价的物品件数。
    let unpricedItemCount: Int

    /// 这批物品里最近一次更新的时刻；没有物品时为 nil。这次只解码和缓存，不显示。
    let lastItemUpdatedAt: Date?

    /// hub 取到这份汇总的时刻。
    let fetchedAt: Date

    private enum CodingKeys: String, CodingKey {
        case inServicePurchaseTotal, retiredPurchaseTotal, pricedItemCount, unpricedItemCount, lastItemUpdatedAt, fetchedAt
    }

    /// 逐字段创建，供测试使用。
    init(
        inServicePurchaseTotal: Decimal,
        retiredPurchaseTotal: Decimal,
        pricedItemCount: Int,
        unpricedItemCount: Int,
        lastItemUpdatedAt: Date? = nil,
        fetchedAt: Date
    ) {
        self.inServicePurchaseTotal = inServicePurchaseTotal
        self.retiredPurchaseTotal = retiredPurchaseTotal
        self.pricedItemCount = pricedItemCount
        self.unpricedItemCount = unpricedItemCount
        self.lastItemUpdatedAt = lastItemUpdatedAt
        self.fetchedAt = fetchedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inServicePurchaseTotal = try Self.decodeMoney(from: container, forKey: .inServicePurchaseTotal)
        retiredPurchaseTotal = try Self.decodeMoney(from: container, forKey: .retiredPurchaseTotal)
        pricedItemCount = try container.decode(Int.self, forKey: .pricedItemCount)
        unpricedItemCount = try container.decode(Int.self, forKey: .unpricedItemCount)
        if let text = try container.decodeIfPresent(String.self, forKey: .lastItemUpdatedAt) {
            lastItemUpdatedAt = try Self.parseTimestamp(text, forKey: .lastItemUpdatedAt, in: container)
        } else {
            lastItemUpdatedAt = nil
        }
        fetchedAt = try Self.parseTimestamp(
            try container.decode(String.self, forKey: .fetchedAt),
            forKey: .fetchedAt,
            in: container
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.moneyString(inServicePurchaseTotal), forKey: .inServicePurchaseTotal)
        try container.encode(Self.moneyString(retiredPurchaseTotal), forKey: .retiredPurchaseTotal)
        try container.encode(pricedItemCount, forKey: .pricedItemCount)
        try container.encode(unpricedItemCount, forKey: .unpricedItemCount)
        try container.encodeIfPresent(lastItemUpdatedAt.map(Self.timestampString), forKey: .lastItemUpdatedAt)
        try container.encode(Self.timestampString(fetchedAt), forKey: .fetchedAt)
    }

    /// 从字符串字段解出金额；用 POSIX 区域按「.」解析小数，不受用户语言影响。
    private static func decodeMoney(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> Decimal {
        let text = try container.decode(String.self, forKey: key)
        guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "不是金额：\(text)")
        }
        return value
    }

    /// 解析 ISO 8601 时间，失败时抛出 `DecodingError`。
    private static func parseTimestamp(
        _ text: String,
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Date {
        guard let date = AIBillingTimestamp.parse(text) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "不是 ISO 8601 时间：\(text)")
        }
        return date
    }

    /// 金额写回字符串；`Decimal` 的文本表示固定用「.」，不受区域影响。
    private static func moneyString(_ value: Decimal) -> String {
        "\(value)"
    }

    /// 时间写回 ISO 8601 字符串（UTC，带毫秒），与服务端的写法一致，读回来不丢精度。
    private static func timestampString(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}
