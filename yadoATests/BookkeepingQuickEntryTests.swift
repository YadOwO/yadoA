import Foundation
import SwiftData
import Testing
@testable import yadoA

/// 记账提速：预选最近分类、“再记一笔”和首页流水可否删除。
@Suite("记账快捷操作")
@MainActor
struct BookkeepingQuickEntryTests {
    // MARK: - 最近分类

    @Test("账本为空时没有最近分类")
    func emptyLedgerHasNoRecentCategories() throws {
        let container = try AccountDataContainer.inMemory().modelContainer

        let recent = BookkeepingRecentCategories.resolve(in: ModelContext(container))

        #expect(recent == BookkeepingRecentCategories(expenseKey: nil, incomeKey: nil))
    }

    @Test("按保存时间取最近一笔，补记的旧账也算刚用过；收支方向各算各的，余额调整不算")
    func recentCategoryFollowsSavedAt() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let context = ModelContext(container)
        let accountID = UUID()
        context.insert(try AccountTransaction.validatingExpense(
            id: UUID(), accountID: accountID, category: .dining, amount: 10,
            transactionDay: 20260930, savedAt: Date(timeIntervalSince1970: 100)
        ))
        context.insert(try AccountTransaction.validatingExpense(
            id: UUID(), accountID: accountID, category: .travel, amount: 20,
            transactionDay: 20260101, savedAt: Date(timeIntervalSince1970: 200)
        ))
        context.insert(try AccountTransaction.validatingIncome(
            id: UUID(), accountID: accountID, category: .salary, amount: 30,
            transactionDay: 20260930, savedAt: Date(timeIntervalSince1970: 150)
        ))
        context.insert(try AccountTransaction.validatingBalanceAdjustment(
            id: UUID(), accountID: accountID, balanceBefore: 0, balanceAfter: 5,
            transactionDay: 20260930, savedAt: Date(timeIntervalSince1970: 300)
        ))
        try context.save()

        let recent = BookkeepingRecentCategories.resolve(in: context)

        #expect(recent.expenseKey == ExpenseCategory.travel.rawValue)
        #expect(recent.incomeKey == IncomeCategory.salary.rawValue)
    }

    @Test("最近分类已被删除时不预选")
    func deletedCategoryIsNotPreselected() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let repository = LocalCategoryRepository(container: container)
        try repository.ensurePresets()
        try repository.delete(key: "pets", direction: .expense, transactions: .migrate(to: "other"))
        let context = ModelContext(container)
        context.insert(try AccountTransaction.validatingExpense(
            id: UUID(), accountID: UUID(), categoryKey: "pets", amount: 10, transactionDay: 20260930
        ))
        try context.save()

        #expect(BookkeepingRecentCategories.resolve(in: context).expenseKey == nil)
    }

    // MARK: - 草稿流程

    @Test("新草稿预选最近分类，填好金额就能提交")
    func recentCategoryAllowsSubmittingWithoutSelection() {
        let flow = makeFlow()

        flow.applyRecentCategories(BookkeepingRecentCategories(expenseKey: "travel", incomeKey: nil))
        flow.updateAmountText("12", decimalSeparator: ".")

        #expect(flow.selectedCategoryKey == "travel")
        #expect(flow.canSubmit)
    }

    @Test("切到有最近分类的方向直接沿用，切到没有的方向要重新选")
    func switchingDirectionUsesRecentCategoryOfThatDirection() {
        let withIncome = makeFlow()
        withIncome.applyRecentCategories(BookkeepingRecentCategories(expenseKey: "travel", incomeKey: "bonus"))
        withIncome.selectEntryType(.income)
        #expect(withIncome.selectedCategoryKey == "bonus")

        let withoutIncome = makeFlow()
        withoutIncome.applyRecentCategories(BookkeepingRecentCategories(expenseKey: "travel", incomeKey: nil))
        withoutIncome.selectEntryType(.income)
        #expect(withoutIncome.selectedCategoryKey == nil)
        #expect(!withoutIncome.canSubmit)
    }

    @Test("手动改过的分类切换方向再切回来仍然保留")
    func manualSelectionSurvivesDirectionSwitch() {
        let flow = makeFlow()
        flow.applyRecentCategories(BookkeepingRecentCategories(expenseKey: "travel", incomeKey: "bonus"))

        flow.selectCategory(key: "shopping")
        flow.selectEntryType(.income)
        flow.selectEntryType(.expense)

        #expect(flow.selectedCategoryKey == "shopping")
    }

    @Test("预选的分类被删除后要重新选，切换方向再切回来也不会恢复")
    func clearedRecentCategoryRequiresSelection() {
        let flow = makeFlow()
        flow.applyRecentCategories(BookkeepingRecentCategories(expenseKey: "travel", incomeKey: nil))

        flow.clearCategory()
        flow.selectEntryType(.income)
        flow.selectEntryType(.expense)

        #expect(flow.selectedCategoryKey == nil)
    }

    @Test("恢复的草稿不被最近分类覆盖")
    func restoredDraftKeepsItsCategory() {
        let flow = DiningExpenseEntryFlow(
            draft: DiningExpenseDraft(
                accountID: UUID(),
                expenseCategoryKey: "shopping",
                amountText: "8",
                transactionDay: 20260930
            ),
            saveAction: { _ in }
        )

        flow.applyRecentCategories(BookkeepingRecentCategories(expenseKey: "travel", incomeKey: "bonus"))

        #expect(flow.selectedCategoryKey == "shopping")
    }

    // MARK: - 再记一笔

    @Test("再记一笔沿用分类、金额、账户和备注，换新标识和日期")
    func repeatDraftCopiesEntry() throws {
        let account = makeAccount()
        let source = try AccountTransaction.validatingExpense(
            id: UUID(), accountID: account.id, category: .travel, amount: Decimal(string: "35.5")!,
            transactionDay: 20260101, note: "打车"
        )

        let draft = try #require(DiningExpenseDraft(
            repeating: source, accounts: [account], transactionDay: 20260930
        ))

        #expect(draft.id != source.id)
        #expect(draft.accountID == account.id)
        #expect(draft.entryType == .expense)
        #expect(draft.expenseCategoryKey == ExpenseCategory.travel.rawValue)
        #expect(draft.amount == Decimal(string: "35.5"))
        #expect(draft.transactionDay == 20260930)
        #expect(draft.note == "打车")
    }

    @Test("收入也能再记一笔")
    func repeatDraftSupportsIncome() throws {
        let account = makeAccount()
        let source = try AccountTransaction.validatingIncome(
            id: UUID(), accountID: account.id, category: .bonus, amount: 100, transactionDay: 20260101
        )

        let draft = try #require(DiningExpenseDraft(
            repeating: source, accounts: [account], transactionDay: 20260930
        ))

        #expect(draft.entryType == .income)
        #expect(draft.incomeCategoryKey == IncomeCategory.bonus.rawValue)
    }

    @Test("原账户已停用时不带账户，由记账页面填入默认账户")
    func repeatDraftDropsUnavailableAccount() throws {
        let account = makeAccount(deactivatedAt: .now)
        let source = try AccountTransaction.validatingExpense(
            id: UUID(), accountID: account.id, category: .dining, amount: 10, transactionDay: 20260101
        )

        let draft = try #require(DiningExpenseDraft(
            repeating: source, accounts: [account], transactionDay: 20260930
        ))

        #expect(draft.accountID == nil)
    }

    @Test("余额调整不能再记一笔")
    func repeatDraftRejectsBalanceAdjustment() throws {
        let account = makeAccount()
        let source = try AccountTransaction.validatingBalanceAdjustment(
            id: UUID(), accountID: account.id, balanceBefore: 0, balanceAfter: 5, transactionDay: 20260101
        )

        #expect(DiningExpenseDraft(repeating: source, accounts: [account], transactionDay: 20260930) == nil)
    }

    // MARK: - 首页可否删除

    @Test("已停用或已不存在账户下的流水不能从首页删除")
    func onlyActiveAccountTransactionsAreEditable() throws {
        let active = makeAccount()
        let deactivated = makeAccount(deactivatedAt: .now)
        let editable = try AccountTransaction.validatingExpense(
            id: UUID(), accountID: active.id, category: .dining, amount: 1, transactionDay: 20260930
        )
        let archived = try AccountTransaction.validatingExpense(
            id: UUID(), accountID: deactivated.id, category: .dining, amount: 1, transactionDay: 20260930
        )
        let orphaned = try AccountTransaction.validatingExpense(
            id: UUID(), accountID: UUID(), category: .dining, amount: 1, transactionDay: 20260930
        )

        let ids = HomeOverviewPresentation.editableTransactionIDs(
            transactions: [editable, archived, orphaned],
            accounts: [active, deactivated]
        )

        #expect(ids == [editable.id])
    }

    // MARK: - 打字入口

    @Test("未登录点打字入口询问是否去登录，不打开输入框")
    func textInputRequiresSignIn() {
        let voice = VoiceBookkeepingState()

        voice.beginTextInput(isSignedIn: false)

        #expect(voice.input.alert == .signInRequired)
        #expect(!voice.isTextInputPresented)
    }

    @Test("已登录点打字入口打开输入框")
    func textInputOpensWhenSignedIn() {
        let voice = VoiceBookkeepingState()

        voice.beginTextInput(isSignedIn: true)

        #expect(voice.input.alert == nil)
        #expect(voice.isTextInputPresented)
    }

    // MARK: - 辅助

    private func makeFlow() -> DiningExpenseEntryFlow {
        DiningExpenseEntryFlow(
            initialAccountID: UUID(),
            now: Date(timeIntervalSince1970: 0),
            saveAction: { _ in }
        )
    }

    private func makeAccount(deactivatedAt: Date? = nil) -> Account {
        Account(
            id: UUID(),
            typeRawValue: AccountType.cash.rawValue,
            templateID: nil,
            name: "现金",
            note: nil,
            lastFourDigits: nil,
            balance: 0,
            currencyCode: "CNY",
            createdAt: .now,
            updatedAt: .now,
            deactivatedAt: deactivatedAt
        )
    }
}
