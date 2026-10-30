import Foundation
import SwiftData
import UserNotifications

/// 每日记账提醒的偏好与排期规则。
enum BookkeepingReminder {
    /// 提醒开关的存储键，默认关闭。
    static let isEnabledKey = "reminder.isEnabled"

    /// 提醒时间的存储键，值为从 0 点开始的分钟数。
    static let minutesKey = "reminder.minutes"

    /// 默认提醒时间：晚上 9 点。
    static let defaultMinutes = 21 * 60

    /// 一次排好的提醒天数。不用系统的每日重复：那样无法跳过已经记过账的今天；
    /// 排满后如果这么多天都没打开 App，也就不再继续打扰。
    static let scheduledDays = 14

    /// 第几天的提醒使用的通知标识。
    ///
    /// - Parameter index: 从 0 开始的序号。
    static func identifier(at index: Int) -> String {
        "bookkeeping.reminder.\(index)"
    }

    /// 计算接下来要提醒的时刻：今天已经过了提醒时间或已经记过账时从明天开始。
    ///
    /// - Parameters:
    ///   - now: 当前时刻。
    ///   - minutes: 从 0 点开始的提醒时间。
    ///   - hasEntryToday: 今天是否已经手动或用语音记过账。
    ///   - calendar: 用户当前日历。
    /// - Returns: 按时间排列的提醒时刻，最多 `scheduledDays` 个。
    static func fireComponents(
        now: Date,
        minutes: Int,
        hasEntryToday: Bool,
        calendar: Calendar
    ) -> [DateComponents] {
        let hour = minutes / 60
        let minute = minutes % 60
        let today = calendar.startOfDay(for: now)
        var components: [DateComponents] = []
        var offset = 0
        while components.count < scheduledDays, offset <= scheduledDays {
            defer { offset += 1 }
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let fireDate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
            else { continue }
            if offset == 0, hasEntryToday || fireDate <= now { continue }
            var fire = calendar.dateComponents([.year, .month, .day], from: day)
            fire.hour = hour
            fire.minute = minute
            components.append(fire)
        }
        return components
    }
}

/// 与系统通知中心打交道的部分：请求权限和重排提醒。
@MainActor
enum BookkeepingReminderScheduler {
    /// 请求通知权限。
    ///
    /// - Returns: 用户是否允许；之前已经拒绝过时系统不再弹窗，直接返回 `false`。
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// 按当前偏好重排提醒：先清掉已排好的，开关打开且有权限时重新排。
    ///
    /// App 回到前台和进入后台时都调用，所以今天刚记过账，今天的提醒就会取消。
    ///
    /// - Parameters:
    ///   - container: 用来判断今天是否记过账的本地财务容器。
    ///   - locale: 通知文案使用的语言环境。
    ///   - calendar: 用户当前日历。
    ///   - now: 当前时刻。
    static func reschedule(
        container: ModelContainer,
        locale: Locale,
        calendar: Calendar,
        now: Date = .now,
        defaults: UserDefaults = .standard
    ) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(
            withIdentifiers: (0 ..< BookkeepingReminder.scheduledDays).map(BookkeepingReminder.identifier(at:))
        )
        guard defaults.bool(forKey: BookkeepingReminder.isEnabledKey) else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        let storedMinutes = defaults.object(forKey: BookkeepingReminder.minutesKey) as? Int
        let fires = BookkeepingReminder.fireComponents(
            now: now,
            minutes: storedMinutes ?? BookkeepingReminder.defaultMinutes,
            hasEntryToday: hasEntry(onDay: TransactionDay.encode(now, calendar: calendar), in: container),
            calendar: calendar
        )
        let content = UNMutableNotificationContent()
        content.title = AccountLocalization.string("reminder.notification.title", locale: locale)
        content.body = AccountLocalization.string("reminder.notification.body", locale: locale)
        content.sound = .default
        for (index, fire) in fires.enumerated() {
            try? await center.add(
                UNNotificationRequest(
                    identifier: BookkeepingReminder.identifier(at: index),
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: fire, repeats: false)
                )
            )
        }
    }

    /// 这一天用户自己是否记过账；周期记账自动记入的不算，否则有固定支出的日子永远不提醒。
    ///
    /// - Parameters:
    ///   - day: `YYYYMMDD` 记账日。
    ///   - container: 本地财务容器。
    /// - Returns: 读取失败时返回 `false`，宁可多提醒一次。
    static func hasEntry(onDay day: Int, in container: ModelContainer) -> Bool {
        let expenseType = AccountTransactionType.expense.rawValue
        let incomeType = AccountTransactionType.income.rawValue
        let descriptor = FetchDescriptor<AccountTransaction>(
            predicate: #Predicate<AccountTransaction> { transaction in
                transaction.transactionDay == day
                    && transaction.recurringRuleID == nil
                    && (transaction.typeRawValue == expenseType || transaction.typeRawValue == incomeType)
            }
        )
        return ((try? container.makeManualSaveContext().fetchCount(descriptor)) ?? 0) > 0
    }
}
