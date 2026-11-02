import CryptoKit
import Foundation
import SwiftData

/// 周期记账的重复频率；rawValue 持久化并参与同步，只能新增不能改名。
enum RecurringFrequency: String, CaseIterable, Identifiable, Sendable {
    /// 每天。
    case daily

    /// 每周同一天。
    case weekly

    /// 每两周同一天。
    case biweekly

    /// 每月同一天；当月没有这一天时取月末。
    case monthly

    /// 每三个月同一天；当月没有这一天时取月末。
    case quarterly

    /// 每年同月同日；平年没有 2 月 29 日时取 2 月 28 日。
    case yearly

    /// SwiftUI 选择器使用稳定值作为标识。
    var id: String { rawValue }

    /// 频率名称的本地化键。
    var titleKey: String { "recurring.frequency.\(rawValue)" }
}

/// 周期记账的排期计算；只处理 `YYYYMMDD` 整数，不受设备时区影响。
enum RecurringSchedule {
    /// 只用来做日期运算的 UTC 公历。
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    /// 计算某一期之后的下一期。
    ///
    /// 按月、按年的日子始终从起始日推算：1 月 31 日起始时依次是 2 月 28 日、3 月 31 日，不会一路停在 28 日。
    ///
    /// - Parameters:
    ///   - day: 当前这一期的 `YYYYMMDD`。
    ///   - frequency: 重复频率。
    ///   - anchorDay: 起始日的 `YYYYMMDD`。
    /// - Returns: 下一期；日期无效时返回 `nil`。
    static func day(after day: Int, frequency: RecurringFrequency, anchorDay: Int) -> Int? {
        switch frequency {
        case .daily: adding(days: 1, to: day)
        case .weekly: adding(days: 7, to: day)
        case .biweekly: adding(days: 14, to: day)
        case .monthly: adding(months: 1, to: day, anchorDay: anchorDay)
        case .quarterly: adding(months: 3, to: day, anchorDay: anchorDay)
        case .yearly: adding(months: 12, to: day, anchorDay: anchorDay)
        }
    }

    /// 从某一期开始往后找，第一个不早于目标日期的一期；恢复暂停的规则时用来跳过暂停期间的日期。
    ///
    /// - Parameters:
    ///   - target: 目标日期的 `YYYYMMDD`。
    ///   - start: 开始查找的一期。
    ///   - frequency: 重复频率。
    ///   - anchorDay: 起始日的 `YYYYMMDD`。
    /// - Returns: 找到的一期；日期无效时返回 `start`。
    static func firstDay(onOrAfter target: Int, from start: Int, frequency: RecurringFrequency, anchorDay: Int) -> Int {
        var current = start
        while current < target {
            guard let next = day(after: current, frequency: frequency, anchorDay: anchorDay), next > current else {
                return current
            }
            current = next
        }
        return current
    }

    /// 按天推进。
    private static func adding(days: Int, to day: Int) -> Int? {
        guard let date = TransactionDay.date(from: day, calendar: calendar),
              let shifted = calendar.date(byAdding: .day, value: days, to: date)
        else { return nil }
        return TransactionDay.encode(shifted, calendar: calendar)
    }

    /// 按月推进，日子取起始日当天，目标月没有这一天时取月末。
    private static func adding(months: Int, to day: Int, anchorDay: Int) -> Int? {
        let monthIndex = day / 10_000 * 12 + (day / 100 % 100 - 1) + months
        let year = monthIndex / 12
        let month = monthIndex % 12 + 1
        guard let firstOfMonth = TransactionDay.date(from: year * 10_000 + month * 100 + 1, calendar: calendar),
              let daysInMonth = calendar.range(of: .day, in: .month, for: firstOfMonth)?.count
        else { return nil }
        return year * 10_000 + month * 100 + min(anchorDay % 100, daysInMonth)
    }
}

/// SwiftData 中持久化的周期记账规则：按频率自动生成收支流水。
///
/// 已生成的流水是普通流水，可以单独修改或删除；改动或删除规则都不影响已生成的流水。
/// 规则见 `docs/rules/recurring-bookkeeping-rules.md`。
@Model
final class RecurringRule {
    /// 跨设备保持稳定的规则标识，也是每期流水标识的计算依据。
    @Attribute(.unique) var id: UUID

    /// `BookkeepingEntryType.rawValue` 的持久化值。
    var entryTypeRawValue: String

    /// 记入账户的稳定 UUID；账户不可用时规则暂不生成。
    var accountID: UUID

    /// 收支分类 key（预置 rawValue 或 `custom.<uuid>`）。
    var categoryKey: String

    /// 每期的正数金额，最多两位小数。
    var amount: Decimal

    /// 写入每期流水的可选备注。
    var note: String?

    /// `RecurringFrequency.rawValue` 的持久化值；未知值的规则不生成。
    var frequencyRawValue: String

    /// 排期起始日的 `YYYYMMDD`，决定按月、按年时取哪一天。
    var anchorDay: Int

    /// 下一期要记入的 `YYYYMMDD`。
    var nextDueDay: Int

    /// 最后一期不能晚于这一天的 `YYYYMMDD`；为空表示一直重复。
    var endDay: Int?

    /// 暂停时间；为空表示正常生成。
    var pausedAt: Date?

    /// 规则创建时间。
    var createdAt: Date

    /// 用户最近一次修改规则的时间；自动生成推进排期时不变。
    var updatedAt: Date

    /// 已知持久化值对应的收支方向；未知值返回 `nil`。
    var entryType: BookkeepingEntryType? {
        BookkeepingEntryType(rawValue: entryTypeRawValue)
    }

    /// 已知持久化值对应的重复频率；未知值返回 `nil`。
    var frequency: RecurringFrequency? {
        RecurringFrequency(rawValue: frequencyRawValue)
    }

    /// 是否已经过了结束日期，不会再生成。
    var isFinished: Bool {
        endDay.map { nextDueDay > $0 } ?? false
    }

    /// 直接构造已完成校验的持久化规则。
    init(
        id: UUID,
        entryTypeRawValue: String,
        accountID: UUID,
        categoryKey: String,
        amount: Decimal,
        note: String?,
        frequencyRawValue: String,
        anchorDay: Int,
        nextDueDay: Int,
        endDay: Int?,
        pausedAt: Date?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.entryTypeRawValue = entryTypeRawValue
        self.accountID = accountID
        self.categoryKey = categoryKey
        self.amount = amount
        self.note = note
        self.frequencyRawValue = frequencyRawValue
        self.anchorDay = anchorDay
        self.nextDueDay = nextDueDay
        self.endDay = endDay
        self.pausedAt = pausedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 用已校验的值覆盖除稳定标识外的全部持久化字段；恢复备份和应用同步记录时使用。
    func overwrite(with other: RecurringRule) {
        entryTypeRawValue = other.entryTypeRawValue
        accountID = other.accountID
        categoryKey = other.categoryKey
        amount = other.amount
        note = other.note
        frequencyRawValue = other.frequencyRawValue
        anchorDay = other.anchorDay
        nextDueDay = other.nextDueDay
        endDay = other.endDay
        pausedAt = other.pausedAt
        createdAt = other.createdAt
        updatedAt = other.updatedAt
    }

    /// 计算某条规则某一期流水的标识。
    ///
    /// 同一条规则的同一期在任何设备上都得到同一个 UUID，所以两台设备离线时各自生成，同步后也只算一笔。
    ///
    /// - Parameters:
    ///   - ruleID: 规则 UUID。
    ///   - day: 这一期的 `YYYYMMDD`。
    /// - Returns: 这一期流水的 UUID。
    static func occurrenceID(ruleID: UUID, day: Int) -> UUID {
        let digest = SHA256.hash(data: Data("recurring:\(ruleID.uuidString.lowercased()):\(day)".utf8))
        var bytes = Array(digest.prefix(16))
        // 按 RFC 4122 标记版本 5 和变体，服务端的记录 ID 校验只看格式，这里仍保持合法
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

/// 新建或修改一条周期记账时提交的内容。
struct RecurringRuleInput: Equatable, Sendable {
    /// 规则 UUID；已存在时修改，否则新建。
    let id: UUID

    /// 记入账户的 UUID。
    let accountID: UUID

    /// 收支方向。
    let entryType: BookkeepingEntryType

    /// 收支分类 key。
    let categoryKey: String

    /// 每期金额。
    let amount: Decimal

    /// 可选备注，空白会被清理。
    let note: String

    /// 重复频率。
    let frequency: RecurringFrequency

    /// 下一期的 `YYYYMMDD`。
    let nextDueDay: Int

    /// 结束日期的 `YYYYMMDD`；为空表示一直重复。
    let endDay: Int?

    /// 由记账表单的草稿和周期选项组成提交内容。
    ///
    /// - Parameters:
    ///   - draft: 记账表单的草稿，`transactionDay` 表示下一期，`id` 表示规则。
    ///   - frequency: 重复频率。
    ///   - endDay: 结束日期。
    /// - Returns: 提交内容；草稿缺少账户或金额时为 `nil`。
    init?(draft: DiningExpenseDraft, frequency: RecurringFrequency, endDay: Int?) {
        guard let accountID = draft.accountID, let amount = draft.amount else { return nil }
        self.init(
            id: draft.id,
            accountID: accountID,
            entryType: draft.entryType,
            categoryKey: draft.categoryKey,
            amount: amount,
            note: draft.note,
            frequency: frequency,
            nextDueDay: draft.transactionDay,
            endDay: endDay
        )
    }

    /// 成员逐一初始化。
    init(
        id: UUID,
        accountID: UUID,
        entryType: BookkeepingEntryType,
        categoryKey: String,
        amount: Decimal,
        note: String,
        frequency: RecurringFrequency,
        nextDueDay: Int,
        endDay: Int?
    ) {
        self.id = id
        self.accountID = accountID
        self.entryType = entryType
        self.categoryKey = categoryKey
        self.amount = amount
        self.note = note
        self.frequency = frequency
        self.nextDueDay = nextDueDay
        self.endDay = endDay
    }
}
