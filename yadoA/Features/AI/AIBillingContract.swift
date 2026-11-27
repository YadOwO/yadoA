import Foundation

// 与 yado_ai `GET /v1/billing/wallet`、`GET /v1/billing/entries`、`GET /v1/models`（模型档位）、`GET`/`POST /v1/billing/check-in`（每日签到）、
// `GET /v1/billing/check-in/history`（签到日历）、`POST /v1/billing/check-in/gifts/{id}/open`（打开签到礼包）对应的数据契约，结构以服务端 openapi.json 为准。
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

/// 一批未过期的点数：每笔入账（赠送、退点、正数调整、购买）各成一批，到期后剩余点数作废，扣点先用最早过期的。
///
/// App 内购买的点数永不过期（App Store 审核指南 3.1.1），`expiresAt` 为 nil，服务端把它们排在最后、最后才用。
nonisolated struct AICreditLot: Decodable, Equatable, Sendable {
    /// 本批剩余可用点数。
    let points: Int

    /// 过期时刻；永不过期（买来的点数）时为 nil。
    let expiresAt: Date?

    /// 本批入账时的点数；服务端没有返回时为 nil。
    let originalPoints: Int?

    /// 本批的来源类型（赠送、退点、人工调整或购买）；上线有效期之前的存量点数没有来源，与服务端没有返回时都为 nil。
    let kind: AICreditEntryKind?

    /// 来源的原因标签，与流水一致，例如 `initial_grant`；没有时为 nil。
    let reason: String?

    /// 新用户赠送来自哪个产品，例如 `yadoa`；其他来源为 nil。
    let product: String?

    /// 入账时间；服务端没有返回时为 nil。
    let createdAt: Date?

    private enum CodingKeys: String, CodingKey {
        case points, expiresAt, originalPoints, kind, reason, product, createdAt
    }

    /// 逐字段创建。
    init(
        points: Int,
        expiresAt: Date?,
        originalPoints: Int? = nil,
        kind: AICreditEntryKind? = nil,
        reason: String? = nil,
        product: String? = nil,
        createdAt: Date? = nil
    ) {
        self.points = points
        self.expiresAt = expiresAt
        self.originalPoints = originalPoints
        self.kind = kind
        self.reason = reason
        self.product = product
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        points = try container.decode(Int.self, forKey: .points)
        // 服务端对永不过期的批次返回 null
        expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt).map {
            try Self.parseTime($0, forKey: .expiresAt, in: container)
        }
        originalPoints = try container.decodeIfPresent(Int.self, forKey: .originalPoints)
        kind = try container.decodeIfPresent(AICreditEntryKind.self, forKey: .kind)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        product = try container.decodeIfPresent(String.self, forKey: .product)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt).map {
            try Self.parseTime($0, forKey: .createdAt, in: container)
        }
    }

    /// 扣掉一部分点数后的同一批：只改剩余点数，来源与时间不变。
    ///
    /// - Parameter points: 新的剩余点数。
    /// - Returns: 剩余点数更新后的批次。
    func withPoints(_ points: Int) -> AICreditLot {
        AICreditLot(
            points: points,
            expiresAt: expiresAt,
            originalPoints: originalPoints,
            kind: kind,
            reason: reason,
            product: product,
            createdAt: createdAt
        )
    }

    /// 解析 ISO 8601 时间字段；格式不对时整个余额解码失败。
    ///
    /// - Parameters:
    ///   - text: 字段里的时间文本。
    ///   - key: 字段名，用于报错。
    ///   - container: 解码容器，用于报错。
    /// - Returns: 解析出的时间。
    private static func parseTime(
        _ text: String,
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Date {
        guard let date = AIBillingTimestamp.parse(text) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) 不是 ISO 8601 时间：\(text)"
            )
        }
        return date
    }
}

// MARK: - 每日签到

/// 一次签到的记录。
nonisolated struct AICheckInRecord: Decodable, Equatable, Sendable {
    /// 签到获得的点数。
    let points: Int

    /// 这天是连续签到的第几天；服务端没有返回时为 0。
    let streak: Int

    /// 签到时间。
    let createdAt: Date

    /// 这批点数的过期时刻。
    let expiresAt: Date

    private enum CodingKeys: String, CodingKey {
        case points, streak, createdAt, expiresAt
    }

    /// 逐字段创建，供测试使用。
    init(points: Int, streak: Int = 0, createdAt: Date, expiresAt: Date) {
        self.points = points
        self.streak = streak
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        points = try container.decode(Int.self, forKey: .points)
        streak = try container.decodeIfPresent(Int.self, forKey: .streak) ?? 0
        createdAt = try AICheckInTime.decode(.createdAt, in: container)
        expiresAt = try AICheckInTime.decode(.expiresAt, in: container)
    }
}

/// 补签卡的情况，签到状态里的 `protection`：每月几张、本月还剩几张、今天能不能用。
///
/// 能不能用、剩几张都由服务端算，App 只负责展示，并在签到时把用户“用不用卡”的选择告诉服务端。
nonisolated struct AICheckInProtection: Decodable, Equatable, Sendable {
    /// 每个自然月（北京时间）有几张，不累积，月初恢复；为 0 时服务端没开补签卡，界面不显示补签卡。
    let cardsPerMonth: Int

    /// 本月还剩几张。
    let cardsLeft: Int

    /// 今天签到时可以用卡保住的那天（昨天），`YYYY-MM-DD`；今天用不了卡时为 nil。
    let pendingDate: String?

    /// 补签卡是否开着：服务端每月给了卡才显示补签卡相关的内容。
    var isEnabled: Bool {
        cardsPerMonth > 0
    }

    /// 签到后的同一份情况：今天已经签了，不能再用卡；剩余张数换成签到结果带回的。
    ///
    /// - Parameter cardsLeft: 签到后本月还剩几张；服务端没有返回时沿用原来的。
    /// - Returns: `pendingDate` 清空后的情况。
    func afterCheckIn(cardsLeft: Int?) -> AICheckInProtection {
        AICheckInProtection(cardsPerMonth: cardsPerMonth, cardsLeft: cardsLeft ?? self.cardsLeft, pendingDate: nil)
    }
}

/// 点签到时问用户要不要用补签卡的依据：漏签的是哪天、能保住几天连签、本月还剩几张。
nonisolated struct AICheckInProtectionOffer: Equatable, Sendable {
    /// 漏签、可以用卡保住的那天，`YYYY-MM-DD`。
    let missedDate: String

    /// 能保住的连签天数，即前天的连签天数。
    let keptStreak: Int

    /// 本月还剩几张卡。
    let cardsLeft: Int

    /// 用卡签到后今天是连签的第几天。
    var nextStreak: Int {
        keptStreak + 1
    }
}

/// 签到状态，`GET /v1/billing/check-in` 的响应：今天签没签、当前连签天数、还没开完的礼包、各档礼包的规则与补签卡。
///
/// 连签礼包和补签卡相关的字段是后加的，服务端没有返回时取空值，界面按“没有礼包”“没有补签卡”显示。
nonisolated struct AICheckInStatus: Decodable, Equatable, Sendable {
    /// 服务端按配置时区算出的日期，`YYYY-MM-DD`。
    let date: String

    /// 今天是否已签到。
    let checkedIn: Bool

    /// 今天的签到记录；没签到时为 nil。
    let checkIn: AICheckInRecord?

    /// 每次签到可得点数的下限。
    let minPoints: Int

    /// 每次签到可得点数的上限。
    let maxPoints: Int

    /// 签到点数的有效小时数；服务端没有返回时为 nil。
    let validHours: Int?

    /// 当前连签天数：今天签了取今天的；今天没签但昨天签了取昨天的（今天签还能接上）；
    /// 昨天也没签、但今天可以用补签卡时取前天的（用卡签到还能接上）；否则为 0。
    let streak: Int

    /// 第一次签到的日期，`YYYY-MM-DD`；签到日历最早翻到这个月。从没签过时为 nil。
    let firstCheckInDate: String?

    /// 还没开完的礼包，按发放先后排列；礼包不会过期。
    let gifts: [AICheckInGift]

    /// 各档礼包的规则，按周、月、年排列；用来显示“再签几天开礼包”和礼包说明。
    let giftTiers: [AICheckInGiftRule]

    /// 补签卡；服务端没有返回（还不支持补签卡）时为 nil。
    let protection: AICheckInProtection?

    private enum CodingKeys: String, CodingKey {
        case date, checkedIn, checkIn, minPoints, maxPoints, validHours, streak, firstCheckInDate, gifts, giftTiers
        case protection
    }

    /// 逐字段创建；连签礼包和补签卡相关的字段可以省略，供测试使用。
    init(
        date: String,
        checkedIn: Bool,
        checkIn: AICheckInRecord?,
        minPoints: Int,
        maxPoints: Int,
        validHours: Int? = nil,
        streak: Int = 0,
        firstCheckInDate: String? = nil,
        gifts: [AICheckInGift] = [],
        giftTiers: [AICheckInGiftRule] = [],
        protection: AICheckInProtection? = nil
    ) {
        self.date = date
        self.checkedIn = checkedIn
        self.checkIn = checkIn
        self.minPoints = minPoints
        self.maxPoints = maxPoints
        self.validHours = validHours
        self.streak = streak
        self.firstCheckInDate = firstCheckInDate
        self.gifts = gifts
        self.giftTiers = giftTiers
        self.protection = protection
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        checkedIn = try container.decode(Bool.self, forKey: .checkedIn)
        checkIn = try container.decodeIfPresent(AICheckInRecord.self, forKey: .checkIn)
        minPoints = try container.decode(Int.self, forKey: .minPoints)
        maxPoints = try container.decode(Int.self, forKey: .maxPoints)
        validHours = try container.decodeIfPresent(Int.self, forKey: .validHours)
        streak = try container.decodeIfPresent(Int.self, forKey: .streak) ?? 0
        firstCheckInDate = try container.decodeIfPresent(String.self, forKey: .firstCheckInDate)
        gifts = try container.decodeIfPresent([AICheckInGift].self, forKey: .gifts) ?? []
        giftTiers = try container.decodeIfPresent([AICheckInGiftRule].self, forKey: .giftTiers) ?? []
        protection = try container.decodeIfPresent(AICheckInProtection.self, forKey: .protection)
    }

    /// 今天签到时可以用补签卡保住连签的情况：今天还没签、服务端给了要保住的日子、本月还有卡；用不了时为 nil。
    ///
    /// 有值时点签到先问用户用不用卡；连旧服务端拿不到补签卡信息时总是 nil，不问。
    var protectionOffer: AICheckInProtectionOffer? {
        guard !checkedIn, let protection, protection.isEnabled, protection.cardsLeft > 0,
              let missedDate = protection.pendingDate else { return nil }
        return AICheckInProtectionOffer(missedDate: missedDate, keptStreak: streak, cardsLeft: protection.cardsLeft)
    }

    /// 换掉礼包列表的同一份状态；开完的礼包不再列出。
    ///
    /// - Parameter gifts: 新的礼包列表。
    /// - Returns: 只有礼包列表不同的状态。
    func replacingGifts(_ gifts: [AICheckInGift]) -> AICheckInStatus {
        AICheckInStatus(
            date: date,
            checkedIn: checkedIn,
            checkIn: checkIn,
            minPoints: minPoints,
            maxPoints: maxPoints,
            validHours: validHours,
            streak: streak,
            firstCheckInDate: firstCheckInDate,
            gifts: gifts.filter { !$0.isFinished },
            giftTiers: giftTiers,
            protection: protection
        )
    }

    /// 某一档礼包的规则；服务端没有返回这档时为 nil。
    ///
    /// - Parameter tier: 礼包档位。
    func rule(for tier: AICheckInGiftTier) -> AICheckInGiftRule? {
        giftTiers.first { $0.tier == tier }
    }
}

/// 一次签到的结果，`POST /v1/billing/check-in` 的响应。
nonisolated struct AICheckInResult: Decodable, Equatable, Sendable {
    /// 服务端按配置时区算出的日期，`YYYY-MM-DD`。
    let date: String

    /// 获得的点数。
    let points: Int

    /// 是否抽到了高档点数（庆祝动画更隆重）。
    let isBonus: Bool

    /// 今天是否早已签过；为 true 时其余字段是当天那次签到的值，没有重复入账。
    let isDuplicate: Bool

    /// 签到后的当前余额。
    let balance: Int

    /// 这天是连续签到的第几天；服务端没有返回时为 0。
    let streak: Int

    /// 这次签到得到的礼包，可能同时有几档；当天已签过时是当天得到的礼包（带最新的打开次数）。
    let gifts: [AICheckInGift]

    /// 这次签到用补签卡保住的那天（昨天），`YYYY-MM-DD`；没用卡或服务端没有返回时为 nil。当天已签过时是当天那次的值。
    let protectedDate: String?

    /// 签到后本月还剩几张补签卡；服务端没有返回（还不支持补签卡）时为 nil。
    let cardsLeft: Int?

    /// 签到时间。
    let createdAt: Date

    /// 这批点数的过期时刻。
    let expiresAt: Date

    private enum CodingKeys: String, CodingKey {
        case date, points, isBonus, isDuplicate, balance, streak, gifts, protectedDate, cardsLeft, createdAt, expiresAt
    }

    /// 逐字段创建，供测试使用。
    init(
        date: String,
        points: Int,
        isBonus: Bool,
        isDuplicate: Bool,
        balance: Int,
        streak: Int = 0,
        gifts: [AICheckInGift] = [],
        protectedDate: String? = nil,
        cardsLeft: Int? = nil,
        createdAt: Date,
        expiresAt: Date
    ) {
        self.date = date
        self.points = points
        self.isBonus = isBonus
        self.isDuplicate = isDuplicate
        self.balance = balance
        self.streak = streak
        self.gifts = gifts
        self.protectedDate = protectedDate
        self.cardsLeft = cardsLeft
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        points = try container.decode(Int.self, forKey: .points)
        isBonus = try container.decode(Bool.self, forKey: .isBonus)
        isDuplicate = try container.decode(Bool.self, forKey: .isDuplicate)
        balance = try container.decode(Int.self, forKey: .balance)
        streak = try container.decodeIfPresent(Int.self, forKey: .streak) ?? 0
        gifts = try container.decodeIfPresent([AICheckInGift].self, forKey: .gifts) ?? []
        protectedDate = try container.decodeIfPresent(String.self, forKey: .protectedDate)
        cardsLeft = try container.decodeIfPresent(Int.self, forKey: .cardsLeft)
        createdAt = try AICheckInTime.decode(.createdAt, in: container)
        expiresAt = try AICheckInTime.decode(.expiresAt, in: container)
    }

    /// 这次签到新得到、还没开完的礼包；当天已签过时为空，免得重复弹出开礼包。
    var newGifts: [AICheckInGift] {
        isDuplicate ? [] : gifts.filter { !$0.isFinished }
    }

    /// 这次签到用补签卡保住的连签天数，即前天的连签天数；没用卡时为 nil。
    var keptStreak: Int? {
        guard protectedDate != nil else { return nil }
        return max(streak - 1, 0)
    }
}

// MARK: - 连续签到礼包

/// 连续签到礼包的档位，与 yado_ai `db/schema.ts` 的 `CHECK_IN_GIFT_TIERS` 一致；服务端以后新增的档位归入 `unknown`，不让整个签到状态解码失败。
nonisolated enum AICheckInGiftTier: String, Decodable, Equatable, Hashable, Sendable {
    /// 周礼包：每连签 7 天一个。
    case weekly

    /// 月礼包：每连签 30 天一个。
    case monthly

    /// 年度礼包：每连签 365 天一个，可以开两次。
    case yearly

    /// 客户端还不认识的档位。
    case unknown

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }

    /// 由流水或批次的原因标签反推档位，与 yado_ai `check-in.ts` 的 `CHECK_IN_GIFT_REASONS` 一致；不是签到礼包时为 nil。
    ///
    /// - Parameter reason: 原因标签，例如 `check_in_gift_weekly`。
    init?(entryReason reason: String?) {
        switch reason {
        case "check_in_gift_weekly": self = .weekly
        case "check_in_gift_monthly": self = .monthly
        case "check_in_gift_yearly": self = .yearly
        default: return nil
        }
    }

    /// 打开这档礼包入账时流水的原因标签；不认识的档位为 nil。
    var entryReason: String? {
        switch self {
        case .weekly: "check_in_gift_weekly"
        case .monthly: "check_in_gift_monthly"
        case .yearly: "check_in_gift_yearly"
        case .unknown: nil
        }
    }

    /// 礼包名称的本地化 key，例如“周礼包”。
    var titleKey: String {
        switch self {
        case .weekly: "checkIn.gift.weekly"
        case .monthly: "checkIn.gift.monthly"
        case .yearly: "checkIn.gift.yearly"
        case .unknown: "checkIn.gift.other"
        }
    }

    /// 点数明细里打开这档礼包的标题 key，例如“签到周礼包”。
    var entryTitleKey: String {
        switch self {
        case .weekly: "ai.entry.grant.weeklyGift"
        case .monthly: "ai.entry.grant.monthlyGift"
        case .yearly: "ai.entry.grant.yearlyGift"
        case .unknown: "ai.entry.grant"
        }
    }
}

/// 一个连续签到礼包。礼包不会过期，打开才入账；年度礼包可以开两次，每次打开 `openedCount` 加 1。
nonisolated struct AICheckInGift: Decodable, Equatable, Hashable, Identifiable, Sendable {
    /// 礼包 id，打开时放在请求路径里。
    let id: String

    /// 礼包档位。
    let tier: AICheckInGiftTier

    /// 得到礼包时的连签天数。
    let streak: Int

    /// 得到礼包的签到日，`YYYY-MM-DD`。
    let checkInDate: String

    /// 一共可以打开几次。
    let totalOpens: Int

    /// 已经打开的次数。
    let openedCount: Int

    /// 发放时刻。
    let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, tier, streak, checkInDate, totalOpens, openedCount, createdAt
    }

    /// 逐字段创建，供测试使用。
    init(
        id: String,
        tier: AICheckInGiftTier,
        streak: Int,
        checkInDate: String,
        totalOpens: Int,
        openedCount: Int,
        createdAt: Date
    ) {
        self.id = id
        self.tier = tier
        self.streak = streak
        self.checkInDate = checkInDate
        self.totalOpens = totalOpens
        self.openedCount = openedCount
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        tier = try container.decode(AICheckInGiftTier.self, forKey: .tier)
        streak = try container.decode(Int.self, forKey: .streak)
        checkInDate = try container.decode(String.self, forKey: .checkInDate)
        totalOpens = try container.decode(Int.self, forKey: .totalOpens)
        openedCount = try container.decode(Int.self, forKey: .openedCount)
        createdAt = try AICheckInTime.decode(.createdAt, in: container)
    }

    /// 还能打开几次。
    var remainingOpens: Int {
        max(totalOpens - openedCount, 0)
    }

    /// 是否已经开完。
    var isFinished: Bool {
        remainingOpens == 0
    }

    /// 下一次打开是第几次，从 1 开始；打开请求带上它，网络重发时服务端据此不重复入账。
    var nextSeq: Int {
        openedCount + 1
    }
}

/// 礼包某一次打开的点数范围。
nonisolated struct AICheckInGiftOpening: Decodable, Equatable, Hashable, Sendable {
    /// 最少送的点数。
    let minPoints: Int

    /// 最多送的点数。
    let maxPoints: Int
}

/// 一档礼包的规则：每连签几天发一个、每次打开的点数范围、点数有效期。
nonisolated struct AICheckInGiftRule: Decodable, Equatable, Hashable, Sendable {
    /// 礼包档位。
    let tier: AICheckInGiftTier

    /// 连签天数每到它的整数倍发一个，例如 7 表示第 7、14、21… 天各一个。
    let everyDays: Int

    /// 依次打开的次数与每次的点数范围；年度礼包有两项。
    let openings: [AICheckInGiftOpening]

    /// 每次打开得到的点数的有效期（天），从打开时刻起算。
    let validDays: Int

    /// 这档礼包所有开启次数最多能得到的点数合计，用来折算「最高价值」。
    var maxTotalPoints: Int {
        openings.reduce(0) { $0 + max($1.maxPoints, 0) }
    }

    /// 离下一个这档礼包还要签几天（含今天）。
    ///
    /// 今天签了时 `streak` 是今天的连签天数，今天没签时是昨天的；两种情况下一个礼包都在连签天数到达 `everyDays` 的下一个整数倍那天，
    /// 所以都是 `everyDays - streak % everyDays`。今天刚拿到时为 `everyDays`。
    ///
    /// - Parameter streak: 当前连签天数。
    /// - Returns: 还要签的天数；规则不合法（`everyDays` 不是正数）时为 nil。
    func daysUntilNext(streak: Int) -> Int? {
        guard everyDays > 0 else { return nil }
        return everyDays - max(streak, 0) % everyDays
    }

    /// 当前这一轮的进度，0 到 1 之间（不含 1）。
    ///
    /// - Parameter streak: 当前连签天数。
    func progress(streak: Int) -> Double {
        guard everyDays > 0 else { return 0 }
        return Double(max(streak, 0) % everyDays) / Double(everyDays)
    }
}

/// 打开一次礼包的结果，`POST /v1/billing/check-in/gifts/{id}/open` 的响应。
nonisolated struct AICheckInGiftOpenResult: Decodable, Equatable, Sendable {
    /// 打开后的礼包，`openedCount` 已更新。
    let gift: AICheckInGift

    /// 这是第几次打开。
    let seq: Int

    /// 这次送的点数。
    let points: Int

    /// 这一次早已打开过时为 true，此时点数和时间是当时那次的值，没有重复入账。
    let isDuplicate: Bool

    /// 当前余额；重复打开时也是服务端此刻的余额。
    let balance: Int

    /// 打开（到账）时刻。
    let createdAt: Date

    /// 这次点数的过期时刻。
    let expiresAt: Date

    private enum CodingKeys: String, CodingKey {
        case gift, seq, points, isDuplicate, balance, createdAt, expiresAt
    }

    /// 逐字段创建，供测试使用。
    init(
        gift: AICheckInGift,
        seq: Int,
        points: Int,
        isDuplicate: Bool,
        balance: Int,
        createdAt: Date,
        expiresAt: Date
    ) {
        self.gift = gift
        self.seq = seq
        self.points = points
        self.isDuplicate = isDuplicate
        self.balance = balance
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gift = try container.decode(AICheckInGift.self, forKey: .gift)
        seq = try container.decode(Int.self, forKey: .seq)
        points = try container.decode(Int.self, forKey: .points)
        isDuplicate = try container.decode(Bool.self, forKey: .isDuplicate)
        balance = try container.decode(Int.self, forKey: .balance)
        createdAt = try AICheckInTime.decode(.createdAt, in: container)
        expiresAt = try AICheckInTime.decode(.expiresAt, in: container)
    }
}

// MARK: - 签到日历

/// 签到日历里签过的一天。
nonisolated struct AICheckInDay: Decodable, Equatable, Sendable {
    /// 签到日，`YYYY-MM-DD`。
    let date: String

    /// 这天签到送的点数。
    let points: Int

    /// 这天是连续签到的第几天。
    let streak: Int

    /// 这天得到的礼包档位；没有为空。
    let giftTiers: [AICheckInGiftTier]
}

/// 某个月的签到日历，`GET /v1/billing/check-in/history` 的响应。
nonisolated struct AICheckInMonth: Decodable, Equatable, Sendable {
    /// 查询的月份，`YYYY-MM`。
    let month: String

    /// 服务端按配置时区算出的今天，`YYYY-MM-DD`；签到日历最晚翻到这个月。
    let today: String

    /// 第一次签到的日期；从没签过时为 nil。签到日历最早翻到这个月。
    let firstCheckInDate: String?

    /// 这个月签过的日子，按日期排列。
    let days: [AICheckInDay]

    /// 这个月里被补签卡保住的日子，`YYYY-MM-DD`，按日期排列；这些日子没有签到，只是连签没断。服务端没有返回时为空。
    let protectedDates: [String]

    private enum CodingKeys: String, CodingKey {
        case month, today, firstCheckInDate, days, protectedDates
    }

    /// 逐字段创建；补签卡保住的日子可以省略，供测试使用。
    init(month: String, today: String, firstCheckInDate: String?, days: [AICheckInDay], protectedDates: [String] = []) {
        self.month = month
        self.today = today
        self.firstCheckInDate = firstCheckInDate
        self.days = days
        self.protectedDates = protectedDates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        month = try container.decode(String.self, forKey: .month)
        today = try container.decode(String.self, forKey: .today)
        firstCheckInDate = try container.decodeIfPresent(String.self, forKey: .firstCheckInDate)
        days = try container.decode([AICheckInDay].self, forKey: .days)
        protectedDates = try container.decodeIfPresent([String].self, forKey: .protectedDates) ?? []
    }
}

/// 签到模型共用的时间解码。
private nonisolated enum AICheckInTime {
    /// 解码并解析 ISO 8601 时间字段；格式不对时抛 `DecodingError.dataCorrupted`。
    ///
    /// - Parameters:
    ///   - key: 字段名。
    ///   - container: 解码容器。
    /// - Returns: 解析出的时间。
    static func decode<Key: CodingKey>(_ key: Key, in container: KeyedDecodingContainer<Key>) throws -> Date {
        let text = try container.decode(String.self, forKey: key)
        guard let date = AIBillingTimestamp.parse(text) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) 不是 ISO 8601 时间：\(text)"
            )
        }
        return date
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

    /// App 内购买的点数，永不过期。
    case purchase

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
/// 接入新档位时在这里加一个 case，并补齐名称、图标、一句话特点与特点说明的文案。
nonisolated enum AIModelTier: String, CaseIterable, Identifiable, Sendable {
    /// 普通：速度快，每句扣的点数少。
    case standard

    /// 精准：用更强的模型，每句扣的点数多。
    case precise

    /// 用户没选过档位时本 App 用的档位：默认用精准，记账更准；服务端停用精准时才交给服务端的默认档位。
    static let appDefault: AIModelTier = .precise

    /// 选择项的稳定标识。
    var id: String { rawValue }

    /// 档位名称的本地化 key。
    var titleKey: String {
        switch self {
        case .standard: "ai.tier.standard"
        case .precise: "ai.tier.precise"
        }
    }

    /// 模型选择页上档位名称前的图标。
    var symbol: String {
        switch self {
        case .standard: "gauge.with.dots.needle.50percent"
        case .precise: "scope"
        }
    }

    /// 一句话特点的本地化 key，显示在模型选择页的档位名称下方，例如“均衡之选”。
    var summaryKey: String {
        switch self {
        case .standard: "ai.tier.standard.summary"
        case .precise: "ai.tier.precise.summary"
        }
    }

    /// 模型选择页列出的具体特点，先说优势、再说代价，方便用户在档位之间比较。
    var highlights: [AIModelTierHighlight] {
        switch self {
        case .standard:
            [
                AIModelTierHighlight(symbol: "bolt", textKey: "ai.tier.standard.speed"),
                AIModelTierHighlight(symbol: "checkmark.circle", textKey: "ai.tier.standard.fit")
            ]
        case .precise:
            [
                AIModelTierHighlight(symbol: "text.magnifyingglass", textKey: "ai.tier.precise.understanding"),
                AIModelTierHighlight(symbol: "clock", textKey: "ai.tier.precise.speed")
            ]
        }
    }
}

/// 模型档位用在哪里：快捷语音和 AI 对话各选各的，互不影响。
///
/// 快捷语音是一级页面上按住麦克风说的话，在 AI 点数页选模型；AI 对话是聊天页里说的、打的话和发的图片，在聊天页的输入栏里选。
/// 两边没选过时都用 `AIModelTier.appDefault`（精准）。
/// 两边共用同一个对话段，每句话按发出时所在的入口取档位。
nonisolated enum AIModelScope: String, CaseIterable, Identifiable, Sendable {
    /// 快捷语音：一级页面上按住麦克风说话，结果出现在会话卡片里。
    case quickVoice

    /// AI 对话：在聊天页里说、打字或发图片。
    case chat

    /// 选择项的稳定标识。
    var id: String { rawValue }

    /// 在本机保存这个入口所选档位的偏好键。
    var storageKey: String { "ai.modelTier.\(rawValue)" }

    /// 模型选择页标题与入口行名称的本地化 key。
    var titleKey: String {
        switch self {
        case .quickVoice: "ai.tier.quickVoice.title"
        case .chat: "ai.tier.chat.title"
        }
    }

    /// 说明这个模型用在哪里、另一边在哪里选的本地化 key，显示在模型选择页顶部。
    var scopeNoteKey: String {
        switch self {
        case .quickVoice: "ai.tier.quickVoice.note"
        case .chat: "ai.tier.chat.note"
        }
    }
}

/// 模型档位的一条特点：图标加一句说明，例如“响应快，说完很快就能记好”。
nonisolated struct AIModelTierHighlight: Identifiable, Equatable, Sendable {
    /// 特点前的图标。
    let symbol: String

    /// 特点说明的本地化 key；同一档位内不重复，兼作列表标识。
    let textKey: String

    var id: String { textKey }
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

    /// 用户没选过档位时实际用的档位，模型选择页给它标“默认”：本 App 的默认档位可选时用它，
    /// 否则是服务端的默认档位；客户端不认识服务端默认档位时为 nil。
    var appDefaultTier: AIModelTier? {
        selectableTiers.contains(.appDefault) ? .appDefault : AIModelTier(rawValue: defaultTier)
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

    /// 每日签到赠送的原因标签，与 yado_ai 签到发放写入的流水 reason 一致。
    static let dailyCheckInReason = "daily_check_in"

    /// App 内购买退款、扣回没用掉的点数的原因标签，与 yado_ai `shared/billing/purchases.ts` 一致。
    static let purchaseRefundReason = "app_store_refund"

    /// App 内购买的退款被 Apple 撤销、点数补回的原因标签，与 yado_ai `shared/billing/purchases.ts` 一致。
    static let purchaseRefundReversedReason = "app_store_refund_reversed"

    /// 各产品名称的本地化 key，按 yado_ai `config/billing.ts` 的 `PRODUCT_CODES`；不在这里的产品显示不带产品名的标题。
    static let productNameKeys: [String: String] = [
        "yadoa": "ai.product.yadoa"
    ]

    /// 新用户赠送来源产品名称的本地化 key；不是新用户赠送、没有产品或不认识的产品为 nil。
    var grantProductNameKey: String? {
        Self.grantProductNameKey(kind: kind, reason: reason, product: product)
    }

    /// 明细标题的本地化 key：扣点按能力区分，赠送按原因区分（新用户赠送认识来源产品时带产品名），其余按类型；
    /// 不认识的能力或原因用类型兜底。
    var titleKey: String {
        Self.titleKey(kind: kind, feature: feature, reason: reason, product: product)
    }

    /// 明细行图标。
    var symbol: String {
        Self.symbol(kind: kind, feature: feature, reason: reason)
    }

    /// 明细标题，例如“语音记账”“芽豆资产新用户赠送”。
    ///
    /// - Parameter locale: 文案使用的语言环境。
    /// - Returns: 本地化后的标题。
    func title(locale: Locale) -> String {
        Self.title(kind: kind, feature: feature, reason: reason, product: product, locale: locale)
    }

    // 下面几个按字段计算的版本供点数批次复用：批次的来源就是生成它的那条入账流水，标题与图标保持一致。

    /// 新用户赠送来源产品名称的本地化 key；不是新用户赠送、没有产品或不认识的产品为 nil。
    ///
    /// - Parameters:
    ///   - kind: 流水类型。
    ///   - reason: 原因标签。
    ///   - product: 新用户赠送来自的产品。
    static func grantProductNameKey(kind: AICreditEntryKind, reason: String?, product: String?) -> String? {
        guard kind == .grant, reason == initialGrantReason, let product else { return nil }
        return productNameKeys[product]
    }

    /// 标题的本地化 key，规则见实例属性 `titleKey`。
    ///
    /// - Parameters:
    ///   - kind: 流水类型。
    ///   - feature: 扣点所属的能力。
    ///   - reason: 原因标签。
    ///   - product: 新用户赠送来自的产品。
    static func titleKey(kind: AICreditEntryKind, feature: String?, reason: String?, product: String?) -> String {
        switch kind {
        case .charge:
            feature == voiceSessionFeature ? "ai.entry.voiceSession" : "ai.entry.charge"
        case .grant:
            if grantProductNameKey(kind: kind, reason: reason, product: product) != nil {
                "ai.entry.grant.initial.product"
            } else if reason == initialGrantReason {
                "ai.entry.grant.initial"
            } else if reason == dailyCheckInReason {
                "ai.entry.grant.dailyCheckIn"
            } else if let giftTier = AICheckInGiftTier(entryReason: reason) {
                giftTier.entryTitleKey
            } else {
                "ai.entry.grant"
            }
        case .refund:
            "ai.entry.refund"
        case .adjust:
            if reason == purchaseRefundReason {
                "ai.entry.purchaseRefund"
            } else if reason == purchaseRefundReversedReason {
                "ai.entry.purchaseRefundReversed"
            } else {
                "ai.entry.adjust"
            }
        case .expire:
            "ai.entry.expire"
        case .purchase:
            "ai.entry.purchase"
        case .unknown:
            "ai.entry.other"
        }
    }

    /// 图标。
    ///
    /// - Parameters:
    ///   - kind: 流水类型。
    ///   - feature: 扣点所属的能力。
    ///   - reason: 原因标签；每日签到的赠送用签到图标。
    static func symbol(kind: AICreditEntryKind, feature: String?, reason: String?) -> String {
        switch kind {
        case .charge:
            feature == voiceSessionFeature ? "mic" : "sparkles"
        case .grant:
            reason == dailyCheckInReason ? "calendar.badge.checkmark" : "gift"
        case .refund:
            "arrow.uturn.backward"
        case .adjust:
            reason == purchaseRefundReason || reason == purchaseRefundReversedReason ? "cart" : "slider.horizontal.3"
        case .expire:
            "hourglass"
        case .purchase:
            "cart"
        case .unknown:
            "circle.dashed"
        }
    }

    /// 本地化后的标题，新用户赠送认识来源产品时带产品名。
    ///
    /// - Parameters:
    ///   - kind: 流水类型。
    ///   - feature: 扣点所属的能力。
    ///   - reason: 原因标签。
    ///   - product: 新用户赠送来自的产品。
    ///   - locale: 文案使用的语言环境。
    static func title(
        kind: AICreditEntryKind,
        feature: String?,
        reason: String?,
        product: String?,
        locale: Locale
    ) -> String {
        let key = titleKey(kind: kind, feature: feature, reason: reason, product: product)
        guard let productKey = grantProductNameKey(kind: kind, reason: reason, product: product) else {
            return AccountLocalization.string(key, locale: locale)
        }
        return AccountLocalization.formatted(
            key,
            value: AccountLocalization.string(productKey, locale: locale),
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

extension AICreditLot {
    /// 没有来源的存量点数的标题 key：上线有效期之前的余额转成的批次。
    static let legacyTitleKey = "ai.lot.legacy"

    /// 标题的本地化 key，与生成本批的入账流水一致；没有来源时为“早期点数”。
    var titleKey: String {
        guard let kind else { return Self.legacyTitleKey }
        return AICreditEntry.titleKey(kind: kind, feature: nil, reason: reason, product: product)
    }

    /// 图标，与生成本批的入账流水一致；没有来源时用托盘。
    var symbol: String {
        guard let kind else { return "tray" }
        return AICreditEntry.symbol(kind: kind, feature: nil, reason: reason)
    }

    /// 是否是每日签到赠送的一批。
    var isDailyCheckIn: Bool {
        kind == .grant && reason == AICreditEntry.dailyCheckInReason
    }

    /// 到期时间文本：签到点数 24 小时后过期，显示到时分，其余只显示日期。
    ///
    /// - Parameter locale: 文案使用的语言环境。
    /// - Returns: 本地化后的到期时间；永不过期的批次为 nil。
    func expiryText(locale: Locale) -> String? {
        guard let expiresAt else { return nil }
        if isDailyCheckIn {
            return expiresAt.formatted(.dateTime.year().month().day().hour().minute().locale(locale))
        }
        return expiresAt.formatted(.dateTime.year().month().day().locale(locale))
    }

    /// 本地化后的标题，例如“芽豆资产新用户赠送”“退点”。
    ///
    /// - Parameter locale: 文案使用的语言环境。
    /// - Returns: 本地化后的标题。
    func title(locale: Locale) -> String {
        guard let kind else { return AccountLocalization.string(Self.legacyTitleKey, locale: locale) }
        return AICreditEntry.title(kind: kind, feature: nil, reason: reason, product: product, locale: locale)
    }
}
