import Foundation

/// 备份提醒在本机保存的两个记录：上次备份时间和提醒暂缓截止时间。
///
/// 只存在 `UserDefaults`，不进 SwiftData，不随账本同步或备份。
/// 值统一存成 `Double`（`timeIntervalSince1970`），视图可以直接用 `@AppStorage(key) var x: Double?` 观察；
/// 不直接存 `Date`，因为 iOS 18 的 `@AppStorage` 观察不到 `Date`。
enum BackupReminderStore {
    /// 上次真正备份成功的时间（只有分享面板确认完成后才写入）。
    static let lastExportedAtKey = "backup.lastExportedAt"

    /// 用户点「以后再说」后，提醒卡片暂缓到的截止时间。
    static let snoozedUntilKey = "backup.reminderSnoozedUntil"

    /// 把 `@AppStorage` 读到的时间戳还原成日期。
    ///
    /// - Parameter value: 以 `timeIntervalSince1970` 保存的数值；没有记录时为 `nil`。
    /// - Returns: 对应的日期；没有记录时为 `nil`。
    static func date(fromStored value: Double?) -> Date? {
        value.map { Date(timeIntervalSince1970: $0) }
    }

    /// 读取上次备份时间。
    ///
    /// - Parameter defaults: 保存记录的 `UserDefaults`，测试可注入独立的套件。
    /// - Returns: 上次备份时间；从没备份过时为 `nil`。
    static func lastBackupAt(in defaults: UserDefaults = .standard) -> Date? {
        storedDate(forKey: lastExportedAtKey, in: defaults)
    }

    /// 读取提醒暂缓的截止时间。
    ///
    /// - Parameter defaults: 保存记录的 `UserDefaults`，测试可注入独立的套件。
    /// - Returns: 暂缓截止时间；没有暂缓记录时为 `nil`。
    static func snoozedUntil(in defaults: UserDefaults = .standard) -> Date? {
        storedDate(forKey: snoozedUntilKey, in: defaults)
    }

    /// 记录一次真正完成的备份。
    ///
    /// - Parameters:
    ///   - date: 备份完成的时间。
    ///   - defaults: 保存记录的 `UserDefaults`，测试可注入独立的套件。
    static func recordBackup(at date: Date, in defaults: UserDefaults = .standard) {
        defaults.set(date.timeIntervalSince1970, forKey: lastExportedAtKey)
    }

    /// 暂缓提醒：把截止时间记为 `now` 之后的一个暂缓期。
    ///
    /// - Parameters:
    ///   - now: 用户点「以后再说」的时间。
    ///   - defaults: 保存记录的 `UserDefaults`，测试可注入独立的套件。
    static func snooze(from now: Date, in defaults: UserDefaults = .standard) {
        let until = now.addingTimeInterval(BackupReminderPolicy.snoozeInterval)
        defaults.set(until.timeIntervalSince1970, forKey: snoozedUntilKey)
    }

    /// 清掉两个记录；本机账本被清空后调用，让提醒重新按「从没备份过」计算。
    ///
    /// - Parameter defaults: 保存记录的 `UserDefaults`，测试可注入独立的套件。
    static func clear(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: lastExportedAtKey)
        defaults.removeObject(forKey: snoozedUntilKey)
    }

    /// 读取以时间戳保存的日期；键不存在或类型不对时返回 `nil`。
    private static func storedDate(forKey key: String, in defaults: UserDefaults) -> Date? {
        date(fromStored: defaults.object(forKey: key) as? Double)
    }
}
