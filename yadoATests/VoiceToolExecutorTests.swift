import Foundation
import SwiftData
import Testing
@testable import yadoA

/// 使用真实 SwiftData 验证语音记账工具在本地的执行、批量变更的原子性与撤销。
@Suite("语音记账工具执行", .serialized)
@MainActor
struct VoiceToolExecutorTests {
    private let locale = Locale(identifier: "zh-Hans")
    private let savedAt = Date(timeIntervalSince1970: 1_792_470_600)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test("新增按草稿入账并联动余额，记录推断字段与反向操作")
    func createInsertsTransaction() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let accountID = try makeAccount(balance: 100, in: container)
        let execution = makeExecutor(container).execute(.createTransaction(id: "c1", input: createInput(
            accountID: accountID, amount: "28.50", note: "午饭", inferredFields: [.account]
        )))

        guard case let .created(idText) = execution.result.output, let id = UUID(uuidString: idText) else {
            Issue.record("应返回新流水 id")
            return
        }
        #expect(execution.result.toolCallId == "c1")
        #expect(execution.result.name == .createTransaction)
        let transaction = try fetchTransaction(id, in: container)
        #expect(transaction.amount == Decimal(string: "28.50"))
        #expect(transaction.category == .dining)
        #expect(transaction.transactionDay == 20261020)
        #expect(transaction.note == "午饭")
        #expect(transaction.savedAt == savedAt)
        #expect(try balance(accountID, in: container) == Decimal(string: "71.50"))

        let change = try #require(execution.change?.entryChange)
        #expect(change.kind == .created)
        #expect(change.label == "午饭")
        #expect(change.inferredFields == [.account])
        #expect(change.inverse == .delete(id))
        #expect(change.highlight == .added(id: id, transactionDay: 20261020))
        #expect(change.transactionDay == 20261020)
        #expect(change.row?.id == id)
    }

    @Test("新增时账户不存在或已停用返回 invalid_input，不写入任何数据")
    func createRejectsUnavailableAccount() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let deactivated = try makeAccount(balance: 100, isActive: false, in: container)
        let executor = makeExecutor(container)

        let unknown = executor.execute(.createTransaction(id: "c1", input: createInput(accountID: UUID(), amount: "10")))
        let inactive = executor.execute(.createTransaction(id: "c2", input: createInput(accountID: deactivated, amount: "10")))
        let badDate = executor.execute(.createTransaction(id: "c3", input: VoiceCreateTransactionInput(
            type: .expense, amount: "10", accountId: deactivated.uuidString, categoryId: "dining",
            date: "2026-02-30", note: nil, inferredFields: []
        )))

        #expect(unknown.result.output == .failure(.invalidInput))
        #expect(inactive.result.output == .failure(.invalidInput))
        #expect(badDate.result.output == .failure(.invalidInput))
        #expect(unknown.change == nil)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<AccountTransaction>()) == 0)
        #expect(try balance(deactivated, in: container) == 100)
    }

    @Test("修改金额与分类；标题仍是旧分类名时清空，让展示跟随新分类")
    func updateClearsStaleCategoryTitle() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let accountID = try makeAccount(balance: 100, in: container)
        let id = UUID()
        let repository = LocalExpenseRepository(container: container)
        try repository.save(DiningExpenseDraft(id: id, accountID: accountID, amountText: "20", transactionDay: 20261020))
        // 手动编辑会把分类名写成标题
        let diningTitle = BookkeepingCategoryCatalog.presets.resolvedItem(direction: .expense, key: "dining").title(locale: locale)
        try repository.update(DiningExpenseEditDraft(
            id: id, accountID: accountID, title: diningTitle, amountText: "20", transactionDay: 20261020
        ))
        let previous = try #require(BookkeepingEntrySnapshot(transaction: fetchTransaction(id, in: container)))

        let execution = makeExecutor(container).execute(.updateTransaction(id: "c1", input: VoiceUpdateTransactionInput(
            id: id.uuidString,
            patch: VoiceTransactionPatch(amount: "40", categoryId: "transportation", note: .set("打车"))
        )))

        #expect(execution.result.output == .succeeded)
        let transaction = try fetchTransaction(id, in: container)
        #expect(transaction.category == .transportation)
        #expect(transaction.title == nil)
        #expect(transaction.amount == 40)
        #expect(transaction.note == "打车")
        #expect(try balance(accountID, in: container) == 60)
        let change = try #require(execution.change?.entryChange)
        #expect(change.kind == .updated)
        #expect(change.inverse == .replace(previous))
        #expect(change.transactionDay == 20261020)
    }

    @Test("已停用账户下的流水不能修改或删除，不存在的流水返回 not_found")
    func rejectsUneditableTargets() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let accountID = try makeAccount(balance: 100, in: container)
        let id = UUID()
        try LocalExpenseRepository(container: container).save(
            DiningExpenseDraft(id: id, accountID: accountID, amountText: "20", transactionDay: 20261020)
        )
        try deactivate(accountID, in: container)
        let executor = makeExecutor(container)

        let update = executor.execute(.updateTransaction(id: "c1", input: VoiceUpdateTransactionInput(
            id: id.uuidString, patch: VoiceTransactionPatch(amount: "30")
        )))
        let delete = executor.execute(.deleteTransaction(id: "c2", input: VoiceDeleteTransactionInput(id: id.uuidString)))
        let missing = executor.execute(.deleteTransaction(id: "c3", input: VoiceDeleteTransactionInput(id: UUID().uuidString)))

        #expect(update.result.output == .failure(.notEditable))
        #expect(delete.result.output == .failure(.notEditable))
        #expect(missing.result.output == .failure(.notFound))
        #expect(try fetchTransaction(id, in: container).amount == 20)
    }

    @Test("删除后撤销按原 UUID、保存时间与备注插回，余额复原")
    func deleteThenRevertRestoresTransaction() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let accountID = try makeAccount(balance: 100, in: container)
        let id = UUID()
        let originalSavedAt = Date(timeIntervalSince1970: 1_000)
        try LocalExpenseRepository(container: container).save(
            DiningExpenseDraft(id: id, accountID: accountID, amountText: "15", transactionDay: 20261019, note: "奶茶"),
            savedAt: originalSavedAt
        )
        let executor = makeExecutor(container)

        let execution = executor.execute(.deleteTransaction(id: "c1", input: VoiceDeleteTransactionInput(id: id.uuidString)))
        #expect(execution.result.output == .succeeded)
        #expect(try balance(accountID, in: container) == 100)
        let change = try #require(execution.change?.entryChange)
        #expect(change.label == "奶茶")
        guard case .deleted = change.highlight else {
            Issue.record("删除应登记残影提示")
            return
        }

        let highlights = try executor.revert([.entry(change)])
        let restored = try fetchTransaction(id, in: container)
        #expect(restored.savedAt == originalSavedAt)
        #expect(restored.note == "奶茶")
        #expect(restored.amount == 15)
        #expect(try balance(accountID, in: container) == 85)
        #expect(highlights == [.added(id: id, transactionDay: 20261019)])
    }

    @Test("撤销一轮的多笔变更在一次保存内完成")
    func revertUndoesWholeTurn() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let accountID = try makeAccount(balance: 100, in: container)
        let executor = makeExecutor(container)
        let first = executor.execute(.createTransaction(id: "c1", input: createInput(accountID: accountID, amount: "28")))
        let second = executor.execute(.createTransaction(id: "c2", input: createInput(accountID: accountID, amount: "35")))
        guard case let .created(firstID) = first.result.output else {
            Issue.record("应新增成功")
            return
        }
        let update = executor.execute(.updateTransaction(id: "c3", input: VoiceUpdateTransactionInput(
            id: firstID, patch: VoiceTransactionPatch(amount: "30")
        )))
        #expect(try balance(accountID, in: container) == 35)

        let changes = [first, second, update].compactMap(\.change)
        #expect(changes.count == 3)
        _ = try executor.revert(changes)

        #expect(try ModelContext(container).fetchCount(FetchDescriptor<AccountTransaction>()) == 0)
        #expect(try balance(accountID, in: container) == 100)
    }

    @Test("撤销中任一步失败时整体回滚，数据保持撤销前的状态")
    func revertFailureKeepsData() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let accountID = try makeAccount(balance: 100, in: container)
        let executor = makeExecutor(container)
        let first = executor.execute(.createTransaction(id: "c1", input: createInput(accountID: accountID, amount: "28")))
        let change = try #require(first.change?.entryChange)
        // 伪造一个已不存在的流水的删除，使整批撤销失败
        let missing = VoiceEntryChange(
            kind: .created, transactionID: UUID(), transactionDay: 20261020, row: nil, accountName: nil, label: "x",
            formattedAmount: "¥1.00", inferredFields: [], inverse: .delete(UUID()), highlight: nil
        )

        #expect(throws: (any Error).self) {
            _ = try executor.revert([.entry(missing), .entry(change)])
        }
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<AccountTransaction>()) == 1)
        #expect(try balance(accountID, in: container) == 72)
    }

    @Test("批量变更任一步失败时之前的变更也不生效")
    func applyIsAtomic() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let accountID = try makeAccount(balance: 100, in: container)
        let snapshot = BookkeepingEntrySnapshot(
            id: UUID(), accountID: accountID, entryType: .expense, categoryKey: "dining",
            amount: 10, title: "早餐", transactionDay: 20261020, note: nil, savedAt: savedAt
        )

        let missingID = UUID()
        #expect(throws: ExpenseRepositoryError.transactionNotFound(missingID)) {
            try LocalExpenseRepository(container: container).apply([.insert(snapshot), .delete(missingID)])
        }
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<AccountTransaction>()) == 0)
        #expect(try balance(accountID, in: container) == 100)

        try LocalExpenseRepository(container: container).apply([.insert(snapshot)])
        let inserted = try fetchTransaction(snapshot.id, in: container)
        #expect(inserted.title == "早餐")
        #expect(inserted.savedAt == savedAt)
        #expect(try balance(accountID, in: container) == 90)
    }

    @Test("查询按条件筛选并倒序返回，停用账户下的流水标为不可编辑；汇总给出笔数与总额")
    func searchAndSummarize() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let active = try makeAccount(balance: 100, in: container)
        let inactive = try makeAccount(balance: 100, in: container)
        let repository = LocalExpenseRepository(container: container)
        try repository.save(DiningExpenseDraft(
            accountID: active, expenseCategoryKey: "transportation", amountText: "35",
            transactionDay: 20261019, note: "打车回家"
        ))
        try repository.save(DiningExpenseDraft(
            accountID: inactive, expenseCategoryKey: "transportation", amountText: "20",
            transactionDay: 20261020, note: "打车上班"
        ))
        try repository.save(DiningExpenseDraft(
            accountID: active, entryType: .income, amountText: "5000", transactionDay: 20261015
        ))
        try repository.save(DiningExpenseDraft(
            accountID: active, amountText: "28", transactionDay: 20260930, note: "午饭"
        ))
        try deactivate(inactive, in: container)
        let executor = makeExecutor(container)

        let search = executor.execute(.searchTransactions(id: "c1", input: VoiceSearchTransactionsInput(
            filter: VoiceTransactionFilter(dateFrom: "2026-10-01", dateTo: "2026-10-31", keyword: "打车"), limit: 10
        )))
        guard case let .searchResult(total, items) = search.result.output else {
            Issue.record("应返回查询结果")
            return
        }
        #expect(total == 2)
        #expect(items.map(\.date) == ["2026-10-20", "2026-10-19"])
        #expect(items.map(\.isEditable) == [false, true])
        #expect(items.map(\.amount) == ["20", "35"])
        #expect(items.first?.note == "打车上班")

        let summary = executor.execute(.summarizeTransactions(id: "c2", input: VoiceSummarizeTransactionsInput(
            filter: VoiceTransactionFilter(dateFrom: "2026-10-01", dateTo: "2026-10-31")
        )))
        #expect(summary.result.output == .summary(count: 3, expenseTotal: "55", incomeTotal: "5000"))

        let invalid = executor.execute(.summarizeTransactions(id: "c3", input: VoiceSummarizeTransactionsInput(
            filter: VoiceTransactionFilter(dateFrom: "2026-13-01")
        )))
        #expect(invalid.result.output == .failure(.invalidInput))
    }

    @Test("记账日与金额的格式转换")
    func formatConversions() {
        #expect(VoiceToolExecutor.transactionDay(from: "2026-10-20") == 20261020)
        #expect(VoiceToolExecutor.transactionDay(from: "2026-2-3") == nil)
        #expect(VoiceToolExecutor.transactionDay(from: "2026-02-30") == nil)
        #expect(VoiceToolExecutor.dateString(from: 20260203) == "2026-02-03")
        #expect(VoiceToolExecutor.amount(from: "0") == nil)
        #expect(VoiceToolExecutor.amount(from: "35.5") == Decimal(string: "35.5"))
        #expect(VoiceToolExecutor.amount(from: "1.234") == nil)
        #expect(VoiceToolExecutor.amountString(Decimal(string: "28.50")!) == "28.5")
    }

    // MARK: - 辅助

    private func makeExecutor(_ container: ModelContainer) -> VoiceToolExecutor {
        VoiceToolExecutor(container: container, locale: locale, calendar: calendar, now: { savedAt })
    }

    private func createInput(
        accountID: UUID,
        amount: String,
        note: String? = nil,
        inferredFields: [VoiceInferredField] = []
    ) -> VoiceCreateTransactionInput {
        VoiceCreateTransactionInput(
            type: .expense, amount: amount, accountId: accountID.uuidString, categoryId: "dining",
            date: "2026-10-20", note: note, inferredFields: inferredFields
        )
    }

    private func makeAccount(balance: Decimal, isActive: Bool = true, in container: ModelContainer) throws -> UUID {
        let account = Account(
            id: UUID(), typeRawValue: AccountType.cash.rawValue, templateID: nil, name: "现金",
            note: nil, lastFourDigits: nil, balance: balance, currencyCode: "CNY",
            createdAt: .now, updatedAt: .now, deactivatedAt: isActive ? nil : .now
        )
        let context = ModelContext(container)
        context.insert(account)
        try context.save()
        return account.id
    }

    private func deactivate(_ id: UUID, in container: ModelContainer) throws {
        let context = ModelContext(container)
        try #require(context.fetch(FetchDescriptor<Account>()).first { $0.id == id }).deactivatedAt = .now
        try context.save()
    }

    private func balance(_ id: UUID, in container: ModelContainer) throws -> Decimal {
        try #require(ModelContext(container).fetch(FetchDescriptor<Account>()).first { $0.id == id }).balance
    }

    private func fetchTransaction(_ id: UUID, in container: ModelContainer) throws -> AccountTransaction {
        try #require(ModelContext(container).fetch(FetchDescriptor<AccountTransaction>()).first { $0.id == id })
    }
}
