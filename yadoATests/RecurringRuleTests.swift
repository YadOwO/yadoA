import Foundation
import SwiftData
import Testing
@testable import yadoA

/// 周期记账的排期、生成、暂停、分类迁移、同步与备份。
@Suite("周期记账", .serialized)
@MainActor
struct RecurringRuleTests {
    // MARK: - 排期

    @Test("按月从起始日推算，月末不会一路停在 28 日")
    func monthlyKeepsAnchorDay() {
        var day = 20260131
        var days: [Int] = []
        for _ in 0 ..< 3 {
            day = RecurringSchedule.day(after: day, frequency: .monthly, anchorDay: 20260131) ?? 0
            days.append(day)
        }
        #expect(days == [20260228, 20260331, 20260430])
    }

    @Test("闰年 2 月 29 日起始的每年规则，平年取 2 月 28 日，闰年回到 29 日")
    func yearlyHandlesLeapDay() {
        #expect(RecurringSchedule.day(after: 20280229, frequency: .yearly, anchorDay: 20280229) == 20290228)
        #expect(RecurringSchedule.day(after: 20310228, frequency: .yearly, anchorDay: 20280229) == 20320229)
    }

    @Test("每周、每两周、每季度跨月跨年")
    func otherFrequencies() {
        #expect(RecurringSchedule.day(after: 20261230, frequency: .weekly, anchorDay: 20261230) == 20270106)
        #expect(RecurringSchedule.day(after: 20261230, frequency: .biweekly, anchorDay: 20261230) == 20270113)
        #expect(RecurringSchedule.day(after: 20261130, frequency: .quarterly, anchorDay: 20261130) == 20270228)
        #expect(RecurringSchedule.day(after: 20261231, frequency: .daily, anchorDay: 20261231) == 20270101)
    }

    @Test("同一规则同一期的流水标识固定，不同期不同，格式符合 UUID 第 5 版")
    func occurrenceIDIsDeterministic() {
        let ruleID = UUID()
        let first = RecurringRule.occurrenceID(ruleID: ruleID, day: 20261101)
        #expect(first == RecurringRule.occurrenceID(ruleID: ruleID, day: 20261101))
        #expect(first != RecurringRule.occurrenceID(ruleID: ruleID, day: 20261201))
        #expect(first != RecurringRule.occurrenceID(ruleID: UUID(), day: 20261101))
        #expect(first.uuidString.lowercased().wholeMatch(of: #/[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/#) != nil)
    }

    // MARK: - 生成

    @Test("到期生成流水并计入余额，流水带来源，下一期向后推进")
    func generatesDueEntry() throws {
        let fixture = try Fixture()
        let ruleID = try fixture.saveRule(nextDueDay: 20261101)

        let generated = fixture.repository.generateDue(today: 20261101)

        let transactions = try fixture.transactions()
        #expect(generated.count == 1)
        #expect(transactions.count == 1)
        #expect(transactions.first?.recurringRuleID == ruleID)
        #expect(transactions.first?.transactionDay == 20261101)
        #expect(transactions.first?.amount == 100)
        #expect(try fixture.balance() == 900)
        #expect(try fixture.rule(ruleID).nextDueDay == 20261201)
    }

    @Test("没到期不生成")
    func skipsFutureRule() throws {
        let fixture = try Fixture()
        let ruleID = try fixture.saveRule(nextDueDay: 20261102)

        #expect(fixture.repository.generateDue(today: 20261101).isEmpty)
        #expect(try fixture.transactions().isEmpty)
        #expect(try fixture.rule(ruleID).nextDueDay == 20261102)
    }

    @Test("错过的期数一次补上，再跑一遍不会重复")
    func catchesUpAndIsIdempotent() throws {
        let fixture = try Fixture()
        _ = try fixture.saveRule(nextDueDay: 20261101)

        #expect(fixture.repository.generateDue(today: 20270115).count == 3)
        #expect(fixture.repository.generateDue(today: 20270115).isEmpty)
        #expect(try fixture.transactions().map(\.transactionDay).sorted() == [20261101, 20261201, 20270101])
        #expect(try fixture.balance() == 700)
    }

    @Test("删掉生成的一期不会再生成回来")
    func deletedOccurrenceStaysDeleted() throws {
        let fixture = try Fixture()
        _ = try fixture.saveRule(nextDueDay: 20261101)
        let generated = fixture.repository.generateDue(today: 20261101)

        try LocalExpenseRepository(container: fixture.container).delete(id: try #require(generated.first).id)

        #expect(fixture.repository.generateDue(today: 20261115).isEmpty)
        #expect(try fixture.transactions().isEmpty)
    }

    @Test("到了结束日期后不再生成，规则标记为已结束")
    func stopsAtEndDay() throws {
        let fixture = try Fixture()
        let ruleID = try fixture.saveRule(nextDueDay: 20261101, endDay: 20261201)

        #expect(fixture.repository.generateDue(today: 20270301).count == 2)
        #expect(try fixture.rule(ruleID).isFinished)
    }

    @Test("账户停用时不生成也不推进，恢复后补记；其他规则不受影响")
    func unavailableAccountBlocksOnlyItsRule() throws {
        let fixture = try Fixture()
        let blocked = try fixture.saveRule(nextDueDay: 20261101)
        let otherAccount = try fixture.insertAccount(balance: 500)
        _ = try fixture.saveRule(accountID: otherAccount, nextDueDay: 20261101)
        try fixture.setDeactivated(true, accountID: fixture.accountID)

        #expect(fixture.repository.generateDue(today: 20261101).count == 1)
        #expect(try fixture.rule(blocked).nextDueDay == 20261101)

        try fixture.setDeactivated(false, accountID: fixture.accountID)
        #expect(fixture.repository.generateDue(today: 20261101).count == 1)
        #expect(try fixture.rule(blocked).nextDueDay == 20261201)
    }

    @Test("暂停期间不生成，恢复时跳过暂停期间的日期")
    func pauseSkipsMissedDates() throws {
        let fixture = try Fixture()
        let ruleID = try fixture.saveRule(nextDueDay: 20261101)

        try fixture.repository.setPaused(true, id: ruleID, today: 20261015)
        #expect(fixture.repository.generateDue(today: 20270215).isEmpty)

        try fixture.repository.setPaused(false, id: ruleID, today: 20270215)
        #expect(try fixture.rule(ruleID).nextDueDay == 20270301)
        #expect(fixture.repository.generateDue(today: 20270215).isEmpty)
    }

    @Test("删除规则保留已生成的流水")
    func deletingRuleKeepsEntries() throws {
        let fixture = try Fixture()
        let ruleID = try fixture.saveRule(nextDueDay: 20261101)
        fixture.repository.generateDue(today: 20261101)

        try fixture.repository.delete(id: ruleID)

        #expect(try fixture.transactions().count == 1)
        #expect(try ModelContext(fixture.container).recurringRule(id: ruleID) == nil)
    }

    @Test("结束日期早于下一期时拒绝保存")
    func rejectsEndBeforeNext() throws {
        let fixture = try Fixture()
        #expect(throws: RecurringRuleRepositoryError.invalidInput) {
            try fixture.saveRule(nextDueDay: 20261101, endDay: 20261031)
        }
    }

    @Test("改下一期时重置起始日，只改金额时保留起始日")
    func editingResetsAnchorOnlyWhenScheduleChanges() throws {
        let fixture = try Fixture()
        let ruleID = try fixture.saveRule(nextDueDay: 20261031)

        _ = try fixture.saveRule(id: ruleID, amount: 50, nextDueDay: 20261031)
        #expect(try fixture.rule(ruleID).anchorDay == 20261031)
        #expect(try fixture.rule(ruleID).amount == 50)

        _ = try fixture.saveRule(id: ruleID, amount: 50, nextDueDay: 20261105)
        #expect(try fixture.rule(ruleID).anchorDay == 20261105)
    }

    // MARK: - 与其他功能的关系

    @Test("自动记入的流水不影响最近分类")
    func generatedEntryIsNotRecent() throws {
        let fixture = try Fixture()
        let context = ModelContext(fixture.container)
        context.insert(try AccountTransaction.validatingExpense(
            id: UUID(), accountID: fixture.accountID, category: .dining, amount: 10,
            transactionDay: 20261001, savedAt: Date(timeIntervalSince1970: 100)
        ))
        try context.save()
        _ = try fixture.saveRule(categoryKey: ExpenseCategory.travel.rawValue, nextDueDay: 20261101)
        fixture.repository.generateDue(today: 20261101)

        #expect(BookkeepingRecentCategories.resolve(in: ModelContext(fixture.container)).expenseKey == ExpenseCategory.dining.rawValue)
    }

    @Test("自动记入的流水不算今天记过账")
    func generatedEntryDoesNotCountForReminder() throws {
        let fixture = try Fixture()
        _ = try fixture.saveRule(nextDueDay: 20261101)
        fixture.repository.generateDue(today: 20261101)
        #expect(!BookkeepingReminderScheduler.hasEntry(onDay: 20261101, in: fixture.container))

        let context = ModelContext(fixture.container)
        context.insert(try AccountTransaction.validatingExpense(
            id: UUID(), accountID: fixture.accountID, category: .dining, amount: 10, transactionDay: 20261101
        ))
        try context.save()
        #expect(BookkeepingReminderScheduler.hasEntry(onDay: 20261101, in: fixture.container))
    }

    @Test("删除分类时规则跟着迁移；流水随分类删除时规则迁到其他")
    func categoryDeletionMigratesRules() throws {
        let fixture = try Fixture()
        let categories = LocalCategoryRepository(container: fixture.container)
        try categories.ensurePresets()
        let migrated = try fixture.saveRule(categoryKey: "pets", nextDueDay: 20261101)
        let fallback = try fixture.saveRule(categoryKey: "travel", nextDueDay: 20261101)

        try categories.delete(key: "pets", direction: .expense, transactions: .migrate(to: "shopping"))
        try categories.delete(key: "travel", direction: .expense, transactions: .delete)

        #expect(try fixture.rule(migrated).categoryKey == "shopping")
        #expect(try fixture.rule(fallback).categoryKey == BookkeepingCategoryKey.other)
    }

    @Test("列表状态：正常、不可用、暂停、结束，排序把暂停和结束放后面")
    func listPresentation() throws {
        let fixture = try Fixture()
        let finished = try fixture.saveRule(nextDueDay: 20261101, endDay: 20261101)
        fixture.repository.generateDue(today: 20261101)
        let paused = try fixture.saveRule(nextDueDay: 20261201)
        try fixture.repository.setPaused(true, id: paused, today: 20261101)
        let active = try fixture.saveRule(nextDueDay: 20261205)
        let otherAccount = try fixture.insertAccount(balance: 0)
        let unavailable = try fixture.saveRule(accountID: otherAccount, nextDueDay: 20261203)
        try fixture.setDeactivated(true, accountID: otherAccount)

        let context = ModelContext(fixture.container)
        let rows = RecurringRuleListPresentation.rows(
            rules: try context.fetch(FetchDescriptor<RecurringRule>()),
            accounts: try context.fetch(FetchDescriptor<Account>()),
            catalog: .presets,
            locale: Locale(identifier: "zh-Hans"),
            calendar: Calendar(identifier: .gregorian)
        )

        #expect(rows.map(\.id) == [unavailable, active, paused, finished])
        #expect(rows.map(\.status) == [.unavailable, .active, .paused, .finished])
        #expect(rows[1].subtitle.contains("每月"))
        #expect(rows[1].formattedAmount.contains("100"))
    }

    // MARK: - 同步

    @Test("规则修改会登记到同步台账，内容能完整还原")
    func syncPayloadRoundTrip() throws {
        let fixture = try Fixture()
        let ruleID = try fixture.saveRule(nextDueDay: 20261101, endDay: 20271101)

        let source = try fixture.rule(ruleID)
        let record = try #require(try SyncPayloadCoder.record(for: source))
        #expect(record.entityType == .recurringRule)
        #expect(record.recordID == ruleID)

        let key = SyncLedgerEntry.key(entityType: .recurringRule, recordID: ruleID)
        let entries = try ModelContext(fixture.container).fetch(FetchDescriptor<SyncLedgerEntry>())
        #expect(entries.contains { $0.key == key && $0.hasPendingChanges })

        let target = try Fixture()
        let context = target.container.makeManualSaveContext()
        var ledger: [String: SyncLedgerEntry] = [:]
        let outcome = try SyncRecordApplier.apply(
            [SyncRemoteRecord(
                entityTypeRawValue: "recurring_rule",
                recordID: ruleID,
                modifiedAt: .now,
                isDeleted: false,
                payload: try SyncJSONValue(payload: record.payload),
                serverVersion: 1
            )],
            in: context,
            ledger: &ledger,
            now: .now
        )
        try context.saveOrRollback(tracksSyncChanges: false)

        #expect(outcome.appliedCount == 1)
        let applied = try target.rule(ruleID)
        #expect(applied.amount == 100)
        #expect(applied.nextDueDay == 20261101)
        #expect(applied.endDay == 20271101)
        #expect(applied.frequency == .monthly)
    }

    @Test("两台设备离线各自生成同一期，应用对方的流水后只有一笔")
    func twoDevicesConverge() throws {
        let fixture = try Fixture()
        let ruleID = try fixture.saveRule(nextDueDay: 20261101)
        fixture.repository.generateDue(today: 20261101)
        let generated = try #require(try fixture.transactions().first)
        let record = try #require(try SyncPayloadCoder.record(for: generated))

        let context = fixture.container.makeManualSaveContext()
        var ledger = Dictionary(
            try context.fetch(FetchDescriptor<SyncLedgerEntry>()).map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        _ = try SyncRecordApplier.apply(
            [SyncRemoteRecord(
                entityTypeRawValue: "transaction",
                recordID: RecurringRule.occurrenceID(ruleID: ruleID, day: 20261101),
                modifiedAt: .now.addingTimeInterval(60),
                isDeleted: false,
                payload: try SyncJSONValue(payload: record.payload),
                serverVersion: 1
            )],
            in: context,
            ledger: &ledger,
            now: .now
        )
        try context.saveOrRollback(tracksSyncChanges: false)

        let transactions = try fixture.transactions()
        #expect(transactions.count == 1)
        #expect(transactions.first?.recurringRuleID == ruleID)
    }

    @Test("手动记的流水同步内容里没有来源字段，哈希不因升级变化")
    func manualEntryPayloadHasNoRuleField() throws {
        let transaction = try AccountTransaction.validatingExpense(
            id: UUID(), accountID: UUID(), category: .dining, amount: 1, transactionDay: 20261101
        )
        let record = try #require(try SyncPayloadCoder.record(for: transaction))
        let object = try #require(try JSONSerialization.jsonObject(with: record.payload) as? [String: Any])
        #expect(object["recurringRuleID"] == nil)
    }

    // MARK: - 备份

    @Test("备份包含规则和流水来源，恢复后一致；清除数据时一并清除")
    func backupRoundTripAndReset() throws {
        let fixture = try Fixture()
        let ruleID = try fixture.saveRule(nextDueDay: 20261101)
        fixture.repository.generateDue(today: 20261101)
        let backup = try BackupExportService(container: fixture.container).makeSnapshot()
        #expect(backup.recurringRules.map(\.id) == [ruleID])

        let encoded = try BackupFileEncoding.makeEncoder().encode(backup)
        try LocalDataResetService(container: fixture.container).eraseAll()
        #expect(try ModelContext(fixture.container).fetchCount(FetchDescriptor<RecurringRule>()) == 0)

        let service = BackupImportService(container: fixture.container)
        try service.restore(try service.prepare(from: encoded))

        #expect(try fixture.rule(ruleID).nextDueDay == 20261201)
        #expect(try fixture.transactions().first?.recurringRuleID == ruleID)
    }

    @Test("金额不合法的规则让备份校验失败")
    func invalidRuleFailsValidation() throws {
        let rule = RecurringRule(
            id: UUID(), entryTypeRawValue: "expense", accountID: UUID(), categoryKey: "dining", amount: 1, note: nil,
            frequencyRawValue: "monthly", anchorDay: 20261101, nextDueDay: 20261101, endDay: nil,
            pausedAt: nil, createdAt: .now, updatedAt: .now
        )
        rule.amount = 0
        #expect(throws: BackupImportError.invalidContent) {
            try BackupRecurringRule(rule).validatedRule()
        }
    }

    // MARK: - 夹具

    /// 隔离的内存容器，带一个余额 1000 的现金账户。
    private struct Fixture {
        let container: ModelContainer
        let repository: LocalRecurringRuleRepository
        let accountID: UUID

        init() throws {
            container = try AccountDataContainer.inMemory().modelContainer
            repository = LocalRecurringRuleRepository(container: container)
            accountID = UUID()
            let context = ModelContext(container)
            context.insert(Self.makeAccount(id: accountID, balance: 1000))
            try context.save()
        }

        private static func makeAccount(id: UUID, balance: Decimal) -> Account {
            Account(
                id: id,
                typeRawValue: AccountType.cash.rawValue,
                templateID: nil,
                name: "现金",
                note: nil,
                lastFourDigits: nil,
                balance: balance,
                currencyCode: "CNY",
                createdAt: .now,
                updatedAt: .now
            )
        }

        func insertAccount(balance: Decimal) throws -> UUID {
            let id = UUID()
            let context = ModelContext(container)
            context.insert(Self.makeAccount(id: id, balance: balance))
            try context.save()
            return id
        }

        func setDeactivated(_ isDeactivated: Bool, accountID: UUID) throws {
            let context = ModelContext(container)
            let account = try #require(try context.account(id: accountID))
            account.deactivatedAt = isDeactivated ? .now : nil
            try context.save()
        }

        @discardableResult
        func saveRule(
            id: UUID = UUID(),
            accountID: UUID? = nil,
            categoryKey: String = ExpenseCategory.dining.rawValue,
            amount: Decimal = 100,
            nextDueDay: Int,
            endDay: Int? = nil
        ) throws -> UUID {
            try repository.save(
                RecurringRuleInput(
                    id: id,
                    accountID: accountID ?? self.accountID,
                    entryType: .expense,
                    categoryKey: categoryKey,
                    amount: amount,
                    note: "",
                    frequency: .monthly,
                    nextDueDay: nextDueDay,
                    endDay: endDay
                )
            )
            return id
        }

        func rule(_ id: UUID) throws -> RecurringRule {
            try #require(try ModelContext(container).recurringRule(id: id))
        }

        func transactions() throws -> [AccountTransaction] {
            try ModelContext(container).fetch(FetchDescriptor<AccountTransaction>())
        }

        func balance() throws -> Decimal {
            try #require(try ModelContext(container).account(id: accountID)).balance
        }
    }
}
