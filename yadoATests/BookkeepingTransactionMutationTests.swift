import Foundation
import SwiftData
import Testing
@testable import yadoA

/// 使用真实 SwiftData 验证完整纠错、跨账户联动和删除的原子边界。
@Suite("收支流水完整编辑与删除", .serialized)
@MainActor
struct BookkeepingTransactionMutationTests {
    @Test("完整编辑可更换账户、分类、日期和备注，并保留流水身份")
    func fullEditMovesExpenseBetweenAssetAndDebtAccounts() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let source = try makeAccount(balance: 100, in: container)
        let destination = try makeAccount(type: .creditCard, balance: 200, in: container)
        let repository = LocalExpenseRepository(container: container)
        let id = UUID()
        let savedAt = Date(timeIntervalSince1970: 100)
        try repository.save(DiningExpenseDraft(
            id: id, accountID: source, amountText: "20", transactionDay: 20260901
        ), savedAt: savedAt)

        let edit = DiningExpenseEditDraft(
            id: id, accountID: destination, category: .shopping,
            title: "  书包  ", amountText: "30.50", transactionDay: 20260902, note: "  开学用品  "
        )
        try repository.update(edit)
        try repository.update(edit)

        let transaction = try fetchTransaction(id, in: container)
        #expect(transaction.accountID == destination)
        #expect(transaction.category == .shopping)
        #expect(transaction.title == "书包")
        #expect(transaction.amount == Decimal(string: "30.50"))
        #expect(transaction.transactionDay == 20260902)
        #expect(transaction.note == "开学用品")
        #expect(transaction.savedAt == savedAt)
        #expect(try balance(source, in: container) == 100)
        #expect(try balance(destination, in: container) == Decimal(string: "230.50"))
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<AccountTransaction>()) == 1)
    }

    @Test("同账户更改收支方向按资产和负债语义正确调整")
    func changingDirectionAdjustsBalanceAndCategory() throws {
        for type in [AccountType.cash, .creditCard] {
            for oldDirection in BookkeepingEntryType.allCases {
                let container = try AccountDataContainer.inMemory().modelContainer
                let accountID = try makeAccount(type: type, balance: 100, in: container)
                let repository = LocalExpenseRepository(container: container)
                let id = UUID()
                try repository.save(DiningExpenseDraft(
                    id: id, accountID: accountID, entryType: oldDirection,
                    amountText: "20", transactionDay: 20260901
                ))
                let newDirection: BookkeepingEntryType = oldDirection == .expense ? .income : .expense
                try repository.update(DiningExpenseEditDraft(
                    id: id, accountID: accountID, entryType: newDirection,
                    category: .travel, incomeCategory: .bonus,
                    title: "修正方向", amountText: "30", transactionDay: 20260901
                ))
                let increases = (type == .cash) == (newDirection == .income)
                #expect(try balance(accountID, in: container) == (increases ? 130 : 70))
                let transaction = try fetchTransaction(id, in: container)
                #expect(transaction.transactionType == (newDirection == .income ? .income : .expense))
                #expect(transaction.categoryRawValue == (newDirection == .income ? "bonus" : "travel"))
            }
        }
    }

    @Test("删除收入和支出撤销对应账户影响，重复删除不会再次改变余额")
    func deletionRestoresBalanceOnce() throws {
        for type in [AccountType.cash, .creditCard] {
            for direction in BookkeepingEntryType.allCases {
                let container = try AccountDataContainer.inMemory().modelContainer
                let accountID = try makeAccount(type: type, balance: 100, in: container)
                let repository = LocalExpenseRepository(container: container)
                let id = UUID()
                try repository.save(DiningExpenseDraft(
                    id: id, accountID: accountID, entryType: direction,
                    amountText: "20", transactionDay: 20260901
                ))
                try repository.delete(id: id)
                #expect(try balance(accountID, in: container) == 100)
                #expect(try ModelContext(container).fetchCount(FetchDescriptor<AccountTransaction>()) == 0)
                #expect(throws: ExpenseRepositoryError.transactionNotFound(id)) {
                    try repository.delete(id: id)
                }
                #expect(try balance(accountID, in: container) == 100)
            }
        }
    }

    @Test("后续调整余额不会被历史纠错重放，日期与备注修改不影响金额")
    func correctionUsesCurrentBalanceAndPreservesAdjustmentSnapshot() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let accountID = try makeAccount(balance: 100, in: container)
        let repository = LocalExpenseRepository(container: container)
        let id = UUID()
        try repository.save(DiningExpenseDraft(
            id: id, accountID: accountID, amountText: "20", transactionDay: 20260901
        ))
        let adjustmentID = UUID()
        _ = try LocalBalanceAdjustmentRepository(container: container).save(
            BalanceAdjustmentDraft(id: adjustmentID, accountID: accountID, amountText: "500")
        )
        var draft = DiningExpenseEditDraft(
            id: id, accountID: accountID, category: .travel, title: "改日期",
            amountText: "20", transactionDay: 20260101, note: " "
        )
        try repository.update(draft)
        #expect(try balance(accountID, in: container) == 500)
        #expect(try fetchTransaction(id, in: container).note == nil)
        draft.amountText = "30"
        try repository.update(draft)
        #expect(try balance(accountID, in: container) == 490)
        try repository.delete(id: id)
        #expect(try balance(accountID, in: container) == 520)
        let adjustment = try fetchTransaction(adjustmentID, in: container)
        #expect(adjustment.balanceBefore == 80)
        #expect(adjustment.balanceAfter == 500)
        #expect(adjustment.balanceDelta == 420)
        #expect(throws: ExpenseRepositoryError.transactionNotEditable(adjustmentID)) {
            try repository.delete(id: adjustmentID)
        }
    }

    @Test("跨账户编辑和删除保存失败时全部回滚，并可重试")
    func saveFailureRollsBackBothAccountsAndTransaction() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let source = try makeAccount(balance: 100, in: container)
        let target = try makeAccount(balance: 200, in: container)
        let id = UUID()
        try LocalExpenseRepository(container: container).save(DiningExpenseDraft(
            id: id, accountID: source, amountText: "20", transactionDay: 20260901
        ))
        var fails = true
        let repository = LocalExpenseRepository(container: container, beforeSave: {
            if fails { throw MutationSaveFailure() }
        })
        let draft = DiningExpenseEditDraft(
            id: id, accountID: target, title: "修改", amountText: "30", transactionDay: 20260902
        )
        #expect(throws: MutationSaveFailure.self) { try repository.update(draft) }
        #expect(try balance(source, in: container) == 80)
        #expect(try balance(target, in: container) == 200)
        #expect(try fetchTransaction(id, in: container).accountID == source)
        #expect(throws: MutationSaveFailure.self) { try repository.delete(id: id) }
        #expect(try balance(source, in: container) == 80)
        #expect(try fetchTransaction(id, in: container).amount == 20)
        fails = false
        try repository.update(draft)
        try repository.delete(id: id)
        #expect(try balance(source, in: container) == 100)
        #expect(try balance(target, in: container) == 200)
    }

    @Test("无效日期、缺失账户和停用账户的修改均不写入")
    func invalidEditsNeverMutate() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let source = try makeAccount(balance: 100, in: container)
        let target = try makeAccount(balance: 200, in: container)
        let repository = LocalExpenseRepository(container: container)
        let id = UUID()
        try repository.save(DiningExpenseDraft(
            id: id, accountID: source, amountText: "20", transactionDay: 20260901
        ))
        var edit = DiningExpenseEditDraft(
            id: id, accountID: target, title: "修改", amountText: "30", transactionDay: 20260230
        )
        #expect(throws: AccountTransactionValidationError.invalidTransactionDay) { try repository.update(edit) }
        edit.transactionDay = 20260902
        edit.accountID = UUID()
        #expect(throws: ExpenseRepositoryError.accountNotFound(edit.accountID)) { try repository.update(edit) }
        edit.accountID = target
        let context = ModelContext(container)
        let account = try #require(context.fetch(FetchDescriptor<Account>()).first { $0.id == target })
        account.deactivatedAt = .now
        try context.save()
        #expect(throws: ExpenseRepositoryError.accountDeactivated(target)) { try repository.update(edit) }
        let sourceAccount = try #require(context.fetch(FetchDescriptor<Account>()).first { $0.id == source })
        sourceAccount.deactivatedAt = .now
        try context.save()
        #expect(throws: ExpenseRepositoryError.accountDeactivated(source)) { try repository.delete(id: id) }
        edit.accountID = source
        #expect(throws: ExpenseRepositoryError.accountDeactivated(source)) { try repository.update(edit) }
        #expect(try balance(source, in: container) == 80)
        #expect(try balance(target, in: container) == 200)
        #expect(try fetchTransaction(id, in: container).amount == 20)
    }

    @Test("从收入模型初始化草稿完整保留分类、日期和备注，拒绝调整记录")
    func editDraftPreservesIncomeAndRejectsAdjustments() throws {
        let transaction = try AccountTransaction.validatingIncome(
            id: UUID(), accountID: UUID(), category: .bonus,
            amount: 12.34, transactionDay: 20260915, title: "奖金", note: "月度奖金"
        )
        let draft = try #require(DiningExpenseEditDraft(transaction: transaction))
        #expect(draft.id == transaction.id)
        #expect(draft.accountID == transaction.accountID)
        #expect(draft.entryType == .income)
        #expect(draft.incomeCategory == .bonus)
        #expect(draft.amount == Decimal(string: "12.34"))
        #expect(draft.transactionDay == 20260915)
        #expect(draft.note == "月度奖金")
        let adjustment = try AccountTransaction.validatingBalanceAdjustment(
            id: UUID(), accountID: UUID(), balanceBefore: 0, balanceAfter: 100, transactionDay: 20260915
        )
        #expect(DiningExpenseEditDraft(transaction: adjustment) == nil)
        transaction.currencyCode = "USD"
        #expect(DiningExpenseEditDraft(transaction: transaction) == nil)
    }

    /// 创建具有明确资产或负债语义的隔离账户。
    private func makeAccount(type: AccountType = .cash, balance: Decimal, in container: ModelContainer) throws -> UUID {
        let account = Account(
            id: UUID(), typeRawValue: type.rawValue, templateID: nil, name: type.rawValue,
            note: nil, lastFourDigits: nil, balance: balance, currencyCode: "CNY",
            createdAt: .now, updatedAt: .now
        )
        let context = ModelContext(container)
        context.insert(account)
        try context.save()
        return account.id
    }

    /// 使用新 context 检查实际持久化余额。
    private func balance(_ id: UUID, in container: ModelContainer) throws -> Decimal {
        try #require(ModelContext(container).fetch(FetchDescriptor<Account>()).first { $0.id == id }).balance
    }

    /// 使用新 context 检查实际持久化流水。
    private func fetchTransaction(_ id: UUID, in container: ModelContainer) throws -> AccountTransaction {
        try #require(ModelContext(container).fetch(FetchDescriptor<AccountTransaction>()).first { $0.id == id })
    }
}

private struct MutationSaveFailure: Error {}
