import Foundation
import SwiftData
import UserNotifications

/// 订阅扣费提醒的排期规则：在扣费日前几天的上午提醒，试用中的在试用结束前提醒。
enum UserSubscriptionReminder {
    /// 订阅提醒通知标识的前缀；重排时按它找出全部旧提醒，不碰每日记账提醒。
    static let identifierPrefix = "subscription.reminder."

    /// 提醒在当天几点发出。
    static let fireHour = 9

    /// 每条订阅最多排几次扣费：只排下一次的话，一个月没打开 App，第二个月就收不到了。
    static let chargesPerSubscription = 2

    /// 一次最多排多少条，给每日记账提醒（14 条）留出系统 64 条的余量。
    static let maxScheduled = 40

    /// 排好的一条提醒。
    struct Plan: Equatable {
        /// 订阅 UUID。
        let subscriptionID: UUID

        /// 订阅名称。
        let name: String

        /// 每期金额。
        let amount: Decimal

        /// 这次扣费（或试用结束）的 `YYYYMMDD`。
        let chargeDay: Int

        /// 这一天是不是试用结束日。
        let isTrialEnd: Bool

        /// 发出提醒的时刻。
        let fireDate: Date

        /// 交给系统的日历触发条件。
        let fireComponents: DateComponents

        /// 通知标识，同一条订阅的同一次扣费总是同一个标识。
        var identifier: String {
            "\(UserSubscriptionReminder.identifierPrefix)\(subscriptionID.uuidString.lowercased()).\(chargeDay)"
        }
    }

    /// 计算要排的提醒：开了提醒的订阅中、试用中的订阅，各取接下来几次扣费，提醒时刻已过的跳过。
    ///
    /// - Parameters:
    ///   - subscriptions: 全部订阅。
    ///   - now: 当前时刻。
    ///   - calendar: 用户当前日历。
    /// - Returns: 按提醒时刻排好的提醒，最多 `maxScheduled` 条。
    static func plans(for subscriptions: [UserSubscription], now: Date, calendar: Calendar) -> [Plan] {
        let today = TransactionDay.encode(now, calendar: calendar)
        var plans: [Plan] = []
        for subscription in subscriptions {
            guard let daysBefore = subscription.reminderDaysBefore,
                  let frequency = subscription.frequency
            else { continue }
            let phase = subscription.phase(today: today)
            guard let first = phase.upcomingChargeDay else { continue }
            let chargeDays = UserSubscriptionSchedule.chargeDays(
                from: first,
                count: chargesPerSubscription,
                anchorDay: subscription.anchorDay,
                frequency: frequency
            )
            for chargeDay in chargeDays {
                guard let chargeDate = TransactionDay.date(from: chargeDay, calendar: calendar),
                      let fireDay = calendar.date(byAdding: .day, value: -daysBefore, to: chargeDate),
                      let fireDate = calendar.date(bySettingHour: fireHour, minute: 0, second: 0, of: fireDay),
                      fireDate > now
                else { continue }
                var components = calendar.dateComponents([.year, .month, .day], from: fireDay)
                components.hour = fireHour
                components.minute = 0
                var isTrialEnd = false
                if case .trial = phase, chargeDay == first {
                    isTrialEnd = true
                }
                plans.append(
                    Plan(
                        subscriptionID: subscription.id,
                        name: subscription.name,
                        amount: subscription.amount,
                        chargeDay: chargeDay,
                        isTrialEnd: isTrialEnd,
                        fireDate: fireDate,
                        fireComponents: components
                    )
                )
            }
        }
        let sorted = plans.sorted { lhs, rhs in
            lhs.fireDate == rhs.fireDate ? lhs.identifier < rhs.identifier : lhs.fireDate < rhs.fireDate
        }
        return Array(sorted.prefix(maxScheduled))
    }
}

/// 与系统通知中心打交道的部分：重排订阅的扣费提醒。权限请求复用 `BookkeepingReminderScheduler`。
@MainActor
enum UserSubscriptionReminderScheduler {
    /// 按当前订阅重排扣费提醒：先清掉已排好的订阅提醒，有权限时重新排。
    ///
    /// App 回到前台、进入后台和保存、删除订阅后都调用，所以同步来的改动、恢复备份和清空数据也会跟上。
    ///
    /// - Parameters:
    ///   - container: 读取订阅的本地财务容器。
    ///   - locale: 通知文案使用的语言环境。
    ///   - calendar: 用户当前日历。
    ///   - now: 当前时刻。
    static func reschedule(
        container: ModelContainer,
        locale: Locale,
        calendar: Calendar,
        now: Date = .now
    ) async {
        let center = UNUserNotificationCenter.current()
        let stale = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(UserSubscriptionReminder.identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: stale)

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let subscriptions = (try? container.makeManualSaveContext().fetch(FetchDescriptor<UserSubscription>())) ?? []
        let plans = UserSubscriptionReminder.plans(for: subscriptions, now: now, calendar: calendar)
        for plan in plans {
            let content = UNMutableNotificationContent()
            content.title = AccountLocalization.string(
                plan.isTrialEnd ? "subscription.reminder.notification.trial_title" : "subscription.reminder.notification.title",
                locale: locale
            )
            content.body = body(for: plan, locale: locale, calendar: calendar)
            content.sound = .default
            try? await center.add(
                UNNotificationRequest(
                    identifier: plan.identifier,
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: plan.fireComponents, repeats: false)
                )
            )
        }
    }

    /// 通知正文：哪条订阅、哪天、扣多少。
    private static func body(for plan: UserSubscriptionReminder.Plan, locale: Locale, calendar: Calendar) -> String {
        let day = TransactionDay.date(from: plan.chargeDay, calendar: calendar, locale: locale)
            .map { BookkeepingDateFormatting.shortDate($0, locale: locale, calendar: calendar) } ?? ""
        let key = plan.isTrialEnd
            ? "subscription.reminder.notification.trial_body"
            : "subscription.reminder.notification.body"
        return String(
            format: AccountLocalization.string(key, locale: locale),
            locale: locale,
            plan.name,
            day,
            plan.amount.formattedCurrency(locale: locale)
        )
    }
}
