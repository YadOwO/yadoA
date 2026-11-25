import Foundation
import SwiftData
import Testing
@testable import yadoA

@Suite("备份提醒策略")
@MainActor
struct BackupReminderPolicyTests {
    /// 固定的判断时刻，所有用例都以它为基准。
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// 一天的秒数。
    private let day: TimeInterval = 86_400

    /// 构造策略：默认值正好满足全部显示条件，每个用例只改一个输入。
    ///
    /// - Parameter earliestTransactionAge: 最早一笔流水距 `now` 的秒数；传 `nil` 表示没有流水时间。
    private func makePolicy(
        isSyncEnabled: Bool = false,
        transactionCount: Int = 20,
        earliestTransactionAge: TimeInterval? = 10 * 86_400,
        lastBackupAt: Date? = nil,
        snoozedUntil: Date? = nil
    ) -> BackupReminderPolicy {
        BackupReminderPolicy(
            now: now,
            isSyncEnabled: isSyncEnabled,
            transactionCount: transactionCount,
            earliestTransactionSavedAt: earliestTransactionAge.map { now.addingTimeInterval(-$0) },
            lastBackupAt: lastBackupAt,
            snoozedUntil: snoozedUntil
        )
    }

    // MARK: - 显示条件

    @Test("全部条件满足时显示")
    func showsWhenEveryConditionHolds() {
        #expect(makePolicy().showsReminder)
    }

    @Test("同步开启时，其余条件都满足也不显示")
    func hiddenWhenSyncEnabled() {
        #expect(makePolicy(isSyncEnabled: true).showsReminder == false)
    }

    @Test("流水 19 笔不显示，20 笔显示")
    func transactionCountThreshold() {
        #expect(makePolicy(transactionCount: 19).showsReminder == false)
        #expect(makePolicy(transactionCount: 20).showsReminder)
        #expect(makePolicy(transactionCount: 0).showsReminder == false)
    }

    @Test("最早流水记录不满 7 天不显示，刚好 7 天显示，没有流水时间不显示")
    func usageIntervalThreshold() {
        // 6 天 23 小时
        #expect(makePolicy(earliestTransactionAge: 7 * day - 3_600).showsReminder == false)
        #expect(makePolicy(earliestTransactionAge: 7 * day).showsReminder)
        #expect(makePolicy(earliestTransactionAge: nil).showsReminder == false)
    }

    @Test("从没备份过显示；距上次备份差 1 秒满 30 天不显示，刚好 30 天显示")
    func reminderIntervalThreshold() {
        let almostThirtyDays = now.addingTimeInterval(-(30 * day - 1))
        let exactlyThirtyDays = now.addingTimeInterval(-30 * day)

        #expect(makePolicy(lastBackupAt: nil).showsReminder)
        #expect(makePolicy(lastBackupAt: almostThirtyDays).showsReminder == false)
        #expect(makePolicy(lastBackupAt: exactlyThirtyDays).showsReminder)
        #expect(makePolicy(lastBackupAt: now).showsReminder == false)
    }

    @Test("暂缓到 now + 1 秒不显示，暂缓到 now 或已过期时显示")
    func snoozeBoundary() {
        #expect(makePolicy(snoozedUntil: now.addingTimeInterval(1)).showsReminder == false)
        #expect(makePolicy(snoozedUntil: now).showsReminder)
        #expect(makePolicy(snoozedUntil: now.addingTimeInterval(-1)).showsReminder)
        #expect(makePolicy(snoozedUntil: nil).showsReminder)
    }

    @Test("流水样本按保存时间升序，只取前 20 条")
    func sampleDescriptorReadsEarliestTwentyRows() {
        let descriptor = BackupReminderPolicy.transactionSampleDescriptor

        #expect(descriptor.fetchLimit == BackupReminderPolicy.minimumTransactionCount)
        #expect(descriptor.sortBy.count == 1)
        #expect(descriptor.sortBy.first?.order == .forward)
    }

    // MARK: - BackupReminderStore

    @Test("暂缓记录写成当前时间加 30 天")
    func snoozeStoresNowPlusInterval() {
        let suiteName = "backup-reminder-store-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        BackupReminderStore.snooze(from: now, in: defaults)
        BackupReminderStore.recordBackup(at: now, in: defaults)

        #expect(BackupReminderStore.snoozedUntil(in: defaults) == now.addingTimeInterval(30 * day))
        #expect(BackupReminderStore.lastBackupAt(in: defaults) == now)

        BackupReminderStore.clear(in: defaults)
        #expect(BackupReminderStore.snoozedUntil(in: defaults) == nil)
        #expect(BackupReminderStore.lastBackupAt(in: defaults) == nil)
    }

    // MARK: - BackupStatusText

    /// 固定在东八区的公历，避免测试机时区影响「按天」的结果。
    private var gmt8Calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        return calendar
    }

    @Test("跨天按日历天计算：昨晚到今早算 1 天")
    func elapsedDaysCountsCalendarDays() {
        let calendar = gmt8Calendar
        let morning = calendar.date(from: DateComponents(year: 2027, month: 1, day: 10, hour: 8))!
        let lastNight = calendar.date(from: DateComponents(year: 2027, month: 1, day: 9, hour: 23, minute: 50))!
        let twelveDaysEarlier = calendar.date(from: DateComponents(year: 2026, month: 12, day: 29, hour: 20))!

        #expect(BackupStatusText.elapsedDays(since: lastNight, now: morning, calendar: calendar) == 1)
        #expect(BackupStatusText.elapsedDays(since: twelveDaysEarlier, now: morning, calendar: calendar) == 12)
    }

    @Test("同一天为 0 天，未来时间不会出现负数")
    func elapsedDaysIsNeverNegative() {
        let calendar = gmt8Calendar
        let morning = calendar.date(from: DateComponents(year: 2027, month: 1, day: 10, hour: 8))!
        let evening = calendar.date(from: DateComponents(year: 2027, month: 1, day: 10, hour: 21))!
        let nextWeek = calendar.date(from: DateComponents(year: 2027, month: 1, day: 17, hour: 8))!

        #expect(BackupStatusText.elapsedDays(since: morning, now: evening, calendar: calendar) == 0)
        #expect(BackupStatusText.elapsedDays(since: nextWeek, now: morning, calendar: calendar) == 0)
    }

    @Test("没有备份记录时显示「还没备份过」的本地化文案")
    func statusTextWithoutBackupUsesNeverString() {
        for identifier in ["en_US", "zh_Hans_CN"] {
            let locale = Locale(identifier: identifier)

            let text = BackupStatusText.text(
                lastBackupAt: nil,
                now: now,
                calendar: gmt8Calendar,
                locale: locale
            )

            #expect(text == AccountLocalization.string("backup.status.never", locale: locale))
        }
    }

    @Test("有备份记录时文案包含相对时间，并套进「上次备份」格式")
    func statusTextWithBackupWrapsRelativeTime() {
        let calendar = gmt8Calendar
        let locale = Locale(identifier: "en_US")
        let backup = calendar.date(from: DateComponents(year: 2026, month: 12, day: 29, hour: 20))!
        let today = calendar.date(from: DateComponents(year: 2027, month: 1, day: 10, hour: 8))!

        let text = BackupStatusText.text(lastBackupAt: backup, now: today, calendar: calendar, locale: locale)

        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(from: DateComponents(day: -12))
        #expect(text == AccountLocalization.formatted("backup.status.last", value: relative, locale: locale))
        #expect(text.contains(relative))
    }
}
