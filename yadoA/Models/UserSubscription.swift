import Foundation
import SwiftData

/// 订阅的固定分类；rawValue 持久化并参与同步，只能新增不能改名。
///
/// 分类不让用户改：订阅页的饼图按它分块，分类少而固定才看得清。
enum UserSubscriptionCategory: String, CaseIterable, Identifiable, Sendable {
    /// 影音：视频、音乐、播客等。
    case media

    /// AI 服务。
    case ai

    /// 软件工具。
    case software

    /// 云存储。
    case cloud

    /// 生活会员：外卖、出行、购物会员等。
    case membership

    /// 其他。
    case other

    /// SwiftUI 选择器使用稳定值作为标识。
    var id: String { rawValue }

    /// 分类名称的本地化键。
    var titleKey: String { "subscription.category.\(rawValue)" }

    /// 分类图标。
    var symbolName: String {
        switch self {
        case .media: "play.rectangle"
        case .ai: "sparkles"
        case .software: "wrench.and.screwdriver"
        case .cloud: "icloud"
        case .membership: "ticket"
        case .other: "square.grid.2x2"
        }
    }

    /// 打开自动记账时建议的支出分类；预置分类被删掉时用 `defaultExpenseCategoryKey(in:)` 换成默认分类。
    var suggestedExpenseCategoryKey: String {
        switch self {
        case .media, .membership: ExpenseCategory.entertainment.rawValue
        case .ai, .software, .cloud, .other: BookkeepingCategoryKey.other
        }
    }

    /// 打开自动记账时预选的支出分类：编辑页和语音共用。
    ///
    /// - Parameter catalog: 当前分类目录。
    /// - Returns: 建议的分类还在目录里时用它，否则用目录的默认支出分类。
    func defaultExpenseCategoryKey(in catalog: BookkeepingCategoryCatalog) -> String {
        let suggested = suggestedExpenseCategoryKey
        return catalog.items(for: .expense).contains { $0.key == suggested }
            ? suggested
            : catalog.defaultKey(for: .expense)
    }
}

/// 订阅从哪里扣费；rawValue 持久化并参与同步，只能新增不能改名。
///
/// 用户想取消订阅时，一看就知道去哪里退。
enum UserSubscriptionChannel: String, CaseIterable, Identifiable, Sendable {
    /// App Store，可以跳到系统的订阅管理页。
    case appStore

    /// Google Play。
    case googlePlay

    /// 官网绑定的信用卡或借记卡。
    case card

    /// 支付宝。
    case alipay

    /// 微信支付。
    case wechat

    /// 其他。
    case other

    /// SwiftUI 选择器使用稳定值作为标识。
    var id: String { rawValue }

    /// 渠道名称的本地化键。
    var titleKey: String { "subscription.channel.\(rawValue)" }

    /// App Store 的订阅管理页；系统会在 App Store 里打开它。
    static let appStoreManagementURL = URL(string: "https://apps.apple.com/account/subscriptions")
}

/// 用户选的订阅状态；rawValue 持久化并参与同步，只能新增不能改名。
enum UserSubscriptionStatus: String, CaseIterable, Identifiable, Sendable {
    /// 订阅中，按周期扣费。
    case active

    /// 试用中：试用结束那天开始扣费，`anchorDay` 就是试用结束日。
    case trial

    /// 已取消，不再扣费；`accessEndDay` 是还能用到的那天。
    case cancelled

    /// SwiftUI 选择器使用稳定值作为标识。
    var id: String { rawValue }

    /// 状态名称的本地化键。
    var titleKey: String { "subscription.status.\(rawValue)" }
}

/// 订阅在某一天的实际状态：试用过了结束日就按订阅中算，取消后过了可用日期就算到期。
enum UserSubscriptionPhase: Equatable, Sendable {
    /// 订阅中，下一次扣费在这一天。
    case active(nextChargeDay: Int)

    /// 试用中，这一天试用结束并开始扣费。
    case trial(endDay: Int)

    /// 已取消，还能用到这一天；为 `nil` 表示没填。
    case cancelled(accessEndDay: Int?)

    /// 已取消，并且过了可用日期。
    case expired

    /// 频率或状态是不认识的值（新版本同步来的），只展示不计算。
    case unknown

    /// 是否在扣费：只有订阅中的才算进每月合计和饼图。
    var isCharging: Bool {
        if case .active = self { return true }
        return false
    }

    /// 下一次扣费的日子；试用中是试用结束日，已取消和到期的没有。
    var upcomingChargeDay: Int? {
        switch self {
        case let .active(day): day
        case let .trial(day): day
        case .cancelled, .expired, .unknown: nil
        }
    }
}

/// 订阅的排期和金额折算；日期只处理 `YYYYMMDD` 整数，排期规则与周期记账一致。
enum UserSubscriptionSchedule {
    /// 订阅可选的扣费周期；同步来的其他频率照样能算。
    static let cycles: [RecurringFrequency] = [.weekly, .monthly, .quarterly, .yearly]

    /// 不早于某天的第一次扣费。
    ///
    /// 按月、按年的日子从 `anchorDay` 推算，当月没有这一天时取月末，与周期记账相同。
    ///
    /// - Parameters:
    ///   - today: 起算日的 `YYYYMMDD`。
    ///   - anchorDay: 排期起始的扣费日。
    ///   - frequency: 扣费周期。
    /// - Returns: 扣费日；起始日晚于 `today` 时就是起始日。
    static func nextChargeDay(onOrAfter today: Int, anchorDay: Int, frequency: RecurringFrequency) -> Int {
        RecurringSchedule.firstDay(onOrAfter: today, from: anchorDay, frequency: frequency, anchorDay: anchorDay)
    }

    /// 从某次扣费开始往后的几次扣费，供扣费提醒使用。
    ///
    /// - Parameters:
    ///   - first: 第一次扣费的 `YYYYMMDD`，包含在结果里。
    ///   - count: 最多几次。
    ///   - anchorDay: 排期起始的扣费日。
    ///   - frequency: 扣费周期。
    /// - Returns: 按时间排列的扣费日。
    static func chargeDays(from first: Int, count: Int, anchorDay: Int, frequency: RecurringFrequency) -> [Int] {
        var days: [Int] = []
        var current = first
        while days.count < count {
            days.append(current)
            guard let next = RecurringSchedule.day(after: current, frequency: frequency, anchorDay: anchorDay),
                  next > current
            else { break }
            current = next
        }
        return days
    }

    /// 把每期金额折算成一年的花费；周按 52 周、两周按 26 期、天按 365 天算。
    ///
    /// - Parameters:
    ///   - amount: 每期金额。
    ///   - frequency: 扣费周期。
    /// - Returns: 一年的花费。
    static func yearlyAmount(_ amount: Decimal, frequency: RecurringFrequency) -> Decimal {
        switch frequency {
        case .daily: amount * 365
        case .weekly: amount * 52
        case .biweekly: amount * 26
        case .monthly: amount * 12
        case .quarterly: amount * 4
        case .yearly: amount
        }
    }

    /// 把每期金额折算成平均每月的花费：一年的花费除以 12，年付的也摊到每个月。
    ///
    /// - Parameters:
    ///   - amount: 每期金额。
    ///   - frequency: 扣费周期。
    /// - Returns: 平均每月的花费，不取整，展示时再按币种格式化。
    static func monthlyAmount(_ amount: Decimal, frequency: RecurringFrequency) -> Decimal {
        yearlyAmount(amount, frequency: frequency) / 12
    }

    /// 改成「已取消」时预填的可用日期：下一次扣费的前一天，也就是已付费周期的最后一天。
    ///
    /// - Parameters:
    ///   - chargeDay: 下一次扣费（试用中是试用结束）的 `YYYYMMDD`。
    ///   - calendar: 日期运算使用的日历。
    /// - Returns: 前一天；日期无效时原样返回。
    static func defaultAccessEndDay(beforeChargeDay chargeDay: Int, calendar: Calendar) -> Int {
        guard let date = TransactionDay.date(from: chargeDay, calendar: calendar),
              let previous = calendar.date(byAdding: .day, value: -1, to: date)
        else { return chargeDay }
        return TransactionDay.encode(previous, calendar: calendar)
    }
}

/// 扣费提醒可选的提前天数。
enum UserSubscriptionReminderOption {
    /// 编辑页可选的提前天数；不提醒存为 `nil`。
    static let daysBefore: [Int] = [1, 3, 7]

    /// 同步或备份里允许的提前天数范围，比编辑页宽一些，给以后加选项留余地。
    static let validRange = 0 ... 30
}

/// SwiftData 中持久化的一条订阅：记清楚订了什么、多少钱、哪天扣、从哪扣。
///
/// 订阅本身不生成流水；打开「自动记账」时由它创建并管理一条周期记账规则（`recurringRuleID`），
/// 流水由那条规则生成。规则见 `docs/rules/subscription-rules.md`。
@Model
final class UserSubscription {
    /// 跨设备保持稳定的订阅标识。
    @Attribute(.unique) var id: UUID

    /// 订阅名称，例如「ChatGPT Plus」。
    var name: String

    /// 每期的正数金额，按账本币种记，最多两位小数。
    var amount: Decimal

    /// `RecurringFrequency.rawValue` 的持久化值；未知值只展示不计算。
    var frequencyRawValue: String

    /// 排期起始的扣费日 `YYYYMMDD`；试用中时是试用结束日。
    var anchorDay: Int

    /// `UserSubscriptionCategory.rawValue` 的持久化值；未知值按「其他」展示。
    var categoryRawValue: String

    /// `UserSubscriptionChannel.rawValue` 的持久化值；未知值按「其他」展示。
    var channelRawValue: String

    /// `UserSubscriptionStatus.rawValue` 的持久化值。
    var statusRawValue: String

    /// 已取消时还能用到的那天 `YYYYMMDD`；没填或未取消时为空。
    var accessEndDay: Int?

    /// 提前几天提醒扣费；为空表示不提醒。
    var reminderDaysBefore: Int?

    /// 可选备注。
    var note: String?

    /// 自动记账时由订阅管理的周期记账规则；为空表示不自动记账。规则可能已被删掉，读取时要判空。
    var recurringRuleID: UUID?

    /// 创建时间。
    var createdAt: Date

    /// 用户最近一次修改的时间。
    var updatedAt: Date

    /// 已知持久化值对应的扣费周期；未知值返回 `nil`。
    var frequency: RecurringFrequency? {
        RecurringFrequency(rawValue: frequencyRawValue)
    }

    /// 已知持久化值对应的状态；未知值返回 `nil`。
    var status: UserSubscriptionStatus? {
        UserSubscriptionStatus(rawValue: statusRawValue)
    }

    /// 分类；未知值按「其他」。
    var category: UserSubscriptionCategory {
        UserSubscriptionCategory(rawValue: categoryRawValue) ?? .other
    }

    /// 扣费渠道；未知值按「其他」。
    var channel: UserSubscriptionChannel {
        UserSubscriptionChannel(rawValue: channelRawValue) ?? .other
    }

    /// 直接构造已完成校验的持久化订阅。
    init(
        id: UUID,
        name: String,
        amount: Decimal,
        frequencyRawValue: String,
        anchorDay: Int,
        categoryRawValue: String,
        channelRawValue: String,
        statusRawValue: String,
        accessEndDay: Int?,
        reminderDaysBefore: Int?,
        note: String?,
        recurringRuleID: UUID?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.amount = amount
        self.frequencyRawValue = frequencyRawValue
        self.anchorDay = anchorDay
        self.categoryRawValue = categoryRawValue
        self.channelRawValue = channelRawValue
        self.statusRawValue = statusRawValue
        self.accessEndDay = accessEndDay
        self.reminderDaysBefore = reminderDaysBefore
        self.note = note
        self.recurringRuleID = recurringRuleID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 用已校验的值覆盖除稳定标识外的全部持久化字段；恢复备份和应用同步记录时使用。
    func overwrite(with other: UserSubscription) {
        name = other.name
        amount = other.amount
        frequencyRawValue = other.frequencyRawValue
        anchorDay = other.anchorDay
        categoryRawValue = other.categoryRawValue
        channelRawValue = other.channelRawValue
        statusRawValue = other.statusRawValue
        accessEndDay = other.accessEndDay
        reminderDaysBefore = other.reminderDaysBefore
        note = other.note
        recurringRuleID = other.recurringRuleID
        createdAt = other.createdAt
        updatedAt = other.updatedAt
    }

    /// 订阅在某一天的实际状态。
    ///
    /// - Parameter today: 今天的 `YYYYMMDD`。
    /// - Returns: 试用过了结束日按订阅中算；取消后过了可用日期算到期。
    func phase(today: Int) -> UserSubscriptionPhase {
        guard let status, let frequency else { return .unknown }
        switch status {
        case .trial where today < anchorDay:
            return .trial(endDay: anchorDay)
        case .active, .trial:
            return .active(
                nextChargeDay: UserSubscriptionSchedule.nextChargeDay(
                    onOrAfter: today,
                    anchorDay: anchorDay,
                    frequency: frequency
                )
            )
        case .cancelled:
            if let accessEndDay, accessEndDay < today { return .expired }
            return .cancelled(accessEndDay: accessEndDay)
        }
    }
}

/// 自动记账的设置：记到哪个账户、哪个支出分类。
struct UserSubscriptionBookkeeping: Equatable, Sendable {
    /// 记入账户的 UUID。
    let accountID: UUID

    /// 支出分类 key。
    let categoryKey: String
}

/// 新建或修改一条订阅时提交的内容。
struct UserSubscriptionInput: Equatable, Sendable {
    /// 订阅 UUID；已存在时修改，否则新建。
    let id: UUID

    /// 名称，首尾空白会被去掉。
    let name: String

    /// 每期金额。
    let amount: Decimal

    /// 扣费周期。
    let frequency: RecurringFrequency

    /// 表单上的日期：订阅中是下一次扣费日，试用中是试用结束日；已取消时沿用原值。
    let chargeDay: Int

    /// 分类。
    let category: UserSubscriptionCategory

    /// 扣费渠道。
    let channel: UserSubscriptionChannel

    /// 状态。
    let status: UserSubscriptionStatus

    /// 已取消时还能用到的那天。
    let accessEndDay: Int?

    /// 提前几天提醒扣费；为空表示不提醒。
    let reminderDaysBefore: Int?

    /// 备注，空白会被清理。
    let note: String

    /// 自动记账设置；为空表示不自动记账。
    let bookkeeping: UserSubscriptionBookkeeping?

    /// 关掉自动记账时是否同时删掉原来那条周期记账；`false` 时它留下来变成普通的周期记账。
    let deletesRuleWhenUnlinking: Bool
}
