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

    /// 内存修改完成后、显式保存前执行的故障点；测试用来模拟保存失败。
    private let beforeSave: () throws -> Void

    /// 创建仓库。
    ///
    /// - Parameters:
    ///   - container: 应用或测试持有的完整本地财务容器。
    ///   - beforeSave: 内存修改完成后、显式保存前执行的故障点。
    init(container: ModelContainer, beforeSave: @escaping () throws -> Void = {}) {
        self.container = container
        self.beforeSave = beforeSave
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
        let context = container.makeManualSaveContext()
        try Self.validate(input, in: context)
        if let rule = try context.recurringRule(id: input.id) {
            Self.apply(input, to: rule, now: now)
        } else {
            context.insert(
                RecurringRule(
                    id: input.id,
                    entryTypeRawValue: input.entryType.rawValue,
                    accountID: input.accountID,
                    categoryKey: input.categoryKey,
                    amount: input.amount,
                    note: Self.normalizedNote(input.note),
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
        try context.saveOrRollback(beforeSave: beforeSave)
    }

    /// 按字段修改一条规则：「恢复 → 改内容 → 暂停」在同一次保存里执行，任一步不合法时什么都不改。
    ///
    /// 恢复与 `setPaused(false, ...)` 一致，把下一期推到今天或之后，起始日不变；
    /// 只有修改内容里改了下一期或频率，下一期才成为新的起始日。已暂停的再暂停、正常的再恢复都不算错。
    ///
    /// - Parameters:
    ///   - id: 规则 UUID。
    ///   - change: 要改的内容。
    ///   - today: 今天的 `YYYYMMDD`，恢复时用来跳过暂停期间的日期。
    ///   - now: 本次修改时间。
    /// - Throws: 规则不存在、内容不合法、账户或分类不可用、保存失败时抛出错误。
    func update(id: UUID, change: RecurringRuleChange, today: Int, now: Date = .now) throws {
        let context = container.makeManualSaveContext()
        guard let rule = try context.recurringRule(id: id) else {
            throw RecurringRuleRepositoryError.ruleNotFound(id)
        }
        if change.isPaused == false, rule.pausedAt != nil {
            Self.resume(rule, today: today)
        }
        if change.changesContent {
            // 损坏的规则（方向或频率不认识）只有同时给出新值才能改
            guard let entryType = change.entryType ?? rule.entryType,
                  let frequency = change.frequency ?? rule.frequency
            else { throw RecurringRuleRepositoryError.invalidInput }
            let note: String = switch change.note {
            case let .set(value): value
            case .clear: ""
            case nil: rule.note ?? ""
            }
            let endDay: Int? = switch change.endDay {
            case let .set(day): day
            case .clear: nil
            case nil: rule.endDay
            }
            // 恢复已推后的下一期在这里作为当前值，没改下一期时不会被当成改了排期
            let input = RecurringRuleInput(
                id: rule.id,
                accountID: change.accountID ?? rule.accountID,
                entryType: entryType,
                categoryKey: change.categoryKey ?? rule.categoryKey,
                amount: change.amount ?? rule.amount,
                note: note,
                frequency: frequency,
                nextDueDay: change.nextDueDay ?? rule.nextDueDay,
                endDay: endDay
            )
            try Self.validate(input, in: context)
            Self.apply(input, to: rule, now: now)
        }
        if change.isPaused == true, rule.pausedAt == nil {
            rule.pausedAt = now
        }
        rule.updatedAt = now
        try context.saveOrRollback(beforeSave: beforeSave)
    }

    /// 校验提交内容：金额、日期、分类 key 合法，结束日期不早于下一期，账户可以记账，分类可用。
    private static func validate(_ input: RecurringRuleInput, in context: ModelContext) throws {
        guard input.amount > 0,
              AccountAmountParser.hasCNYPrecision(input.amount),
              TransactionDay.isValid(input.nextDueDay),
              BookkeepingCategoryKey.isValid(input.categoryKey, direction: input.entryType),
              input.endDay.map({ TransactionDay.isValid($0) && $0 >= input.nextDueDay }) ?? true
        else { throw RecurringRuleRepositoryError.invalidInput }

        _ = try LocalExpenseRepository.bookkeepingAccount(id: input.accountID, in: context)
        guard try context.isCategoryAvailable(key: input.categoryKey, direction: input.entryType) else {
            throw ExpenseRepositoryError.categoryUnavailable(input.categoryKey)
        }
    }

    /// 把已校验的内容写进已有规则；改了下一期或频率时，下一期成为新的起始日。
    private static func apply(_ input: RecurringRuleInput, to rule: RecurringRule, now: Date) {
        if rule.nextDueDay != input.nextDueDay || rule.frequencyRawValue != input.frequency.rawValue {
            rule.anchorDay = input.nextDueDay
        }
        rule.entryTypeRawValue = input.entryType.rawValue
        rule.accountID = input.accountID
        rule.categoryKey = input.categoryKey
        rule.amount = input.amount
        rule.note = normalizedNote(input.note)
        rule.frequencyRawValue = input.frequency.rawValue
        rule.nextDueDay = input.nextDueDay
        rule.endDay = input.endDay
        rule.updatedAt = now
    }

    /// 去掉首尾空白；空备注存为 `nil`。
    private static func normalizedNote(_ note: String) -> String? {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 恢复一条暂停的规则：暂停期间的日期不补记，下一期推到今天或之后，起始日不变。
    private static func resume(_ rule: RecurringRule, today: Int) {
        rule.pausedAt = nil
        if let frequency = rule.frequency {
            rule.nextDueDay = RecurringSchedule.firstDay(
                onOrAfter: today,
                from: rule.nextDueDay,
                frequency: frequency,
                anchorDay: rule.anchorDay
            )
        }
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
        try context.saveOrRollback(beforeSave: beforeSave)
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
        if isPaused {
            rule.pausedAt = now
        } else {
            Self.resume(rule, today: today)
        }
        rule.updatedAt = now
        try context.saveOrRollback(beforeSave: beforeSave)
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

    /// 只把一条规则到期的期数记入账本：语音新建或修改规则后，下一期是今天的立即记入，与编辑页保存后一致。
    ///
    /// 不碰其他规则，它们仍在 App 回到前台、同步结束后统一记入。
    ///
    /// - Parameters:
    ///   - ruleID: 规则 UUID。
    ///   - today: 今天的 `YYYYMMDD`。
    ///   - now: 流水的保存时间。
    /// - Returns: 本次新生成的流水；规则不存在、暂停或账户分类不可用时为空。
    @discardableResult
    func generateDue(ruleID: UUID, today: Int, now: Date = .now) -> [RecurringGeneratedEntry] {
        do {
            return try generate(ruleID: ruleID, today: today, now: now)
        } catch {
            Self.logger.error("周期记账未能生成：\(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// 在调用方的 context 中执行一次撤销；不保存，撤销语音会话的一轮时与其他改动一起提交。
    ///
    /// - Parameters:
    ///   - revert: 反向变更。
    ///   - context: 撤销用的 context。
    /// - Throws: 要删除或还原的规则已不存在时抛出 `ruleNotFound`。
    static func revert(_ revert: RecurringRuleRevert, in context: ModelContext) throws {
        switch revert {
        case let .remove(ruleID):
            guard let rule = try context.recurringRule(id: ruleID) else {
                throw RecurringRuleRepositoryError.ruleNotFound(ruleID)
            }
            context.delete(rule)
        case let .restore(snapshot):
            guard let rule = try context.recurringRule(id: snapshot.id) else {
                throw RecurringRuleRepositoryError.ruleNotFound(snapshot.id)
            }
            rule.overwrite(with: snapshot.makeRule())
        case let .reinsert(snapshot):
            // 期间同步又带回了同一条规则时按快照覆盖，不重复插入
            if let rule = try context.recurringRule(id: snapshot.id) {
                rule.overwrite(with: snapshot.makeRule())
            } else {
                context.insert(snapshot.makeRule())
            }
        }
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
        try context.saveOrRollback(beforeSave: beforeSave)
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
