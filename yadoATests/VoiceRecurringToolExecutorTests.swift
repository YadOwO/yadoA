import Foundation
import SwiftData
import Testing
@testable import yadoA

/// 使用真实 SwiftData 验证语音会话周期记账工具的执行、错误码与撤销。
@Suite("语音周期记账工具执行", .serialized)
@MainActor
struct VoiceRecurringToolExecutorTests {
    private let locale = Locale(identifier: "zh-Hans")
    private let savedAt = Date(timeIntervalSince1970: 1_792_470_600) // 2026-10-20T04:30:00Z

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    // MARK: - 新建

    @Test("新建：第一期在以后时只建规则、不记流水，起始日为第一期")
    func createFutureRule() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let cash = try makeAccount(balance: 1000, in: container)
        let executor = makeExecutor(container)

        let execution = executor.execute(createCall(accountID: cash, nextDueDate: "2026-11-01", inferredFields: [.account]))

        let saved = try #require(SavedOutput(execution.result.output))
        #expect(saved.status == .active)
        #expect(saved.nextDueDate == "2026-11-01")
        #expect(saved.recordedTransactionIds.isEmpty)
        let rule = try #require(try fetchRule(saved.ruleID, in: container))
        #expect(rule.entryType == .expense)
        #expect(rule.categoryKey == ExpenseCategory.housing.rawValue)
        #expect(rule.amount == 800)
        #expect(rule.note == "房租")
        #expect(rule.frequency == .monthly)
        #expect(rule.anchorDay == 20261101)
        #expect(rule.endDay == nil)
        #expect(rule.pausedAt == nil)
        #expect(try transactionCount(in: container) == 0)

        #expect(execution.changes.count == 1)
        let change = try #require(execution.change?.recurringChange)
        #expect(change.ruleID == saved.ruleID)
        #expect(change.actionText == "新建周期记账")
        #expect(change.title == "房租")
        #expect(change.formattedAmount.contains("800.00"))
        #expect(change.detail?.hasPrefix("每月 · 下次") == true)
        #expect(change.detail?.hasSuffix("待确认：账户") == true)
        #expect(change.summary.hasPrefix("已新建周期记账：房租，每月"))
        #expect(change.inverse == .remove(ruleID: saved.ruleID))
    }

    @Test("新建：第一期是今天时当场记入，改动按「规则 → 流水」排列，撤销时规则和流水一起删除")
    func createDueTodayRecordsAndReverts() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let cash = try makeAccount(balance: 1000, in: container)
        let executor = makeExecutor(container)

        let execution = executor.execute(createCall(accountID: cash, nextDueDate: "2026-10-20"))

        let saved = try #require(SavedOutput(execution.result.output))
        let occurrenceID = RecurringRule.occurrenceID(ruleID: saved.ruleID, day: 20261020)
        #expect(saved.status == .active)
        #expect(saved.nextDueDate == "2026-11-20")
        #expect(saved.recordedTransactionIds == [occurrenceID.uuidString])
        #expect(try balance(cash, in: container) == 200)
        let transaction = try fetchTransaction(occurrenceID, in: container)
        #expect(transaction.recurringRuleID == saved.ruleID)
        #expect(transaction.transactionDay == 20261020)

        #expect(execution.changes.count == 2)
        #expect(execution.changes.first?.recurringChange?.ruleID == saved.ruleID)
        let entry = try #require(execution.changes.last?.entryChange)
        #expect(entry.kind == .created)
        #expect(entry.transactionID == occurrenceID)
        #expect(entry.transactionDay == 20261020)
        #expect(entry.inverse == .delete(occurrenceID))

        // 先说规则，再说当场记入的流水
        let summary = VoiceSessionSummary.text(for: execution.changes, locale: locale)
        #expect(summary.hasPrefix("已新建周期记账：房租"))
        #expect(summary.contains("；已记 1 笔"))

        _ = try executor.revert(execution.changes)
        #expect(try fetchRule(saved.ruleID, in: container) == nil)
        #expect(try transactionCount(in: container) == 0)
        #expect(try balance(cash, in: container) == 1000)
    }

    @Test("新建：结束日期就是今天时记入这一期后即为已结束")
    func createEndingTodayFinishes() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let cash = try makeAccount(balance: 1000, in: container)
        let executor = makeExecutor(container)

        let saved = try #require(SavedOutput(executor.execute(
            createCall(accountID: cash, nextDueDate: "2026-10-20", endDate: "2026-10-20")
        ).result.output))

        #expect(saved.status == .finished)
        #expect(saved.recordedTransactionIds.count == 1)
        #expect(try #require(try fetchRule(saved.ruleID, in: container)).isFinished)
    }

    @Test("新建：下一期早于今天、结束日期早于第一期、金额或日期格式不对、账户已停用都返回 invalid_input，不写入")
    func createErrors() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let cash = try makeAccount(balance: 1000, in: container)
        let inactive = try makeAccount(balance: 0, isActive: false, in: container)
        let executor = makeExecutor(container)
        func create(
            accountID: String? = nil,
            amount: String = "800",
            nextDueDate: String = "2026-11-01",
            endDate: String? = nil
        ) -> VoiceToolOutput {
            executor.execute(.createRecurringRule(id: "c", input: VoiceCreateRecurringRuleInput(
                type: .expense, amount: amount, accountId: accountID ?? cash.uuidString,
                categoryId: ExpenseCategory.housing.rawValue, note: nil, frequency: .monthly,
                nextDueDate: nextDueDate, endDate: endDate, inferredFields: []
            ))).result.output
        }

        // 补记过去的账由 create_transaction 负责
        #expect(create(nextDueDate: "2026-10-19") == .failure(.invalidInput))
        #expect(create(endDate: "2026-10-31") == .failure(.invalidInput))
        #expect(create(amount: "0") == .failure(.invalidInput))
        #expect(create(amount: "12.345") == .failure(.invalidInput))
        #expect(create(nextDueDate: "2026-13-01") == .failure(.invalidInput))
        #expect(create(endDate: "下个月") == .failure(.invalidInput))
        #expect(create(accountID: "not-a-uuid") == .failure(.invalidInput))
        #expect(create(accountID: inactive.uuidString) == .failure(.invalidInput))
        #expect(try ruleCount(in: container) == 0)
        #expect(try transactionCount(in: container) == 0)
    }

    // MARK: - 修改

    @Test("暂停后恢复：暂停期间的日期不补记，恢复后今天正好到期的当场记入；恢复和改内容按顺序说明")
    func pauseThenResume() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let cash = try makeAccount(balance: 1000, in: container)
        let executor = makeExecutor(container)
        let ruleID = try createRule(accountID: cash, nextDueDate: "2026-10-25", executor: executor)

        let paused = executor.execute(updateCall(ruleID, patch: VoiceRecurringRulePatch(isPaused: true)))
        let pausedOutput = try #require(SavedOutput(paused.result.output))
        #expect(pausedOutput.status == .paused)
        #expect(pausedOutput.recordedTransactionIds.isEmpty)
        let pausedChange = try #require(paused.change?.recurringChange)
        #expect(pausedChange.actionText == "已暂停")
        #expect(pausedChange.summary == "已暂停周期记账：房租")
        #expect(pausedChange.detail?.contains("已暂停") == true)
        #expect(try #require(try fetchRule(ruleID, in: container)).pausedAt == savedAt)

        // 一个多月后恢复，同时改金额：10 月 25 日那期跳过，11 月 25 日是今天，按新金额当场记入
        let later = makeExecutor(container, now: savedAt.addingTimeInterval(36 * 86_400))
        let resumed = later.execute(updateCall(ruleID, patch: VoiceRecurringRulePatch(amount: "900", isPaused: false)))

        let resumedOutput = try #require(SavedOutput(resumed.result.output))
        let occurrenceID = RecurringRule.occurrenceID(ruleID: ruleID, day: 20261125)
        #expect(resumedOutput.status == .active)
        #expect(resumedOutput.nextDueDate == "2026-12-25")
        #expect(resumedOutput.recordedTransactionIds == [occurrenceID.uuidString])
        #expect(try fetchTransaction(occurrenceID, in: container).amount == 900)
        #expect(try transactionCount(in: container) == 1)
        let rule = try #require(try fetchRule(ruleID, in: container))
        #expect(rule.pausedAt == nil)
        #expect(rule.anchorDay == 20261025)
        let resumedChange = try #require(resumed.change?.recurringChange)
        #expect(resumedChange.actionText == "已恢复")
        #expect(resumedChange.summary == "已恢复周期记账：房租；已修改周期记账：房租")
        #expect(resumed.changes.count == 2)
    }

    @Test("修改内容：只改给出的字段，清空备注和结束日期；撤销后还原")
    func updateContentAndRevert() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let cash = try makeAccount(balance: 1000, in: container)
        let executor = makeExecutor(container)
        let ruleID = try createRule(accountID: cash, nextDueDate: "2026-11-01", endDate: "2027-11-01", executor: executor)

        let execution = executor.execute(updateCall(ruleID, patch: VoiceRecurringRulePatch(
            amount: "850", note: .clear, endDate: .clear
        )))

        let saved = try #require(SavedOutput(execution.result.output))
        #expect(saved.status == .active)
        #expect(saved.nextDueDate == "2026-11-01")
        #expect(saved.recordedTransactionIds.isEmpty)
        let updated = try #require(try fetchRule(ruleID, in: container))
        #expect(updated.amount == 850)
        #expect(updated.note == nil)
        #expect(updated.endDay == nil)
        #expect(updated.anchorDay == 20261101)
        #expect(updated.categoryKey == ExpenseCategory.housing.rawValue)
        #expect(updated.frequency == .monthly)
        let change = try #require(execution.change?.recurringChange)
        // 备注清空后用分类名称称呼规则
        let housingTitle = categoryTitle(.expense, ExpenseCategory.housing.rawValue)
        #expect(change.actionText == "已修改")
        #expect(change.title == housingTitle)
        #expect(change.summary == "已修改周期记账：\(housingTitle)")
        #expect(execution.changes.count == 1)

        _ = try executor.revert(execution.changes)
        let reverted = try #require(try fetchRule(ruleID, in: container))
        #expect(reverted.amount == 800)
        #expect(reverted.note == "房租")
        #expect(reverted.endDay == 20271101)
    }

    @Test("改排期：下一期改到今天时重置起始日并当场记入；撤销后排期复原、记入的流水删除")
    func rescheduleToTodayRecordsAndReverts() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let cash = try makeAccount(balance: 1000, in: container)
        let executor = makeExecutor(container)
        let ruleID = try createRule(accountID: cash, nextDueDate: "2026-11-01", executor: executor)

        let execution = executor.execute(updateCall(ruleID, patch: VoiceRecurringRulePatch(
            frequency: .weekly, nextDueDate: "2026-10-20"
        )))

        let saved = try #require(SavedOutput(execution.result.output))
        let occurrenceID = RecurringRule.occurrenceID(ruleID: ruleID, day: 20261020)
        #expect(saved.nextDueDate == "2026-10-27")
        #expect(saved.recordedTransactionIds == [occurrenceID.uuidString])
        let rule = try #require(try fetchRule(ruleID, in: container))
        #expect(rule.anchorDay == 20261020)
        #expect(rule.frequency == .weekly)
        #expect(execution.changes.count == 2)
        #expect(execution.changes.last?.entryChange?.transactionID == occurrenceID)
        #expect(try balance(cash, in: container) == 200)

        _ = try executor.revert(execution.changes)
        let reverted = try #require(try fetchRule(ruleID, in: container))
        #expect(reverted.nextDueDay == 20261101)
        #expect(reverted.anchorDay == 20261101)
        #expect(reverted.frequency == .monthly)
        #expect(try transactionCount(in: container) == 0)
        #expect(try balance(cash, in: container) == 1000)
    }

    @Test("修改：找不到规则返回 not_found；没有要改的、下一期早于今天、结束日期早于下一期返回 invalid_input，规则不变")
    func updateErrors() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let cash = try makeAccount(balance: 1000, in: container)
        let executor = makeExecutor(container)
        let ruleID = try createRule(accountID: cash, nextDueDate: "2026-11-01", executor: executor)
        func update(_ id: String, _ patch: VoiceRecurringRulePatch) -> VoiceToolOutput {
            executor.execute(.updateRecurringRule(id: "c", input: VoiceUpdateRecurringRuleInput(ruleId: id, patch: patch)))
                .result.output
        }

        #expect(update(UUID().uuidString, VoiceRecurringRulePatch(amount: "900")) == .failure(.notFound))
        #expect(update("R1", VoiceRecurringRulePatch(amount: "900")) == .failure(.notFound))
        #expect(update(ruleID.uuidString, VoiceRecurringRulePatch()) == .failure(.invalidInput))
        #expect(update(ruleID.uuidString, VoiceRecurringRulePatch(amount: "-1")) == .failure(.invalidInput))
        #expect(update(ruleID.uuidString, VoiceRecurringRulePatch(nextDueDate: "2026-10-19")) == .failure(.invalidInput))
        #expect(update(ruleID.uuidString, VoiceRecurringRulePatch(endDate: .set("2026-10-31"))) == .failure(.invalidInput))
        // 暂停与非法内容一起给出时整次不生效，不会只暂停
        #expect(update(ruleID.uuidString, VoiceRecurringRulePatch(amount: "0", isPaused: true)) == .failure(.invalidInput))

        let rule = try #require(try fetchRule(ruleID, in: container))
        #expect(rule.amount == 800)
        #expect(rule.nextDueDay == 20261101)
        #expect(rule.endDay == nil)
        #expect(rule.pausedAt == nil)
    }

    // MARK: - 删除

    @Test("删除：已记入的流水保留；撤销后规则按原样回来")
    func deleteKeepsEntriesAndReverts() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let cash = try makeAccount(balance: 1000, in: container)
        let executor = makeExecutor(container)
        let ruleID = try createRule(accountID: cash, nextDueDate: "2026-10-20", executor: executor)
        let before = RecurringRuleSnapshot(rule: try #require(try fetchRule(ruleID, in: container)))

        let execution = executor.execute(.deleteRecurringRule(id: "c", input: VoiceDeleteRecurringRuleInput(ruleId: ruleID.uuidString)))

        #expect(execution.result.output == .succeeded)
        #expect(try fetchRule(ruleID, in: container) == nil)
        #expect(try transactionCount(in: container) == 1)
        #expect(try balance(cash, in: container) == 200)
        let change = try #require(execution.change?.recurringChange)
        #expect(change.ruleID == nil)
        #expect(change.actionText == "已删除")
        #expect(change.detail == "每月 · 已记入的流水保留")
        #expect(change.summary == "已删除周期记账：房租，已记入的流水保留")
        #expect(execution.changes.count == 1)

        _ = try executor.revert(execution.changes)
        let restored = try #require(try fetchRule(ruleID, in: container))
        #expect(RecurringRuleSnapshot(rule: restored) == before)
        #expect(try transactionCount(in: container) == 1)
    }

    @Test("删除：找不到规则返回 not_found")
    func deleteUnknownRule() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let executor = makeExecutor(container)

        for id in [UUID().uuidString, "R1"] {
            let execution = executor.execute(.deleteRecurringRule(id: "c", input: VoiceDeleteRecurringRuleInput(ruleId: id)))
            #expect(execution.result.output == .failure(.notFound))
            #expect(execution.changes.isEmpty)
        }
    }

    // MARK: - 查询

    @Test("查询规则：与周期记账列表同样的顺序，按类型、分类、账户、状态、关键词过滤，total 不受 limit 影响")
    func searchRules() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let cash = try makeAccount(balance: 1000, in: container)
        let executor = makeExecutor(container)
        let rent = try createRule(accountID: cash, nextDueDate: "2026-11-01", executor: executor)
        let membership = try createRule(
            accountID: cash, categoryID: ExpenseCategory.dining.rawValue, amount: "30", note: "会员",
            nextDueDate: "2026-10-25", executor: executor
        )
        let salary = try createRule(
            accountID: cash, type: .income, categoryID: IncomeCategory.salary.rawValue, amount: "10000", note: "工资",
            nextDueDate: "2026-10-31", executor: executor
        )
        _ = executor.execute(updateCall(salary, patch: VoiceRecurringRulePatch(isPaused: true)))
        let parking = try createRule(
            accountID: cash, categoryID: ExpenseCategory.dining.rawValue, amount: "20", note: "停车",
            nextDueDate: "2026-10-20", endDate: "2026-10-20", executor: executor
        )
        func search(_ filter: VoiceRecurringRuleFilter = VoiceRecurringRuleFilter(), limit: Int = 20) -> (total: Int, items: [VoiceRecurringRuleItem]) {
            let output = executor.execute(.searchRecurringRules(id: "c", input: VoiceSearchRecurringRulesInput(filter: filter, limit: limit)))
            guard case let .recurringRuleSearchResult(total, items) = output.result.output else {
                Issue.record("应为周期记账查询结果")
                return (0, [])
            }
            #expect(output.changes.isEmpty)
            return (total, items)
        }
        func ids(_ result: (total: Int, items: [VoiceRecurringRuleItem])) -> [UUID] {
            result.items.compactMap { UUID(uuidString: $0.id) }
        }

        // 正常的按下一期从近到远，其次是暂停的，已结束的放最后
        let all = search()
        #expect(ids(all) == [membership, rent, salary, parking])
        #expect(all.items.map(\.status) == [.active, .active, .paused, .finished])
        let rentItem = try #require(all.items.first { $0.id == rent.uuidString })
        #expect(rentItem == VoiceRecurringRuleItem(
            id: rent.uuidString, type: .expense, amount: "800", categoryId: ExpenseCategory.housing.rawValue,
            accountId: cash.uuidString, note: "房租", frequency: .monthly, nextDueDate: "2026-11-01", endDate: nil,
            status: .active
        ))
        let parkingItem = try #require(all.items.last)
        #expect(parkingItem.nextDueDate == "2026-11-20")
        #expect(parkingItem.endDate == "2026-10-20")

        let limited = search(limit: 2)
        #expect(limited.total == 4)
        #expect(ids(limited) == [membership, rent])
        #expect(ids(search(VoiceRecurringRuleFilter(statuses: [.paused, .finished]))) == [salary, parking])
        #expect(ids(search(VoiceRecurringRuleFilter(type: .income))) == [salary])
        #expect(ids(search(VoiceRecurringRuleFilter(categoryIds: [ExpenseCategory.housing.rawValue]))) == [rent])
        #expect(search(VoiceRecurringRuleFilter(accountIds: [cash.uuidString])).total == 4)
        #expect(search(VoiceRecurringRuleFilter(accountIds: [UUID().uuidString])).total == 0)
        #expect(ids(search(VoiceRecurringRuleFilter(keyword: " 房租 "))) == [rent])
        // 关键词也匹配分类名称
        let diningTitle = categoryTitle(.expense, ExpenseCategory.dining.rawValue)
        #expect(ids(search(VoiceRecurringRuleFilter(keyword: diningTitle))) == [membership, parking])
    }

    @Test("查询流水：周期记账自动记入的带规则 id，手动记的为空")
    func searchTransactionsIncludesRecurringRuleID() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let cash = try makeAccount(balance: 1000, in: container)
        let executor = makeExecutor(container)
        let ruleID = try createRule(accountID: cash, nextDueDate: "2026-10-20", executor: executor)
        let manual = executor.execute(.createTransaction(id: "c", input: VoiceCreateTransactionInput(
            type: .expense, amount: "20", accountId: cash.uuidString, categoryId: ExpenseCategory.dining.rawValue,
            date: "2026-10-20", note: "午饭", inferredFields: []
        )))
        let manualID = try #require(manual.change?.entryChange?.transactionID)

        let output = executor.execute(.searchTransactions(id: "c", input: VoiceSearchTransactionsInput(
            filter: VoiceTransactionFilter(dateFrom: "2026-10-01", dateTo: "2026-10-31"), limit: 10
        ))).result.output

        guard case let .searchResult(total, items) = output else {
            Issue.record("应为流水查询结果")
            return
        }
        #expect(total == 2)
        let generatedID = RecurringRule.occurrenceID(ruleID: ruleID, day: 20261020)
        #expect(items.first { $0.id == generatedID.uuidString }?.recurringRuleId == ruleID.uuidString)
        let manualItem = try #require(items.first { $0.id == manualID.uuidString })
        #expect(manualItem.recurringRuleId == nil)
    }

    // MARK: - 结果提示

    @Test("结果提示先说周期记账，再说收支流水，最后说账户改动")
    func summaryOrdersRecurringFirst() {
        let recurring = VoiceChange.recurring(VoiceRecurringChange(
            ruleID: UUID(), actionText: "新建周期记账", title: "房租", symbolName: "house.fill", formattedAmount: "¥800.00",
            detail: nil, summary: "已新建周期记账：房租，每月 ¥800.00", inverse: .remove(ruleID: UUID())
        ))
        let entry = VoiceChange.entry(VoiceEntryChange(
            kind: .created, transactionID: UUID(), transactionDay: 20261020, row: nil, accountName: nil, label: "房租",
            formattedAmount: "¥800.00", inferredFields: [], inverse: .delete(UUID()), highlight: nil
        ))
        let account = VoiceChange.account(VoiceAccountChange(
            accountIDs: [UUID()], actionText: "调整余额", title: "微信", symbolName: "message.fill", formattedAmount: "¥487.50",
            detail: nil, summary: "已把微信的余额调整为 ¥487.50", inverse: .removeBalanceAdjustment(UUID())
        ))

        let text = VoiceSessionSummary.text(for: [account, entry, recurring], locale: locale)
        #expect(text.hasPrefix("已新建周期记账：房租，每月 ¥800.00；已记 1 笔"))
        #expect(text.hasSuffix("；已把微信的余额调整为 ¥487.50"))
        #expect(VoiceSessionSummary.text(for: [recurring], locale: locale) == "已新建周期记账：房租，每月 ¥800.00")
    }

    // MARK: - 辅助

    /// 解开新建、修改周期记账的回传结果。
    private struct SavedOutput {
        let ruleID: UUID
        let status: VoiceRecurringRuleStatus
        let nextDueDate: String
        let recordedTransactionIds: [String]

        init?(_ output: VoiceToolOutput) {
            guard case let .recurringRuleSaved(id, status, nextDueDate, recorded) = output,
                  let ruleID = UUID(uuidString: id)
            else { return nil }
            self.ruleID = ruleID
            self.status = status
            self.nextDueDate = nextDueDate
            recordedTransactionIds = recorded
        }
    }

    private func makeExecutor(_ container: ModelContainer, now: Date? = nil) -> VoiceToolExecutor {
        let date = now ?? savedAt
        return VoiceToolExecutor(container: container, locale: locale, calendar: calendar, now: { date })
    }

    private func createCall(
        accountID: UUID,
        type: VoiceEntryType = .expense,
        categoryID: String = ExpenseCategory.housing.rawValue,
        amount: String = "800",
        note: String? = "房租",
        nextDueDate: String,
        endDate: String? = nil,
        inferredFields: [VoiceInferredField] = []
    ) -> VoiceToolCall {
        .createRecurringRule(id: "c", input: VoiceCreateRecurringRuleInput(
            type: type, amount: amount, accountId: accountID.uuidString, categoryId: categoryID, note: note,
            frequency: .monthly, nextDueDate: nextDueDate, endDate: endDate, inferredFields: inferredFields
        ))
    }

    /// 通过语音工具新建一条每月规则，返回规则 UUID。
    private func createRule(
        accountID: UUID,
        type: VoiceEntryType = .expense,
        categoryID: String = ExpenseCategory.housing.rawValue,
        amount: String = "800",
        note: String? = "房租",
        nextDueDate: String,
        endDate: String? = nil,
        executor: VoiceToolExecutor
    ) throws -> UUID {
        let output = executor.execute(createCall(
            accountID: accountID, type: type, categoryID: categoryID, amount: amount, note: note,
            nextDueDate: nextDueDate, endDate: endDate
        )).result.output
        return try #require(SavedOutput(output)).ruleID
    }

    private func updateCall(_ ruleID: UUID, patch: VoiceRecurringRulePatch) -> VoiceToolCall {
        .updateRecurringRule(id: "c", input: VoiceUpdateRecurringRuleInput(ruleId: ruleID.uuidString, patch: patch))
    }

    private func categoryTitle(_ direction: BookkeepingEntryType, _ key: String) -> String {
        BookkeepingCategoryCatalog.presets.resolvedItem(direction: direction, key: key).title(locale: locale)
    }

    private func makeAccount(balance: Decimal, isActive: Bool = true, in container: ModelContainer) throws -> UUID {
        let account = Account(
            id: UUID(), typeRawValue: AccountType.cash.rawValue, templateID: nil, name: "现金",
            note: nil, lastFourDigits: nil, balance: balance, currencyCode: "CNY",
            createdAt: savedAt, updatedAt: savedAt, deactivatedAt: isActive ? nil : savedAt
        )
        let context = ModelContext(container)
        context.insert(account)
        try context.save()
        return account.id
    }

    private func fetchRule(_ id: UUID, in container: ModelContainer) throws -> RecurringRule? {
        try ModelContext(container).recurringRule(id: id)
    }

    private func ruleCount(in container: ModelContainer) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<RecurringRule>())
    }

    private func balance(_ id: UUID, in container: ModelContainer) throws -> Decimal {
        try #require(try ModelContext(container).fetch(FetchDescriptor<Account>()).first { $0.id == id }).balance
    }

    private func fetchTransaction(_ id: UUID, in container: ModelContainer) throws -> AccountTransaction {
        try #require(ModelContext(container).fetch(FetchDescriptor<AccountTransaction>()).first { $0.id == id })
    }

    private func transactionCount(in container: ModelContainer) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<AccountTransaction>())
    }
}

private extension VoiceChange {
    /// 周期记账的改动；其他改动为 `nil`。
    var recurringChange: VoiceRecurringChange? {
        if case let .recurring(change) = self { return change }
        return nil
    }
}
