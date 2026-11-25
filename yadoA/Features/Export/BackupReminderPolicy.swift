import Foundation
import SwiftData

/// 判断账户页要不要显示「备份提醒」卡片的纯值策略。
///
/// 所有输入都由调用方传入（当前时间、同步状态、流水样本、两个本机记录），不读取任何全局状态，方便固定时间测试。
struct BackupReminderPolicy: Equatable {
    /// 本机流水至少这么多笔才提醒；账本太空时没有备份的必要。
    static let minimumTransactionCount = 20

    /// 最早一笔流水至少记录了这么久才提醒（7 天）。
    static let minimumUsageInterval: TimeInterval = 7 * 86_400

    /// 距上次备份满这么久才再次提醒（30 天）。
    static let reminderInterval: TimeInterval = 30 * 86_400

    /// 点「以后再说」后的暂缓时长，与提醒间隔相同。
    static let snoozeInterval = reminderInterval

    /// 判断时刻。
    let now: Date

    /// 是否开启了云同步；开启后数据在云端有一份，不提醒。
    let isSyncEnabled: Bool

    /// 本机流水条数；账户页只读最多 `minimumTransactionCount` 条样本，所以最多是这个数。
    let transactionCount: Int

    /// 最早一笔流水的保存时间（`savedAt`，真实记录时间，不是流水日期）；没有流水时为 `nil`。
    let earliestTransactionSavedAt: Date?

    /// 上次真正备份成功的时间；从没备份过时为 `nil`。
    let lastBackupAt: Date?

    /// 提醒暂缓到的截止时间；没有暂缓记录时为 `nil`。
    let snoozedUntil: Date?

    /// 是否显示提醒卡片：以下各条必须全部成立。
    ///
    /// - 没开云同步。
    /// - 流水不少于 `minimumTransactionCount` 笔。
    /// - 最早一笔流水的保存时间在 `minimumUsageInterval` 以前（刚好满时算已满）。
    /// - 从没备份过，或距上次备份已满 `reminderInterval`（刚好满时算已满）。
    /// - 不在暂缓期内（到了截止时刻就算已过暂缓期）。
    var showsReminder: Bool {
        guard !isSyncEnabled, transactionCount >= Self.minimumTransactionCount else { return false }
        guard let earliestTransactionSavedAt,
              now.timeIntervalSince(earliestTransactionSavedAt) >= Self.minimumUsageInterval
        else { return false }
        if let lastBackupAt, now.timeIntervalSince(lastBackupAt) < Self.reminderInterval {
            return false
        }
        if let snoozedUntil, now < snoozedUntil {
            return false
        }
        return true
    }

    /// 账户页用来判断提醒的流水样本：按保存时间升序只取前 `minimumTransactionCount` 条。
    ///
    /// 结果条数就是「总数和 20 取小」，第一条就是最早的一笔，不需要整表读取。
    static var transactionSampleDescriptor: FetchDescriptor<AccountTransaction> {
        var descriptor = FetchDescriptor<AccountTransaction>(
            sortBy: [SortDescriptor(\.savedAt, order: .forward)]
        )
        descriptor.fetchLimit = minimumTransactionCount
        return descriptor
    }
}

/// 「上次备份」小字的文案与天数计算。
enum BackupStatusText {
    /// 按日历天计算从 `since` 到 `now` 过了几天。
    ///
    /// 两个时刻都先取当天零点再相减，所以昨晚到今早算 1 天；`since` 晚于 `now` 时按 0 天处理。
    ///
    /// - Parameters:
    ///   - since: 起点，例如上次备份时间。
    ///   - now: 当前时间。
    ///   - calendar: 用来划分「天」的日历。
    /// - Returns: 不小于 0 的整天数。
    static func elapsedDays(since: Date, now: Date, calendar: Calendar) -> Int {
        let start = calendar.startOfDay(for: since)
        let end = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        return max(days, 0)
    }

    /// 导出入口标题下的小字：有记录时是「上次备份：12 天前」，没有记录时是「还没备份过」。
    ///
    /// - Parameters:
    ///   - lastBackupAt: 上次备份时间；从没备份过时为 `nil`。
    ///   - now: 当前时间。
    ///   - calendar: 用来按天计算的日历。
    ///   - locale: 文案与相对时间使用的语言环境。
    /// - Returns: 已本地化的一行文案。
    static func text(lastBackupAt: Date?, now: Date, calendar: Calendar, locale: Locale) -> String {
        guard let lastBackupAt else {
            return AccountLocalization.string("backup.status.never", locale: locale)
        }
        let days = elapsedDays(since: lastBackupAt, now: now, calendar: calendar)
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(from: DateComponents(day: -days))
        return AccountLocalization.formatted("backup.status.last", value: relative, locale: locale)
    }
}
