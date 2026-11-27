import Foundation

/// 订阅列表里一行的展示数据。
struct UserSubscriptionRowPresentation: Identifiable, Equatable {
    /// 订阅 UUID。
    let id: UUID

    /// 订阅名称。
    let title: String

    /// 分类图标。
    let symbolName: String

    /// 每期金额，不带正负号。
    let formattedAmount: String

    /// 副行文字：周期、下次扣费日和扣费渠道，或试用、取消的状态。
    let subtitle: String

    /// 已取消或已到期，行会变淡。
    let isInactive: Bool

    /// 是否打开了自动记账（它管理的周期记账还在）。
    let hasAutoBookkeeping: Bool
}

/// 订阅页顶部的合计和饼图数据。
struct UserSubscriptionSummary: Equatable {
    /// 平均每月的花费：只算订阅中的，年付、季付、周付都折到每个月。
    let monthlyTotal: Decimal

    /// 一年的花费。
    let yearlyTotal: Decimal

    /// 按分类分的每月花费，饼图用；最多画出配色位数那么多类，其余合并。
    let breakdown: CategoryBreakdownPresentation

    /// 有花费的分类数；只有一类时不画饼图。
    let categoryCount: Int
}

/// 把订阅转换为列表和合计的展示数据。
enum UserSubscriptionListPresentation {
    /// 生成列表行：订阅中、试用中的按下一次扣费从近到远，其次是已取消的，已到期的放最后。
    ///
    /// - Parameters:
    ///   - subscriptions: 全部订阅。
    ///   - existingRuleIDs: 本地现有周期记账规则的 UUID，用来判断自动记账是否还在。
    ///   - today: 今天的 `YYYYMMDD`。
    ///   - ledgerCurrencyCode: 当前账本币种；金额按它展示，不换算。
    ///   - locale: 语言环境。
    ///   - calendar: 日历。
    /// - Returns: 排好序的列表行。
    static func rows(
        subscriptions: [UserSubscription],
        existingRuleIDs: Set<UUID>,
        today: Int,
        ledgerCurrencyCode: String,
        locale: Locale,
        calendar: Calendar
    ) -> [UserSubscriptionRowPresentation] {
        sorted(subscriptions, today: today).map { subscription in
            let phase = subscription.phase(today: today)
            return UserSubscriptionRowPresentation(
                id: subscription.id,
                title: subscription.name,
                symbolName: subscription.category.symbolName,
                formattedAmount: subscription.amount.formattedCurrency(locale: locale, currencyCode: ledgerCurrencyCode),
                subtitle: subtitle(for: subscription, phase: phase, locale: locale, calendar: calendar),
                isInactive: phase.upcomingChargeDay == nil,
                hasAutoBookkeeping: subscription.recurringRuleID.map(existingRuleIDs.contains) ?? false
            )
        }
    }

    /// 按列表顺序排列订阅。
    ///
    /// - Parameters:
    ///   - subscriptions: 要排序的订阅。
    ///   - today: 今天的 `YYYYMMDD`。
    /// - Returns: 排好序的订阅。
    static func sorted(_ subscriptions: [UserSubscription], today: Int) -> [UserSubscription] {
        let keyed = subscriptions.map { subscription in
            (subscription: subscription, key: sortKey(subscription.phase(today: today)))
        }
        return keyed.sorted { lhs, rhs in
            if lhs.key.rank != rhs.key.rank { return lhs.key.rank < rhs.key.rank }
            if lhs.key.day != rhs.key.day { return lhs.key.day < rhs.key.day }
            if lhs.subscription.name != rhs.subscription.name { return lhs.subscription.name < rhs.subscription.name }
            return lhs.subscription.id.uuidString < rhs.subscription.id.uuidString
        }
        .map(\.subscription)
    }

    /// 排序依据：先按状态分组，组内按日子从近到远。
    private static func sortKey(_ phase: UserSubscriptionPhase) -> (rank: Int, day: Int) {
        switch phase {
        case let .active(day): (rank: 0, day: day)
        case let .trial(day): (rank: 0, day: day)
        case let .cancelled(accessEndDay): (rank: 1, day: accessEndDay ?? Int.max)
        case .expired: (rank: 2, day: 0)
        case .unknown: (rank: 3, day: 0)
        }
    }

    /// 合计和饼图：只算订阅中的（试用中、已取消的不算），没有在扣费的订阅时为 `nil`。
    ///
    /// - Parameters:
    ///   - subscriptions: 全部订阅。
    ///   - today: 今天的 `YYYYMMDD`。
    ///   - locale: 合并项名称使用的语言环境。
    /// - Returns: 合计和饼图数据。
    static func summary(
        subscriptions: [UserSubscription],
        today: Int,
        locale: Locale
    ) -> UserSubscriptionSummary? {
        var yearlyByCategory: [UserSubscriptionCategory: Decimal] = [:]
        for subscription in subscriptions where subscription.phase(today: today).isCharging {
            guard let frequency = subscription.frequency else { continue }
            yearlyByCategory[subscription.category, default: 0] += UserSubscriptionSchedule.yearlyAmount(
                subscription.amount,
                frequency: frequency
            )
        }
        let yearlyTotal = yearlyByCategory.values.reduce(Decimal.zero, +)
        guard yearlyTotal > 0 else { return nil }

        let items = UserSubscriptionCategory.allCases.compactMap { category -> CategoryRankingItem? in
            guard let yearly = yearlyByCategory[category], yearly > 0 else { return nil }
            return CategoryRankingItem(
                id: category.rawValue,
                title: AccountLocalization.string(category.titleKey, locale: locale),
                symbolName: category.symbolName,
                amount: yearly / 12
            )
        }
        return UserSubscriptionSummary(
            monthlyTotal: yearlyTotal / 12,
            yearlyTotal: yearlyTotal,
            breakdown: CategoryBreakdownPresentation(
                items: items,
                locale: locale,
                maxSegments: ChartPalette.slotCount,
                remainingTitleKey: "chart.category.remaining"
            ),
            categoryCount: items.count
        )
    }

    /// 副行文字；语音结果里订阅那一行的说明也用它。
    static func subtitle(
        for subscription: UserSubscription,
        phase: UserSubscriptionPhase,
        locale: Locale,
        calendar: Calendar
    ) -> String {
        func text(_ key: String) -> String {
            AccountLocalization.string(key, locale: locale)
        }
        func day(_ value: Int) -> String {
            TransactionDay.date(from: value, calendar: calendar, locale: locale)
                .map { BookkeepingDateFormatting.shortDate($0, locale: locale, calendar: calendar) } ?? ""
        }
        let channel = text(subscription.channel.titleKey)
        let parts: [String]
        switch phase {
        case let .active(nextChargeDay):
            parts = [
                subscription.frequency.map { text($0.titleKey) },
                AccountLocalization.formatted("subscription.row.next_charge", value: day(nextChargeDay), locale: locale),
                channel,
            ].compactMap { $0 }
        case let .trial(endDay):
            parts = [
                AccountLocalization.formatted("subscription.row.trial_until", value: day(endDay), locale: locale),
                channel,
            ]
        case let .cancelled(accessEndDay):
            parts = [
                text("subscription.status.cancelled"),
                accessEndDay.map {
                    AccountLocalization.formatted("subscription.row.access_until", value: day($0), locale: locale)
                },
            ].compactMap { $0 }
        case .expired:
            parts = [text("subscription.row.expired")]
        case .unknown:
            parts = [channel]
        }
        return parts.joined(separator: " · ")
    }
}
