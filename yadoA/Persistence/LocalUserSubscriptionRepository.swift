import Foundation
import SwiftData

/// 订阅写入边界产生的错误。
enum UserSubscriptionRepositoryError: Error, Equatable {
    /// 订阅不存在。
    case subscriptionNotFound(UUID)

    /// 名称、金额、日期或提醒天数不符合约束。
    case invalidInput
}

/// 在主 actor 上读写订阅，并维护「自动记账」打开时由订阅管理的那条周期记账规则。
///
/// 订阅和它的规则在同一次保存里提交：改了订阅，规则跟着改；任一步不合法时什么都不改。
@MainActor
final class LocalUserSubscriptionRepository {
    /// 名称最多几个字符。
    static let nameLengthLimit = 40

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

    /// 新建或修改一条订阅，并按「自动记账」设置新建、修改或解除它管理的周期记账规则。
    ///
    /// 排期：表单上的日期没变、周期也没变时保留原来的起始日（1 月 31 日起扣的仍按月末扣）；改了就以新日期为起始日。
    /// 规则的下一期只在新建规则、改了排期、从已取消恢复或规则被暂停过时重算为不早于今天的第一次扣费，
    /// 所以只改名称、金额时不会补记或跳过任何一期。
    /// 改成已取消时规则的结束日期设为今天：今天及以前该记的照常记，之后不再记；已取消的订阅不新建规则。
    ///
    /// - Parameters:
    ///   - input: 提交内容。
    ///   - today: 今天的 `YYYYMMDD`。
    ///   - now: 本次修改时间。
    /// - Returns: 保存后订阅管理的规则 UUID；不自动记账时为 `nil`。调用方用它把今天到期的一期立即记入。
    /// - Throws: 内容不合法、账户或分类不可用、保存失败时抛出错误。
    @discardableResult
    func save(_ input: UserSubscriptionInput, today: Int, now: Date = .now) throws -> UUID? {
        let context = container.makeManualSaveContext()
        let name = try Self.validatedName(input)
        let existing = try context.userSubscription(id: input.id)
        let previousStatus = existing?.status
        let previousAnchorDay = existing?.anchorDay
        let previousFrequencyRawValue = existing?.frequencyRawValue

        let anchorDay: Int
        if let existing, input.status == .cancelled {
            // 已取消时表单不显示扣费日，排期保持原样，恢复订阅时还能接着算
            anchorDay = existing.anchorDay
        } else if let existing,
                  existing.frequencyRawValue == input.frequency.rawValue,
                  existing.displayedChargeDay(today: today) == input.chargeDay {
            anchorDay = existing.anchorDay
        } else {
            anchorDay = input.chargeDay
        }

        let subscription: UserSubscription
        if let existing {
            subscription = existing
        } else {
            subscription = UserSubscription(
                id: input.id,
                name: name,
                amount: input.amount,
                frequencyRawValue: input.frequency.rawValue,
                anchorDay: anchorDay,
                categoryRawValue: input.category.rawValue,
                channelRawValue: input.channel.rawValue,
                statusRawValue: input.status.rawValue,
                accessEndDay: nil,
                reminderDaysBefore: nil,
                note: nil,
                recurringRuleID: nil,
                createdAt: now,
                updatedAt: now
            )
            context.insert(subscription)
        }
        subscription.name = name
        subscription.amount = input.amount
        subscription.frequencyRawValue = input.frequency.rawValue
        subscription.anchorDay = anchorDay
        subscription.categoryRawValue = input.category.rawValue
        subscription.channelRawValue = input.channel.rawValue
        subscription.statusRawValue = input.status.rawValue
        subscription.accessEndDay = input.status == .cancelled ? input.accessEndDay : nil
        subscription.reminderDaysBefore = input.reminderDaysBefore
        subscription.note = Self.normalizedNote(input.note)
        subscription.updatedAt = now

        let currentRule = try subscription.recurringRuleID.flatMap { try context.recurringRule(id: $0) }
        let isCancelled = input.status == .cancelled
        if let bookkeeping = input.bookkeeping, currentRule != nil || !isCancelled {
            let firstDueDay = UserSubscriptionSchedule.nextChargeDay(
                onOrAfter: today,
                anchorDay: anchorDay,
                frequency: input.frequency
            )
            let ruleInput = RecurringRuleInput(
                id: currentRule?.id ?? UUID(),
                accountID: bookkeeping.accountID,
                entryType: .expense,
                categoryKey: bookkeeping.categoryKey,
                amount: input.amount,
                note: name,
                frequency: input.frequency,
                nextDueDay: firstDueDay,
                endDay: nil
            )
            try LocalRecurringRuleRepository.validate(ruleInput, in: context)

            let rule: RecurringRule
            if let currentRule {
                rule = currentRule
            } else {
                rule = RecurringRule(
                    id: ruleInput.id,
                    entryTypeRawValue: BookkeepingEntryType.expense.rawValue,
                    accountID: bookkeeping.accountID,
                    categoryKey: bookkeeping.categoryKey,
                    amount: input.amount,
                    note: name,
                    frequencyRawValue: input.frequency.rawValue,
                    anchorDay: anchorDay,
                    nextDueDay: firstDueDay,
                    endDay: nil,
                    pausedAt: nil,
                    createdAt: now,
                    updatedAt: now
                )
                context.insert(rule)
            }
            rule.entryTypeRawValue = BookkeepingEntryType.expense.rawValue
            rule.accountID = bookkeeping.accountID
            rule.categoryKey = bookkeeping.categoryKey
            rule.amount = input.amount
            rule.note = name
            rule.frequencyRawValue = input.frequency.rawValue
            rule.anchorDay = anchorDay
            rule.updatedAt = now
            if isCancelled {
                if previousStatus != .cancelled || rule.endDay == nil {
                    rule.endDay = today
                }
            } else {
                let scheduleChanged = previousAnchorDay != anchorDay
                    || previousFrequencyRawValue != input.frequency.rawValue
                if currentRule == nil || scheduleChanged || previousStatus == .cancelled || rule.pausedAt != nil {
                    // 暂停或取消期间的日期不补记，与恢复周期记账一致
                    rule.pausedAt = nil
                    rule.nextDueDay = firstDueDay
                }
                rule.endDay = nil
            }
            subscription.recurringRuleID = rule.id
        } else {
            if let currentRule, input.bookkeeping == nil, input.deletesRuleWhenUnlinking {
                context.delete(currentRule)
            }
            subscription.recurringRuleID = nil
        }

        try context.saveOrRollback(beforeSave: beforeSave)
        return subscription.recurringRuleID
    }

    /// 删除一条订阅；已经记下的流水都保留。
    ///
    /// - Parameters:
    ///   - id: 订阅 UUID。
    ///   - deletesRule: 是否同时删掉它管理的周期记账；`false` 时那条规则留下来变成普通的周期记账。
    /// - Throws: 订阅不存在或保存失败时抛出错误。
    func delete(id: UUID, deletesRule: Bool) throws {
        let context = container.makeManualSaveContext()
        guard let subscription = try context.userSubscription(id: id) else {
            throw UserSubscriptionRepositoryError.subscriptionNotFound(id)
        }
        if deletesRule, let ruleID = subscription.recurringRuleID, let rule = try context.recurringRule(id: ruleID) {
            context.delete(rule)
        }
        context.delete(subscription)
        try context.saveOrRollback(beforeSave: beforeSave)
    }

    /// 校验提交内容并返回清理过的名称。
    ///
    /// - Parameter input: 提交内容。
    /// - Returns: 去掉首尾空白的名称。
    /// - Throws: 名称为空或过长、金额不合法、日期无效、提醒天数超出范围时抛出 `invalidInput`。
    static func validatedName(_ input: UserSubscriptionInput) throws -> String {
        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name.count <= nameLengthLimit,
              input.amount > 0,
              AccountAmountParser.hasCNYPrecision(input.amount),
              TransactionDay.isValid(input.chargeDay),
              input.accessEndDay.map(TransactionDay.isValid) ?? true,
              input.reminderDaysBefore.map(UserSubscriptionReminderOption.validRange.contains) ?? true
        else { throw UserSubscriptionRepositoryError.invalidInput }
        return name
    }

    /// 去掉首尾空白；空备注存为 `nil`。
    private static func normalizedNote(_ note: String) -> String? {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 记下一次改动前订阅和它管的周期记账的样子，供语音撤销。
    ///
    /// - Parameters:
    ///   - subscriptionID: 要改的订阅；新建时传新 UUID。
    ///   - ruleIDs: 这次改动可能新建、修改或删除的规则，通常是改动前后订阅指向的规则。
    /// - Returns: 撤销时还原到这个样子的反向变更。
    /// - Throws: 读取失败时抛出错误。
    func revertPoint(subscriptionID: UUID, ruleIDs: [UUID]) throws -> UserSubscriptionRevert {
        let context = container.makeManualSaveContext()
        let subscription = try context.userSubscription(id: subscriptionID)
        var seen = Set<UUID>()
        let rules = try ruleIDs.filter { seen.insert($0).inserted }.map { ruleID in
            UserSubscriptionRevert.RuleState(
                id: ruleID,
                snapshot: try context.recurringRule(id: ruleID).map(RecurringRuleSnapshot.init(rule:))
            )
        }
        return UserSubscriptionRevert(
            subscriptionID: subscriptionID,
            previous: subscription.map(UserSubscriptionSnapshot.init(subscription:)),
            previousRules: rules
        )
    }

    /// 在调用方的 context 中执行一次撤销；不保存，撤销语音会话的一轮时与其他改动一起提交。
    ///
    /// 先还原规则再还原订阅：订阅当时新建的规则删掉，改过或删掉的按快照还原；订阅本身同理。
    /// 期间同步又带回了同一条记录时按快照覆盖，不重复插入。
    ///
    /// - Parameters:
    ///   - revert: 反向变更。
    ///   - context: 撤销用的 context。
    /// - Throws: 读取失败时抛出错误。
    static func revert(_ revert: UserSubscriptionRevert, in context: ModelContext) throws {
        for state in revert.previousRules {
            let current = try context.recurringRule(id: state.id)
            switch (state.snapshot, current) {
            case let (snapshot?, current?): current.overwrite(with: snapshot.makeRule())
            case let (snapshot?, nil): context.insert(snapshot.makeRule())
            case let (nil, current?): context.delete(current)
            case (nil, nil): break
            }
        }
        let current = try context.userSubscription(id: revert.subscriptionID)
        switch (revert.previous, current) {
        case let (snapshot?, current?): current.overwrite(with: snapshot.makeSubscription())
        case let (snapshot?, nil): context.insert(snapshot.makeSubscription())
        case let (nil, current?): context.delete(current)
        case (nil, nil): break
        }
    }
}

/// 一条订阅在某一刻的全部持久化字段，用于撤销语音会话里的修改和删除。
struct UserSubscriptionSnapshot: Equatable, Sendable {
    /// 订阅 UUID。
    let id: UUID

    /// 名称。
    let name: String

    /// 每期金额。
    let amount: Decimal

    /// 扣费周期原始值。
    let frequencyRawValue: String

    /// 排期起始的扣费日。
    let anchorDay: Int

    /// 分类原始值。
    let categoryRawValue: String

    /// 扣费渠道原始值。
    let channelRawValue: String

    /// 状态原始值。
    let statusRawValue: String

    /// 取消后还能用到哪天。
    let accessEndDay: Int?

    /// 扣费前几天提醒。
    let reminderDaysBefore: Int?

    /// 备注。
    let note: String?

    /// 自动记账管的规则。
    let recurringRuleID: UUID?

    /// 创建时间。
    let createdAt: Date

    /// 最近一次修改时间。
    let updatedAt: Date

    /// 拷贝订阅当前的全部字段。
    init(subscription: UserSubscription) {
        id = subscription.id
        name = subscription.name
        amount = subscription.amount
        frequencyRawValue = subscription.frequencyRawValue
        anchorDay = subscription.anchorDay
        categoryRawValue = subscription.categoryRawValue
        channelRawValue = subscription.channelRawValue
        statusRawValue = subscription.statusRawValue
        accessEndDay = subscription.accessEndDay
        reminderDaysBefore = subscription.reminderDaysBefore
        note = subscription.note
        recurringRuleID = subscription.recurringRuleID
        createdAt = subscription.createdAt
        updatedAt = subscription.updatedAt
    }

    /// 按快照生成尚未插入 context 的订阅。
    func makeSubscription() -> UserSubscription {
        UserSubscription(
            id: id, name: name, amount: amount, frequencyRawValue: frequencyRawValue, anchorDay: anchorDay,
            categoryRawValue: categoryRawValue, channelRawValue: channelRawValue, statusRawValue: statusRawValue,
            accessEndDay: accessEndDay, reminderDaysBefore: reminderDaysBefore, note: note,
            recurringRuleID: recurringRuleID, createdAt: createdAt, updatedAt: updatedAt
        )
    }
}

/// 撤销语音会话中一次订阅改动的反向变更：把订阅和它管过的周期记账都还原成改动前的样子。
struct UserSubscriptionRevert: Equatable, Sendable {
    /// 一条规则改动前的样子。
    struct RuleState: Equatable, Sendable {
        /// 规则 UUID。
        let id: UUID

        /// 改动前的规则；为 `nil` 表示改动前没有这条规则，撤销时删掉。
        let snapshot: RecurringRuleSnapshot?
    }

    /// 订阅 UUID。
    let subscriptionID: UUID

    /// 改动前的订阅；新建时为 `nil`，撤销时删掉。
    let previous: UserSubscriptionSnapshot?

    /// 改动可能涉及的规则改动前的样子。
    let previousRules: [RuleState]
}

extension UserSubscription {
    /// 编辑页日期一行显示的日子：试用中是试用结束日，其余是不早于今天的下一次扣费；周期不认识时是起始日。
    ///
    /// 已取消的也照样往后推算，恢复订阅时直接作为预填的下一次扣费。
    ///
    /// - Parameter today: 今天的 `YYYYMMDD`。
    /// - Returns: `YYYYMMDD`。
    func displayedChargeDay(today: Int) -> Int {
        guard let frequency else { return anchorDay }
        if status == .trial, today < anchorDay { return anchorDay }
        return UserSubscriptionSchedule.nextChargeDay(onOrAfter: today, anchorDay: anchorDay, frequency: frequency)
    }
}

extension ModelContext {
    /// 按稳定 UUID 读取订阅。
    func userSubscription(id: UUID) throws -> UserSubscription? {
        let subscriptionID = id
        var descriptor = FetchDescriptor<UserSubscription>(
            predicate: #Predicate<UserSubscription> { subscription in
                subscription.id == subscriptionID
            }
        )
        descriptor.fetchLimit = 1
        return try fetch(descriptor).first
    }

    /// 管理这条周期记账的订阅；规则不是订阅自动记账建的时为 `nil`。
    ///
    /// - Parameter ruleID: 规则 UUID。
    func userSubscription(owningRuleID ruleID: UUID) throws -> UserSubscription? {
        let optionalRuleID: UUID? = ruleID
        var descriptor = FetchDescriptor<UserSubscription>(
            predicate: #Predicate<UserSubscription> { subscription in
                subscription.recurringRuleID == optionalRuleID
            }
        )
        descriptor.fetchLimit = 1
        return try fetch(descriptor).first
    }

    /// 周期记账规则被单独删掉时，解除管理它的订阅的自动记账；不保存。
    ///
    /// - Parameter ruleID: 被删除的规则 UUID。
    func detachSubscriptions(fromRuleID ruleID: UUID) throws {
        let optionalRuleID: UUID? = ruleID
        let owners = try fetch(
            FetchDescriptor<UserSubscription>(
                predicate: #Predicate<UserSubscription> { subscription in
                    subscription.recurringRuleID == optionalRuleID
                }
            )
        )
        for owner in owners {
            owner.recurringRuleID = nil
        }
    }
}
