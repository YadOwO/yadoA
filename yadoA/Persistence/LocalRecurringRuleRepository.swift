import Foundation
import OSLog
import SwiftData

/// 周期记账写入边界产生的错误。
enum RecurringRuleRepositoryError: Error, Equatable {
    /// 规则不存在。
    case ruleNotFound(UUID)

    /// 金额、日期或分类 key 不符合约束，或结束日期早于下一期。
    case invalidInput
}

/// 一笔自动记入的流水，供首页播放新增提示。
struct RecurringGeneratedEntry: Equatable, Sendable {
    /// 流水 UUID。
    let id: UUID

    /// `YYYYMMDD` 记账日。
    let transactionDay: Int
}

/// 在主 actor 上读写周期记账规则，并把到期的规则生成为流水。
@MainActor
final class LocalRecurringRuleRepository {
    /// 单条规则一次最多补记的期数，避免长期没打开 App 时一次写入过多；剩下的下次打开继续补。
    static let maxOccurrencesPerRun = 400

    /// 日志。
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "yadoA", category: "Recurring")

    /// 应用或测试持有的完整本地财务容器；每次命令创建新鲜 context。
    private let container: ModelContainer

    /// 创建仓库。
    ///
    /// - Parameter container: 应用或测试持有的完整本地财务容器。
    init(container: ModelContainer) {
        self.container = container
    }

    /// 新建或修改一条规则。
    ///
    /// 修改了下一期或频率时，把下一期作为新的排期起始日。
    ///
    /// - Parameters:
    ///   - input: 提交内容。
    ///   - now: 本次修改时间。
    /// - Throws: 内容不合法、账户或分类不可用、保存失败时抛出错误。
    func save(_ input: RecurringRuleInput, now: Date = .now) throws {
        guard input.amount > 0,
              AccountAmountParser.hasCNYPrecision(input.amount),
              TransactionDay.isValid(input.nextDueDay),
              BookkeepingCategoryKey.isValid(input.categoryKey, direction: input.entryType),
              input.endDay.map({ TransactionDay.isValid($0) && $0 >= input.nextDueDay }) ?? true
        else { throw RecurringRuleRepositoryError.invalidInput }

        let context = container.makeManualSaveContext()
        _ = try LocalExpenseRepository.bookkeepingAccount(id: input.accountID, in: context)
        guard try context.isCategoryAvailable(key: input.categoryKey, direction: input.entryType) else {
            throw ExpenseRepositoryError.categoryUnavailable(input.categoryKey)
        }

        let trimmedNote = input.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = trimmedNote.isEmpty ? nil : trimmedNote
        if let rule = try context.recurringRule(id: input.id) {
            if rule.nextDueDay != input.nextDueDay || rule.frequencyRawValue != input.frequency.rawValue {
                rule.anchorDay = input.nextDueDay
            }
            rule.entryTypeRawValue = input.entryType.rawValue
            rule.accountID = input.accountID
            rule.categoryKey = input.categoryKey
            rule.amount = input.amount
            rule.note = note
            rule.frequencyRawValue = input.frequency.rawValue
            rule.nextDueDay = input.nextDueDay
            rule.endDay = input.endDay
            rule.updatedAt = now
        } else {
            context.insert(
                RecurringRule(
                    id: input.id,
                    entryTypeRawValue: input.entryType.rawValue,
                    accountID: input.accountID,
                    categoryKey: input.categoryKey,
                    amount: input.amount,
                    note: note,
                    frequencyRawValue: input.frequency.rawValue,
                    anchorDay: input.nextDueDay,
                    nextDueDay: input.nextDueDay,
                    endDay: input.endDay,
                    pausedAt: nil,
                    createdAt: now,
                    updatedAt: now
                )
            )
        }
        try context.saveOrRollback()
    }

    /// 删除一条规则；已经生成的流水保留。
    ///
    /// - Parameter id: 规则 UUID。
    /// - Throws: 规则不存在或保存失败时抛出错误。
    func delete(id: UUID) throws {
        let context = container.makeManualSaveContext()
        guard let rule = try context.recurringRule(id: id) else {
            throw RecurringRuleRepositoryError.ruleNotFound(id)
        }
        context.delete(rule)
        try context.saveOrRollback()
    }

    /// 暂停或恢复一条规则。
    ///
    /// 暂停期间的日期不补记：恢复时把下一期直接推到今天或之后。
    ///
    /// - Parameters:
    ///   - isPaused: 是否暂停。
    ///   - id: 规则 UUID。
    ///   - today: 今天的 `YYYYMMDD`。
    ///   - now: 本次修改时间。
    /// - Throws: 规则不存在或保存失败时抛出错误。
    func setPaused(_ isPaused: Bool, id: UUID, today: Int, now: Date = .now) throws {
        let context = container.makeManualSaveContext()
        guard let rule = try context.recurringRule(id: id) else {
            throw RecurringRuleRepositoryError.ruleNotFound(id)
        }
        rule.pausedAt = isPaused ? now : nil
        if !isPaused, let frequency = rule.frequency {
            rule.nextDueDay = RecurringSchedule.firstDay(
                onOrAfter: today,
                from: rule.nextDueDay,
                frequency: frequency,
                anchorDay: rule.anchorDay
            )
        }
        rule.updatedAt = now
        try context.saveOrRollback()
    }

    /// 把所有到期的规则生成为流水。
    ///
    /// 每条规则单独保存：账户停用、分类不可用的规则保持原样，不影响其他规则，账户恢复后再补记。
    ///
    /// - Parameters:
    ///   - today: 今天的 `YYYYMMDD`。
    ///   - now: 流水的保存时间。
    /// - Returns: 本次新生成的流水。
    @discardableResult
    func generateDue(today: Int, now: Date = .now) -> [RecurringGeneratedEntry] {
        let context = container.makeManualSaveContext()
        let descriptor = FetchDescriptor<RecurringRule>(
            predicate: #Predicate<RecurringRule> { rule in
                rule.nextDueDay <= today && rule.pausedAt == nil
            }
        )
        guard let dueRuleIDs = try? context.fetch(descriptor).map(\.id) else { return [] }

        var generated: [RecurringGeneratedEntry] = []
        for ruleID in dueRuleIDs {
            do {
                generated += try generate(ruleID: ruleID, today: today, now: now)
            } catch {
                Self.logger.error("周期记账未能生成：\(String(describing: error), privacy: .public)")
            }
        }
        return generated
    }

    /// 生成一条规则到今天为止的全部期数，并推进下一期；流水和排期在同一次保存里提交。
    private func generate(ruleID: UUID, today: Int, now: Date) throws -> [RecurringGeneratedEntry] {
        let context = container.makeManualSaveContext()
        guard let rule = try context.recurringRule(id: ruleID),
              rule.pausedAt == nil,
              let entryType = rule.entryType,
              let frequency = rule.frequency
        else { return [] }

        let expenses = LocalExpenseRepository(container: container)
        var generated: [RecurringGeneratedEntry] = []
        var day = rule.nextDueDay
        var periods = 0
        while day <= today, periods < Self.maxOccurrencesPerRun, rule.endDay.map({ day <= $0 }) ?? true {
            let id = RecurringRule.occurrenceID(ruleID: rule.id, day: day)
            if try !context.containsTransaction(id: id), try !context.hasTombstone(transactionID: id) {
                try expenses.apply(
                    .insert(
                        BookkeepingEntrySnapshot(
                            id: id,
                            accountID: rule.accountID,
                            entryType: entryType,
                            categoryKey: rule.categoryKey,
                            amount: rule.amount,
                            transactionDay: day,
                            note: rule.note,
                            savedAt: now,
                            recurringRuleID: rule.id
                        )
                    ),
                    in: context
                )
                generated.append(RecurringGeneratedEntry(id: id, transactionDay: day))
            }
            guard let next = RecurringSchedule.day(after: day, frequency: frequency, anchorDay: rule.anchorDay),
                  next > day
            else { break }
            day = next
            periods += 1
        }
        guard day != rule.nextDueDay else { return [] }
        rule.nextDueDay = day
        try context.saveOrRollback()
        return generated
    }
}

extension ModelContext {
    /// 按稳定 UUID 读取周期记账规则。
    func recurringRule(id: UUID) throws -> RecurringRule? {
        let ruleID = id
        var descriptor = FetchDescriptor<RecurringRule>(
            predicate: #Predicate<RecurringRule> { rule in
                rule.id == ruleID
            }
        )
        descriptor.fetchLimit = 1
        return try fetch(descriptor).first
    }

    /// 流水是否已在本机删除、删除还没上传：这样的一期不能再生成，否则删掉的流水会回来。
    fileprivate func hasTombstone(transactionID: UUID) throws -> Bool {
        let key = SyncLedgerEntry.key(entityType: .transaction, recordID: transactionID)
        let descriptor = FetchDescriptor<SyncLedgerEntry>(
            predicate: #Predicate<SyncLedgerEntry> { entry in
                entry.key == key && entry.isTombstone
            }
        )
        return try fetchCount(descriptor) > 0
    }

    /// 把引用某个分类的周期记账规则迁到另一个分类；分类被删除时调用，不保存。
    ///
    /// - Parameters:
    ///   - key: 被删除的分类 key。
    ///   - direction: 收支方向。
    ///   - targetKey: 迁移目标分类 key。
    func migrateRecurringRules(categoryKey key: String, direction: BookkeepingEntryType, to targetKey: String) throws {
        let directionRawValue = direction.rawValue
        let rules = try fetch(
            FetchDescriptor<RecurringRule>(
                predicate: #Predicate<RecurringRule> { rule in
                    rule.entryTypeRawValue == directionRawValue && rule.categoryKey == key
                }
            )
        )
        for rule in rules {
            rule.categoryKey = targetKey
        }
    }
}
