import Foundation
import SwiftData
import Testing
@testable import yadoA

/// 订阅的排期、状态、合计、自动记账联动、提醒、同步与备份。
@Suite("订阅", .serialized)
@MainActor
struct UserSubscriptionTests {
    // MARK: - 排期与状态

    @Test("下一次扣费按起始日推算，月末起扣的不会一路停在 28 日")
    func nextChargeKeepsAnchorDay() {
        #expect(UserSubscriptionSchedule.nextChargeDay(onOrAfter: 20260301, anchorDay: 20260131, frequency: .monthly) == 20260331)
        #expect(UserSubscriptionSchedule.nextChargeDay(onOrAfter: 20260201, anchorDay: 20260131, frequency: .monthly) == 20260228)
        // 起始日在以后时就是起始日
        #expect(UserSubscriptionSchedule.nextChargeDay(onOrAfter: 20261101, anchorDay: 20261205, frequency: .yearly) == 20261205)
        // 今天就是扣费日时算今天
        #expect(UserSubscriptionSchedule.nextChargeDay(onOrAfter: 20261205, anchorDay: 20261105, frequency: .monthly) == 20261205)
    }

    @Test("折算：年付除以 12，周付按 52 周，季付乘 4")
    func amountConversion() {
        #expect(UserSubscriptionSchedule.monthlyAmount(120, frequency: .yearly) == 10)
        #expect(UserSubscriptionSchedule.yearlyAmount(10, frequency: .weekly) == 520)
        #expect(UserSubscriptionSchedule.yearlyAmount(30, frequency: .quarterly) == 120)
        #expect(UserSubscriptionSchedule.monthlyAmount(25, frequency: .monthly) == 25)
    }

    @Test("试用过了结束日按订阅中算；取消后过了可用日期算到期；不认识的周期只展示")
    func phases() {
        let trial = Self.subscription(status: .trial, anchorDay: 20261210)
        #expect(trial.phase(today: 20261201) == .trial(endDay: 20261210))
        #expect(trial.phase(today: 20261210) == .active(nextChargeDay: 20261210))
        #expect(trial.phase(today: 20261211) == .active(nextChargeDay: 20270110))

        let cancelled = Self.subscription(status: .cancelled, anchorDay: 20261110, accessEndDay: 20261209)
        #expect(cancelled.phase(today: 20261201) == .cancelled(accessEndDay: 20261209))
        #expect(cancelled.phase(today: 20261210) == .expired)

        let unknown = Self.subscription(status: .active, anchorDay: 20261110)
        unknown.frequencyRawValue = "fortnightly"
        #expect(unknown.phase(today: 20261201) == .unknown)
    }

    @Test("改成已取消时可用日期预填为下次扣费前一天")
    func defaultAccessEndDay() {
        let calendar = Calendar(identifier: .gregorian)
        #expect(UserSubscriptionSchedule.defaultAccessEndDay(beforeChargeDay: 20270101, calendar: calendar) == 20261231)
    }

    // MARK: - 列表与合计

    @Test("列表：在扣费的按下次扣费排前面，已取消其次，到期最后；合计只算订阅中的")
    func listAndSummary() {
        let today = 20261201
        let yearly = Self.subscription(name: "iCloud+", amount: 120, frequency: .yearly, category: .cloud, anchorDay: 20270301)
        let monthly = Self.subscription(name: "ChatGPT", amount: 140, category: .ai, anchorDay: 20261205)
        let video = Self.subscription(name: "视频", amount: 25, category: .media, anchorDay: 20261220)
        let trial = Self.subscription(name: "试用", amount: 99, category: .software, status: .trial, anchorDay: 20261203)
        let cancelled = Self.subscription(name: "已取消", amount: 30, status: .cancelled, anchorDay: 20261101, accessEndDay: 20261215)
        let expired = Self.subscription(name: "到期", amount: 30, status: .cancelled, anchorDay: 20261001, accessEndDay: 20261031)
        let all = [expired, cancelled, yearly, trial, video, monthly]

        let rows = UserSubscriptionListPresentation.rows(
            subscriptions: all,
            existingRuleIDs: [],
            today: today,
            locale: Locale(identifier: "zh-Hans"),
            calendar: Calendar(identifier: .gregorian)
        )
        #expect(rows.map(\.title) == ["试用", "ChatGPT", "视频", "iCloud+", "已取消", "到期"])
        #expect(rows.map(\.isInactive) == [false, false, false, false, true, true])

        let summary = UserSubscriptionListPresentation.summary(
            subscriptions: all,
            today: today,
            locale: Locale(identifier: "zh-Hans")
        )
        // 140 + 25 + 120 / 12 = 175
        #expect(summary?.monthlyTotal == 175)
        #expect(summary?.yearlyTotal == 2100)
        #expect(summary?.categoryCount == 3)
        #expect(summary?.breakdown.segments.map(\.id) == ["ai", "media", "cloud"])
    }

    @Test("分类超过三类时饼图合并成「其他分类」；没有在扣费的订阅时没有合计")
    func summaryMergesAndEmpty() {
        let today = 20261201
        let categories: [UserSubscriptionCategory] = [.ai, .media, .cloud, .software]
        let subscriptions = categories.enumerated().map { index, category in
            Self.subscription(name: category.rawValue, amount: Decimal(40 - index * 10), category: category, anchorDay: 20261210)
        }
        let summary = UserSubscriptionListPresentation.summary(subscriptions: subscriptions, today: today, locale: Locale(identifier: "zh-Hans"))
        #expect(summary?.categoryCount == 4)
        #expect(summary?.breakdown.segments.count == 4)
        #expect(summary?.breakdown.segments.last?.id == CategoryBreakdownPresentation.remainingID)

        let trialOnly = [Self.subscription(status: .trial, anchorDay: 20261210)]
        #expect(UserSubscriptionListPresentation.summary(subscriptions: trialOnly, today: today, locale: .current) == nil)
    }

    // MARK: - 保存

    @Test("新建订阅：名称去空白，不自动记账时不建周期记账")
    func savesWithoutBookkeeping() throws {
        let fixture = try Fixture()
        let id = UUID()
        let ruleID = try fixture.save(id: id, name: "  Netflix ", chargeDay: 20261210)

        #expect(ruleID == nil)
        let subscription = try fixture.subscription(id)
        #expect(subscription.name == "Netflix")
        #expect(subscription.anchorDay == 20261210)
        #expect(try fixture.rules().isEmpty)
    }

    @Test("名称为空、金额为零或提醒天数超出范围时拒绝保存")
    func rejectsInvalidInput() throws {
        let fixture = try Fixture()
        #expect(throws: UserSubscriptionRepositoryError.invalidInput) {
            try fixture.save(name: "  ", chargeDay: 20261210)
        }
        #expect(throws: UserSubscriptionRepositoryError.invalidInput) {
            try fixture.save(amount: 0, chargeDay: 20261210)
        }
        #expect(throws: UserSubscriptionRepositoryError.invalidInput) {
            try fixture.save(chargeDay: 20261210, reminderDaysBefore: 99)
        }
    }

    @Test("表单日期没变时保留月末起始日，改了日期才换起始日")
    func keepsAnchorWhenDateUnchanged() throws {
        let fixture = try Fixture()
        let id = UUID()
        try fixture.save(id: id, chargeDay: 20270131, today: 20270101)

        // 2 月 1 日打开，表单显示的下一次扣费是 2 月 28 日；原样保存不改起始日
        try fixture.save(id: id, amount: 30, chargeDay: 20270228, today: 20270201)
        #expect(try fixture.subscription(id).anchorDay == 20270131)

        try fixture.save(id: id, amount: 30, chargeDay: 20270305, today: 20270201)
        #expect(try fixture.subscription(id).anchorDay == 20270305)
    }

    @Test("打开自动记账：建一条按订阅金额和名称的支出周期记账，今天扣费的保存后立即记入")
    func autoBookkeepingCreatesRule() throws {
        let fixture = try Fixture()
        let id = UUID()
        let ruleID = try #require(try fixture.save(id: id, name: "ChatGPT", amount: 140, chargeDay: 20261201, linked: true))

        let rule = try fixture.rule(ruleID)
        #expect(rule.entryType == .expense)
        #expect(rule.amount == 140)
        #expect(rule.note == "ChatGPT")
        #expect(rule.accountID == fixture.accountID)
        #expect(rule.categoryKey == ExpenseCategory.entertainment.rawValue)
        #expect(rule.nextDueDay == 20261201)
        #expect(rule.anchorDay == 20261201)
        #expect(try fixture.subscription(id).recurringRuleID == ruleID)

        let entries = fixture.recurring.generateDue(ruleID: ruleID, today: 20261201)
        #expect(entries.map(\.transactionDay) == [20261201])
        #expect(try fixture.rule(ruleID).nextDueDay == 20270101)
    }

    @Test("只改金额、名称时规则跟着改，但下一期不变，不会补记或跳过")
    func editingContentKeepsRuleSchedule() throws {
        let fixture = try Fixture()
        let id = UUID()
        let ruleID = try #require(try fixture.save(id: id, chargeDay: 20261201, linked: true))
        fixture.recurring.generateDue(ruleID: ruleID, today: 20261201)

        // 同一天再打开，表单显示的下一次扣费还是今天
        try fixture.save(id: id, name: "改名", amount: 50, chargeDay: 20261201, linked: true)

        let rule = try fixture.rule(ruleID)
        #expect(rule.amount == 50)
        #expect(rule.note == "改名")
        #expect(rule.nextDueDay == 20270101)
    }

    @Test("试用中打开自动记账，从试用结束那天开始记")
    func trialStartsAtTrialEnd() throws {
        let fixture = try Fixture()
        let ruleID = try #require(try fixture.save(status: .trial, chargeDay: 20261215, linked: true))

        #expect(try fixture.rule(ruleID).nextDueDay == 20261215)
        #expect(fixture.recurring.generateDue(today: 20261201).isEmpty)
    }

    @Test("取消订阅：规则记完今天及以前的就结束；恢复订阅后从下一次扣费接着记")
    func cancellingStopsRuleAndResumingRestarts() throws {
        let fixture = try Fixture()
        let id = UUID()
        let ruleID = try #require(try fixture.save(id: id, chargeDay: 20261201, linked: true))
        fixture.recurring.generateDue(ruleID: ruleID, today: 20261201)

        try fixture.save(id: id, status: .cancelled, chargeDay: 20261201, accessEndDay: 20261231, linked: true, today: 20261210)
        var rule = try fixture.rule(ruleID)
        #expect(rule.endDay == 20261210)
        #expect(rule.isFinished)
        #expect(fixture.recurring.generateDue(today: 20270301).isEmpty)

        // 再存一次已取消的（例如改备注），结束日期不再往后挪
        try fixture.save(id: id, status: .cancelled, chargeDay: 20261201, accessEndDay: 20261231, linked: true, today: 20270115)
        #expect(try fixture.rule(ruleID).endDay == 20261210)

        try fixture.save(id: id, status: .active, chargeDay: 20270401, linked: true, today: 20270315)
        rule = try fixture.rule(ruleID)
        #expect(rule.endDay == nil)
        #expect(rule.nextDueDay == 20270401)
    }

    @Test("已取消的订阅不新建周期记账")
    func cancelledDoesNotCreateRule() throws {
        let fixture = try Fixture()
        let ruleID = try fixture.save(status: .cancelled, chargeDay: 20261201, linked: true)
        #expect(ruleID == nil)
        #expect(try fixture.rules().isEmpty)
    }

    @Test("关掉自动记账：可以保留为普通周期记账，也可以删掉；已记的流水都不动")
    func unlinkingKeepsOrDeletesRule() throws {
        let fixture = try Fixture()
        let kept = UUID()
        let keptRule = try #require(try fixture.save(id: kept, chargeDay: 20261201, linked: true))
        fixture.recurring.generateDue(ruleID: keptRule, today: 20261201)
        try fixture.save(id: kept, chargeDay: 20261201, linked: false, deletesRule: false)
        #expect(try fixture.subscription(kept).recurringRuleID == nil)
        #expect(try ModelContext(fixture.container).recurringRule(id: keptRule) != nil)

        let deleted = UUID()
        let deletedRule = try #require(try fixture.save(id: deleted, chargeDay: 20261201, linked: true))
        fixture.recurring.generateDue(ruleID: deletedRule, today: 20261201)
        try fixture.save(id: deleted, chargeDay: 20261201, linked: false, deletesRule: true)
        #expect(try ModelContext(fixture.container).recurringRule(id: deletedRule) == nil)

        #expect(try fixture.transactions().count == 2)
    }

    @Test("在周期记账里删掉订阅建的规则，订阅保留并关掉自动记账")
    func deletingRuleDetachesSubscription() throws {
        let fixture = try Fixture()
        let id = UUID()
        let ruleID = try #require(try fixture.save(id: id, chargeDay: 20261210, linked: true))

        try fixture.recurring.delete(id: ruleID)

        #expect(try fixture.subscription(id).recurringRuleID == nil)
    }

    @Test("删除订阅时可以连周期记账一起删，也可以留下")
    func deletingSubscription() throws {
        let fixture = try Fixture()
        let first = UUID()
        let firstRule = try #require(try fixture.save(id: first, chargeDay: 20261210, linked: true))
        try fixture.repository.delete(id: first, deletesRule: true)
        #expect(try ModelContext(fixture.container).userSubscription(id: first) == nil)
        #expect(try ModelContext(fixture.container).recurringRule(id: firstRule) == nil)

        let second = UUID()
        let secondRule = try #require(try fixture.save(id: second, chargeDay: 20261210, linked: true))
        try fixture.repository.delete(id: second, deletesRule: false)
        #expect(try ModelContext(fixture.container).recurringRule(id: secondRule) != nil)
    }

    @Test("周期记账列表里订阅建的规则以「来自订阅」开头")
    func recurringRowShowsSubscriptionOrigin() throws {
        let fixture = try Fixture()
        let id = UUID()
        let ruleID = try #require(try fixture.save(id: id, chargeDay: 20261210, linked: true))
        let context = ModelContext(fixture.container)

        let rows = RecurringRuleListPresentation.rows(
            rules: try context.fetch(FetchDescriptor<RecurringRule>()),
            accounts: try context.fetch(FetchDescriptor<Account>()),
            catalog: .presets,
            subscriptionOwners: [ruleID: id],
            locale: Locale(identifier: "zh-Hans"),
            calendar: Calendar(identifier: .gregorian)
        )
        #expect(rows.first?.subscriptionID == id)
        #expect(rows.first?.subtitle.hasPrefix("来自订阅") == true)
    }

    // MARK: - 提醒

    @Test("提醒：扣费日前几天上午 9 点，每条订阅排两次，时刻已过的跳过，已取消和不提醒的不排")
    func reminderPlans() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 12, day: 1, hour: 12)))

        let monthly = Self.subscription(name: "月付", anchorDay: 20261205, reminderDaysBefore: 3)
        // 明天扣费、提前 3 天的提醒时刻已过，只排下个月那次
        let soon = Self.subscription(name: "明天", anchorDay: 20261202, reminderDaysBefore: 3)
        let trial = Self.subscription(name: "试用", status: .trial, anchorDay: 20261210, reminderDaysBefore: 1)
        let cancelled = Self.subscription(status: .cancelled, anchorDay: 20261210, reminderDaysBefore: 1)
        let silent = Self.subscription(anchorDay: 20261210)

        let plans = UserSubscriptionReminder.plans(
            for: [monthly, soon, trial, cancelled, silent],
            now: now,
            calendar: calendar
        )

        #expect(plans.filter { $0.subscriptionID == monthly.id }.map(\.chargeDay) == [20261205, 20270105])
        #expect(plans.filter { $0.subscriptionID == soon.id }.map(\.chargeDay) == [20270102])
        let trialPlans = plans.filter { $0.subscriptionID == trial.id }
        #expect(trialPlans.map(\.chargeDay) == [20261210, 20270110])
        #expect(trialPlans.map(\.isTrialEnd) == [true, false])
        #expect(!plans.contains { $0.subscriptionID == cancelled.id || $0.subscriptionID == silent.id })

        let first = try #require(plans.first)
        #expect(first.chargeDay == 20261205)
        #expect(first.fireComponents.day == 2)
        #expect(first.fireComponents.hour == 9)
        #expect(first.identifier.hasPrefix(UserSubscriptionReminder.identifierPrefix))
        #expect(plans.map(\.fireDate) == plans.map(\.fireDate).sorted())
    }

    // MARK: - 同步与备份

    @Test("订阅修改会登记到同步台账，内容能完整还原")
    func syncPayloadRoundTrip() throws {
        let fixture = try Fixture()
        let id = UUID()
        let ruleID = try fixture.save(id: id, name: "ChatGPT", chargeDay: 20261210, reminderDaysBefore: 3, linked: true)

        let source = try fixture.subscription(id)
        let record = try #require(try SyncPayloadCoder.record(for: source))
        #expect(record.entityType == .subscription)
        let key = SyncLedgerEntry.key(entityType: .subscription, recordID: id)
        let entries = try ModelContext(fixture.container).fetch(FetchDescriptor<SyncLedgerEntry>())
        #expect(entries.contains { $0.key == key && $0.hasPendingChanges })

        let target = try Fixture()
        let context = target.container.makeManualSaveContext()
        var ledger: [String: SyncLedgerEntry] = [:]
        let outcome = try SyncRecordApplier.apply(
            [SyncRemoteRecord(
                entityTypeRawValue: "subscription",
                recordID: id,
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
        let applied = try target.subscription(id)
        #expect(applied.name == "ChatGPT")
        #expect(applied.anchorDay == 20261210)
        #expect(applied.reminderDaysBefore == 3)
        #expect(applied.recurringRuleID == ruleID)
        #expect(applied.category == .ai)
    }

    @Test("备份包含订阅，恢复后一致；清除数据时一并清除；旧备份没有订阅也能读")
    func backupRoundTripAndReset() throws {
        let fixture = try Fixture()
        let id = UUID()
        try fixture.save(id: id, name: "iCloud+", chargeDay: 20261210, linked: true)
        let backup = try BackupExportService(container: fixture.container).makeSnapshot()
        #expect(backup.subscriptions.map(\.id) == [id])

        let encoded = try BackupFileEncoding.makeEncoder().encode(backup)
        try LocalDataResetService(container: fixture.container).eraseAll()
        #expect(try ModelContext(fixture.container).fetchCount(FetchDescriptor<UserSubscription>()) == 0)

        let service = BackupImportService(container: fixture.container)
        try service.restore(try service.prepare(from: encoded))
        let restored = try fixture.subscription(id)
        #expect(restored.name == "iCloud+")
        #expect(restored.recurringRuleID != nil)
        #expect(try ModelContext(fixture.container).recurringRule(id: try #require(restored.recurringRuleID)) != nil)

        let legacy = Data(#"{"formatVersion":1,"exportedAt":"2026-11-01T00:00:00.000Z"}"#.utf8)
        #expect(try BackupFileEncoding.decode(legacy).subscriptions.isEmpty)
    }

    @Test("名称为空的订阅让备份校验失败")
    func invalidSubscriptionFailsValidation() {
        let subscription = Self.subscription(anchorDay: 20261210)
        subscription.name = " "
        #expect(throws: BackupImportError.invalidContent) {
            try BackupSubscription(subscription).validatedSubscription()
        }
    }

    // MARK: - 夹具

    /// 构造一条还没插入 context 的订阅。
    private static func subscription(
        name: String = "订阅",
        amount: Decimal = 30,
        frequency: RecurringFrequency = .monthly,
        category: UserSubscriptionCategory = .other,
        status: UserSubscriptionStatus = .active,
        anchorDay: Int,
        accessEndDay: Int? = nil,
        reminderDaysBefore: Int? = nil
    ) -> UserSubscription {
        UserSubscription(
            id: UUID(),
            name: name,
            amount: amount,
            frequencyRawValue: frequency.rawValue,
            anchorDay: anchorDay,
            categoryRawValue: category.rawValue,
            channelRawValue: UserSubscriptionChannel.appStore.rawValue,
            statusRawValue: status.rawValue,
            accessEndDay: accessEndDay,
            reminderDaysBefore: reminderDaysBefore,
            note: nil,
            recurringRuleID: nil,
            createdAt: .now,
            updatedAt: .now
        )
    }

    /// 隔离的内存容器，带一个余额 1000 的现金账户。
    @MainActor
    private struct Fixture {
        let container: ModelContainer
        let repository: LocalUserSubscriptionRepository
        let recurring: LocalRecurringRuleRepository
        let accountID: UUID

        init() throws {
            container = try AccountDataContainer.inMemory().modelContainer
            repository = LocalUserSubscriptionRepository(container: container)
            recurring = LocalRecurringRuleRepository(container: container)
            accountID = UUID()
            let context = ModelContext(container)
            context.insert(
                Account(
                    id: accountID,
                    typeRawValue: AccountType.cash.rawValue,
                    templateID: nil,
                    name: "现金",
                    note: nil,
                    lastFourDigits: nil,
                    balance: 1000,
                    currencyCode: "CNY",
                    createdAt: .now,
                    updatedAt: .now
                )
            )
            try context.save()
        }

        /// 用表单的方式保存一条订阅，返回它管理的规则。
        @discardableResult
        func save(
            id: UUID = UUID(),
            name: String = "ChatGPT",
            amount: Decimal = 30,
            status: UserSubscriptionStatus = .active,
            chargeDay: Int,
            accessEndDay: Int? = nil,
            reminderDaysBefore: Int? = nil,
            linked: Bool = false,
            deletesRule: Bool = false,
            today: Int = 20261201
        ) throws -> UUID? {
            try repository.save(
                UserSubscriptionInput(
                    id: id,
                    name: name,
                    amount: amount,
                    frequency: .monthly,
                    chargeDay: chargeDay,
                    category: .ai,
                    channel: .appStore,
                    status: status,
                    accessEndDay: accessEndDay,
                    reminderDaysBefore: reminderDaysBefore,
                    note: "",
                    bookkeeping: linked
                        ? UserSubscriptionBookkeeping(
                            accountID: accountID,
                            categoryKey: ExpenseCategory.entertainment.rawValue
                        )
                        : nil,
                    deletesRuleWhenUnlinking: deletesRule
                ),
                today: today
            )
        }

        func subscription(_ id: UUID) throws -> UserSubscription {
            try #require(try ModelContext(container).userSubscription(id: id))
        }

        func rule(_ id: UUID) throws -> RecurringRule {
            try #require(try ModelContext(container).recurringRule(id: id))
        }

        func rules() throws -> [RecurringRule] {
            try ModelContext(container).fetch(FetchDescriptor<RecurringRule>())
        }

        func transactions() throws -> [AccountTransaction] {
            try ModelContext(container).fetch(FetchDescriptor<AccountTransaction>())
        }
    }
}
