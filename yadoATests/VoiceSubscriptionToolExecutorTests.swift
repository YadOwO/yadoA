import Foundation
import SwiftData
import Testing
@testable import yadoA

/// 使用真实 SwiftData 验证语音会话订阅工具的执行、自动记账联动、错误码与撤销。
@Suite("语音订阅工具执行", .serialized)
@MainActor
struct VoiceSubscriptionToolExecutorTests {
    private let locale = Locale(identifier: "zh-Hans")
    private let savedAt = Date(timeIntervalSince1970: 1_792_470_600) // 2026-10-20T04:30:00Z

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    // MARK: - 新建

    @Test("新建：默认只记录订阅、不建周期记账；撤销后订阅删掉")
    func createWithoutBookkeeping() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let executor = makeExecutor(container)

        let execution = executor.execute(createCall(nextChargeDate: "2026-10-28", inferredFields: [.category]))

        let saved = try #require(SavedOutput(execution.result.output))
        #expect(saved.status == .active)
        #expect(saved.nextChargeDate == "2026-10-28")
        #expect(saved.ruleID == nil)
        #expect(saved.recordedTransactionIds.isEmpty)
        let subscription = try #require(try fetchSubscription(saved.subscriptionID, in: container))
        #expect(subscription.name == "Netflix")
        #expect(subscription.amount == 68)
        #expect(subscription.frequency == .monthly)
        #expect(subscription.anchorDay == 20261028)
        #expect(subscription.category == .media)
        #expect(subscription.channel == .appStore)
        #expect(subscription.recurringRuleID == nil)
        #expect(try ruleCount(in: container) == 0)

        #expect(execution.changes.count == 1)
        let change = try #require(execution.change?.subscriptionChange)
        #expect(change.subscriptionID == saved.subscriptionID)
        #expect(change.actionText == "新建订阅")
        #expect(change.title == "Netflix")
        #expect(change.summary.hasPrefix("已新建订阅：Netflix，每月"))
        #expect(change.detail?.hasSuffix("待确认：分类") == true)
        #expect(change.hasReminder == false)

        _ = try executor.revert(execution.changes)
        #expect(try fetchSubscription(saved.subscriptionID, in: container) == nil)
    }

    @Test("新建：打开自动记账、今天扣费时当场记入一期；没给分类按订阅分类选；撤销时订阅、规则和流水一起删掉")
    func createWithBookkeepingDueToday() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let cash = try makeAccount(balance: 1000, in: container)
        let executor = makeExecutor(container)

        let execution = executor.execute(createCall(
            nextChargeDate: "2026-10-20",
            reminderDaysBefore: 3,
            bookkeeping: VoiceSubscriptionBookkeeping(accountId: cash.uuidString, categoryId: nil)
        ))

        let saved = try #require(SavedOutput(execution.result.output))
        let ruleID = try #require(saved.ruleID)
        let occurrenceID = RecurringRule.occurrenceID(ruleID: ruleID, day: 20261020)
        #expect(saved.recordedTransactionIds == [occurrenceID.uuidString])
        let rule = try #require(try fetchRule(ruleID, in: container))
        #expect(rule.categoryKey == ExpenseCategory.entertainment.rawValue)
        #expect(rule.note == "Netflix")
        #expect(rule.nextDueDay == 20261120)
        #expect(try balance(cash, in: container) == 932)

        #expect(execution.changes.count == 2)
        #expect(execution.changes.first?.subscriptionChange?.hasReminder == true)
        #expect(execution.changes.last?.entryChange?.transactionID == occurrenceID)

        _ = try executor.revert(execution.changes)
        #expect(try fetchSubscription(saved.subscriptionID, in: container) == nil)
        #expect(try fetchRule(ruleID, in: container) == nil)
        #expect(try transactionCount(in: container) == 0)
        #expect(try balance(cash, in: container) == 1000)
    }

    @Test("新建：周期不是订阅可选的、扣费日早于今天、状态为已取消时不合法")
    func createRejectsInvalidInput() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let executor = makeExecutor(container)

        #expect(executor.execute(createCall(frequency: .daily, nextChargeDate: "2026-10-28")).result.output == .failure(.invalidInput))
        #expect(executor.execute(createCall(nextChargeDate: "2026-10-19")).result.output == .failure(.invalidInput))
        #expect(executor.execute(createCall(status: .cancelled, nextChargeDate: "2026-10-28")).result.output == .failure(.invalidInput))
        #expect(try subscriptionCount(in: container) == 0)
    }

    // MARK: - 修改

    @Test("取消：可用日期默认取下次扣费的前一天，规则今天以后不再记；撤销后都还原")
    func cancelSubscription() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let cash = try makeAccount(balance: 1000, in: container)
        let executor = makeExecutor(container)
        let created = try #require(SavedOutput(executor.execute(createCall(
            nextChargeDate: "2026-10-28",
            bookkeeping: VoiceSubscriptionBookkeeping(accountId: cash.uuidString, categoryId: nil)
        )).result.output))
        let ruleID = try #require(created.ruleID)

        let execution = executor.execute(updateCall(created.subscriptionID, patch: VoiceSubscriptionPatch(status: .cancelled)))

        let saved = try #require(SavedOutput(execution.result.output))
        #expect(saved.status == .cancelled)
        #expect(saved.nextChargeDate == nil)
        #expect(saved.ruleID == ruleID)
        let subscription = try #require(try fetchSubscription(created.subscriptionID, in: container))
        #expect(subscription.status == .cancelled)
        #expect(subscription.accessEndDay == 20261027)
        #expect(try fetchRule(ruleID, in: container)?.endDay == 20261020)
        let change = try #require(execution.change?.subscriptionChange)
        #expect(change.actionText == "已取消")
        #expect(change.summary == "已取消订阅：Netflix")

        _ = try executor.revert(execution.changes)
        let restored = try #require(try fetchSubscription(created.subscriptionID, in: container))
        #expect(restored.status == .active)
        #expect(restored.accessEndDay == nil)
        #expect(try fetchRule(ruleID, in: container)?.endDay == nil)
    }

    @Test("关闭自动记账：默认删掉那条周期记账，说保留时留下；撤销后订阅重新指向它")
    func turnOffBookkeeping() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let cash = try makeAccount(balance: 1000, in: container)
        let executor = makeExecutor(container)
        let created = try #require(SavedOutput(executor.execute(createCall(
            nextChargeDate: "2026-10-28",
            bookkeeping: VoiceSubscriptionBookkeeping(accountId: cash.uuidString, categoryId: nil)
        )).result.output))
        let ruleID = try #require(created.ruleID)

        let removed = executor.execute(updateCall(created.subscriptionID, patch: VoiceSubscriptionPatch(bookkeeping: .clear)))
        #expect(try #require(SavedOutput(removed.result.output)).ruleID == nil)
        #expect(try fetchRule(ruleID, in: container) == nil)
        #expect(removed.change?.subscriptionChange?.summary.contains("已关闭 Netflix 的自动记账") == true)

        _ = try executor.revert(removed.changes)
        #expect(try fetchRule(ruleID, in: container) != nil)
        #expect(try fetchSubscription(created.subscriptionID, in: container)?.recurringRuleID == ruleID)

        let kept = executor.execute(updateCall(
            created.subscriptionID,
            patch: VoiceSubscriptionPatch(bookkeeping: .clear, keepsRecurringRule: true)
        ))
        #expect(kept.result.output.isSuccess)
        #expect(try fetchRule(ruleID, in: container) != nil)
        #expect(try fetchSubscription(created.subscriptionID, in: container)?.recurringRuleID == nil)
    }

    @Test("打开自动记账：新建规则，撤销时删掉；已取消的订阅不能新打开")
    func turnOnBookkeeping() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let cash = try makeAccount(balance: 1000, in: container)
        let executor = makeExecutor(container)
        let created = try #require(SavedOutput(executor.execute(createCall(nextChargeDate: "2026-10-28")).result.output))
        let turnOn = VoiceSubscriptionPatch(bookkeeping: .set(VoiceSubscriptionBookkeepingPatch(accountId: cash.uuidString)))

        let execution = executor.execute(updateCall(created.subscriptionID, patch: turnOn))

        let ruleID = try #require(try #require(SavedOutput(execution.result.output)).ruleID)
        #expect(try fetchRule(ruleID, in: container)?.categoryKey == ExpenseCategory.entertainment.rawValue)
        #expect(execution.change?.subscriptionChange?.summary == "已为 Netflix 打开自动记账")

        _ = try executor.revert(execution.changes)
        #expect(try fetchRule(ruleID, in: container) == nil)
        #expect(try fetchSubscription(created.subscriptionID, in: container)?.recurringRuleID == nil)

        _ = executor.execute(updateCall(created.subscriptionID, patch: VoiceSubscriptionPatch(status: .cancelled)))
        #expect(executor.execute(updateCall(created.subscriptionID, patch: turnOn)).result.output == .failure(.invalidInput))
        #expect(try ruleCount(in: container) == 0)
    }

    @Test("只改金额时保留原来的扣费排期，规则跟着改金额")
    func updateAmountKeepsSchedule() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let cash = try makeAccount(balance: 1000, in: container)
        let executor = makeExecutor(container)
        let created = try #require(SavedOutput(executor.execute(createCall(
            nextChargeDate: "2026-10-31",
            bookkeeping: VoiceSubscriptionBookkeeping(accountId: cash.uuidString, categoryId: nil)
        )).result.output))

        let execution = executor.execute(updateCall(created.subscriptionID, patch: VoiceSubscriptionPatch(amount: "78")))

        #expect(execution.change?.subscriptionChange?.summary == "已修改订阅：Netflix")
        let subscription = try #require(try fetchSubscription(created.subscriptionID, in: container))
        #expect(subscription.amount == 78)
        #expect(subscription.anchorDay == 20261031)
        let rule = try #require(try fetchRule(try #require(created.ruleID), in: container))
        #expect(rule.amount == 78)
        #expect(rule.nextDueDay == 20261031)
    }

    @Test("状态来自更新版本的订阅不能修改，不存在的订阅返回 not_found")
    func updateRejectsUnknownAndMissing() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let executor = makeExecutor(container)
        let unknown = UserSubscription(
            id: UUID(), name: "未来", amount: 10, frequencyRawValue: RecurringFrequency.monthly.rawValue, anchorDay: 20261028,
            categoryRawValue: "media", channelRawValue: "other", statusRawValue: "paused", accessEndDay: nil,
            reminderDaysBefore: nil, note: nil, recurringRuleID: nil, createdAt: savedAt, updatedAt: savedAt
        )
        let context = ModelContext(container)
        context.insert(unknown)
        try context.save()

        #expect(executor.execute(updateCall(unknown.id, patch: VoiceSubscriptionPatch(amount: "20"))).result.output
            == .failure(.notEditable))
        #expect(executor.execute(updateCall(UUID(), patch: VoiceSubscriptionPatch(amount: "20"))).result.output
            == .failure(.notFound))
    }

    // MARK: - 删除

    @Test("删除：默认连周期记账一起删，已记的流水保留；撤销后订阅和规则都回来")
    func deleteWithRule() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let cash = try makeAccount(balance: 1000, in: container)
        let executor = makeExecutor(container)
        let created = try #require(SavedOutput(executor.execute(createCall(
            nextChargeDate: "2026-10-20",
            bookkeeping: VoiceSubscriptionBookkeeping(accountId: cash.uuidString, categoryId: nil)
        )).result.output))
        let ruleID = try #require(created.ruleID)

        let execution = executor.execute(.deleteSubscription(id: "c", input: VoiceDeleteSubscriptionInput(
            subscriptionId: created.subscriptionID.uuidString, keepsRecurringRule: false
        )))

        #expect(execution.result.output == .succeeded)
        #expect(try fetchSubscription(created.subscriptionID, in: container) == nil)
        #expect(try fetchRule(ruleID, in: container) == nil)
        #expect(try transactionCount(in: container) == 1)
        let change = try #require(execution.change?.subscriptionChange)
        #expect(change.subscriptionID == nil)
        #expect(change.summary == "已删除订阅：Netflix，已记入的流水保留")

        _ = try executor.revert(execution.changes)
        #expect(try fetchSubscription(created.subscriptionID, in: container)?.recurringRuleID == ruleID)
        #expect(try fetchRule(ruleID, in: container) != nil)
    }

    // MARK: - 查询

    @Test("查询：顺序与订阅列表一致，合计只算订阅中的并四舍五入到分")
    func searchOrdersAndTotals() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let executor = makeExecutor(container)
        let video = try #require(SavedOutput(executor.execute(createCall(
            name: "视频会员", amount: "198", frequency: .yearly, nextChargeDate: "2026-12-01"
        )).result.output))
        let netflix = try #require(SavedOutput(executor.execute(createCall(nextChargeDate: "2026-10-28")).result.output))
        let trial = try #require(SavedOutput(executor.execute(createCall(
            name: "ChatGPT Plus", amount: "20", category: .ai, status: .trial, nextChargeDate: "2026-10-25"
        )).result.output))
        let weekly = try #require(SavedOutput(executor.execute(createCall(
            name: "周报", amount: "10", frequency: .weekly, category: .software, nextChargeDate: "2026-10-22"
        )).result.output))
        _ = executor.execute(updateCall(weekly.subscriptionID, patch: VoiceSubscriptionPatch(status: .cancelled)))

        let output = executor.execute(.searchSubscriptions(id: "c", input: VoiceSearchSubscriptionsInput(
            filter: VoiceSubscriptionFilter(), limit: 20
        ))).result.output
        guard case let .subscriptionSearchResult(total, monthlyTotal, yearlyTotal, items) = output else {
            Issue.record("应为订阅查询结果")
            return
        }
        #expect(total == 4)
        // 订阅中、试用中的按下次扣费从近到远，已取消的放后面
        #expect(items.map(\.id) == [trial, netflix, video, weekly].map(\.subscriptionID.uuidString))
        #expect(items.first?.status == .trial)
        #expect(items.first?.nextChargeDate == "2026-10-25")
        #expect(items.last?.status == .cancelled)
        #expect(items.last?.accessEndDate == "2026-10-21")
        // 只算订阅中的：68 × 12 + 198 = 1014，每月 84.5
        #expect(yearlyTotal == "1014")
        #expect(monthlyTotal == "84.5")

        let filtered = executor.execute(.searchSubscriptions(id: "c", input: VoiceSearchSubscriptionsInput(
            filter: VoiceSubscriptionFilter(categories: [.media], keyword: "net"), limit: 20
        ))).result.output
        guard case let .subscriptionSearchResult(filteredTotal, _, _, filteredItems) = filtered else {
            Issue.record("应为订阅查询结果")
            return
        }
        #expect(filteredTotal == 1)
        #expect(filteredItems.first?.id == netflix.subscriptionID.uuidString)
    }

    // MARK: - 与周期记账工具

    @Test("订阅管的周期记账：查询时标出订阅，不能用周期记账工具单独修改或删除")
    func recurringToolsRespectSubscriptionOwnership() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let cash = try makeAccount(balance: 1000, in: container)
        let executor = makeExecutor(container)
        let created = try #require(SavedOutput(executor.execute(createCall(
            nextChargeDate: "2026-10-28",
            bookkeeping: VoiceSubscriptionBookkeeping(accountId: cash.uuidString, categoryId: nil)
        )).result.output))
        let ruleID = try #require(created.ruleID)

        let search = executor.execute(.searchRecurringRules(id: "c", input: VoiceSearchRecurringRulesInput(
            filter: VoiceRecurringRuleFilter(), limit: 20
        ))).result.output
        guard case let .recurringRuleSearchResult(_, items) = search else {
            Issue.record("应为周期记账查询结果")
            return
        }
        #expect(items.first?.subscriptionId == created.subscriptionID.uuidString)

        let update = executor.execute(.updateRecurringRule(id: "c", input: VoiceUpdateRecurringRuleInput(
            ruleId: ruleID.uuidString, patch: VoiceRecurringRulePatch(isPaused: true)
        )))
        #expect(update.result.output == .failure(.notEditable))
        let delete = executor.execute(.deleteRecurringRule(id: "c", input: VoiceDeleteRecurringRuleInput(ruleId: ruleID.uuidString)))
        #expect(delete.result.output == .failure(.notEditable))
        #expect(try fetchRule(ruleID, in: container)?.pausedAt == nil)
    }

    // MARK: - 结果提示

    @Test("结果提示先说订阅，再说自动记账当场记入的流水")
    func summaryOrdersSubscriptionFirst() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let cash = try makeAccount(balance: 1000, in: container)
        let executor = makeExecutor(container)

        let execution = executor.execute(createCall(
            nextChargeDate: "2026-10-20",
            bookkeeping: VoiceSubscriptionBookkeeping(accountId: cash.uuidString, categoryId: nil)
        ))

        let text = VoiceSessionSummary.text(for: execution.changes, locale: locale)
        #expect(text.hasPrefix("已新建订阅：Netflix，每月"))
        #expect(text.contains("；已记 1 笔"))
    }

    // MARK: - 辅助

    /// 解开新建、修改订阅的回传结果。
    private struct SavedOutput {
        let subscriptionID: UUID
        let status: VoiceSubscriptionPhase
        let nextChargeDate: String?
        let ruleID: UUID?
        let recordedTransactionIds: [String]

        init?(_ output: VoiceToolOutput) {
            guard case let .subscriptionSaved(id, status, nextChargeDate, ruleID, recorded) = output,
                  let subscriptionID = UUID(uuidString: id)
            else { return nil }
            self.subscriptionID = subscriptionID
            self.status = status
            self.nextChargeDate = nextChargeDate
            self.ruleID = ruleID.flatMap(UUID.init(uuidString:))
            recordedTransactionIds = recorded
        }
    }

    private func makeExecutor(_ container: ModelContainer) -> VoiceToolExecutor {
        let date = savedAt
        return VoiceToolExecutor(container: container, locale: locale, calendar: calendar, now: { date })
    }

    private func createCall(
        name: String = "Netflix",
        amount: String = "68",
        frequency: VoiceRecurringFrequency = .monthly,
        category: VoiceSubscriptionCategory = .media,
        status: VoiceSubscriptionStatus = .active,
        nextChargeDate: String,
        reminderDaysBefore: Int? = nil,
        bookkeeping: VoiceSubscriptionBookkeeping? = nil,
        inferredFields: [VoiceSubscriptionInferredField] = []
    ) -> VoiceToolCall {
        .createSubscription(id: "c", input: VoiceCreateSubscriptionInput(
            name: name, amount: amount, frequency: frequency, category: category, channel: .appStore, status: status,
            nextChargeDate: nextChargeDate, reminderDaysBefore: reminderDaysBefore, note: nil, bookkeeping: bookkeeping,
            inferredFields: inferredFields
        ))
    }

    private func updateCall(_ subscriptionID: UUID, patch: VoiceSubscriptionPatch) -> VoiceToolCall {
        .updateSubscription(id: "c", input: VoiceUpdateSubscriptionInput(subscriptionId: subscriptionID.uuidString, patch: patch))
    }

    private func makeAccount(balance: Decimal, in container: ModelContainer) throws -> UUID {
        let account = Account(
            id: UUID(), typeRawValue: AccountType.cash.rawValue, templateID: nil, name: "现金",
            note: nil, lastFourDigits: nil, balance: balance, currencyCode: "CNY",
            createdAt: savedAt, updatedAt: savedAt, deactivatedAt: nil
        )
        let context = ModelContext(container)
        context.insert(account)
        try context.save()
        return account.id
    }

    private func fetchSubscription(_ id: UUID, in container: ModelContainer) throws -> UserSubscription? {
        try ModelContext(container).userSubscription(id: id)
    }

    private func fetchRule(_ id: UUID, in container: ModelContainer) throws -> RecurringRule? {
        try ModelContext(container).recurringRule(id: id)
    }

    private func subscriptionCount(in container: ModelContainer) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<UserSubscription>())
    }

    private func ruleCount(in container: ModelContainer) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<RecurringRule>())
    }

    private func balance(_ id: UUID, in container: ModelContainer) throws -> Decimal {
        try #require(try ModelContext(container).fetch(FetchDescriptor<Account>()).first { $0.id == id }).balance
    }

    private func transactionCount(in container: ModelContainer) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<AccountTransaction>())
    }
}
