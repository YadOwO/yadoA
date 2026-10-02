import Foundation
import Testing
@testable import yadoA

@Suite("默认记账账户草稿流程")
@MainActor
struct DiningExpenseEntryFlowTests {
    @Test("切换收入后必须重新选择收入分类才能提交")
    func incomeRequiresItsOwnCategorySelection() {
        let flow = DiningExpenseEntryFlow(
            initialAccountID: UUID(),
            now: Date(timeIntervalSince1970: 0),
            saveAction: { _ in }
        )
        flow.updateAmountText("100", decimalSeparator: ".")
        flow.selectCategory(.dining)

        flow.selectEntryType(.income)

        #expect(flow.selectedCategory == nil)
        #expect(flow.selectedIncomeCategory == nil)
        #expect(!flow.canSubmit)

        flow.selectIncomeCategory(.salary)

        #expect(flow.selectedIncomeCategory == .salary)
        #expect(flow.canSubmit)
    }

    @Test("新建支出必须明确选择分类后才能提交")
    func newExpenseRequiresCategorySelection() {
        let flow = DiningExpenseEntryFlow(
            initialAccountID: UUID(),
            now: Date(timeIntervalSince1970: 0),
            saveAction: { _ in }
        )

        flow.updateAmountText("12.50", decimalSeparator: ".")

        #expect(flow.selectedCategory == nil)
        #expect(!flow.canSubmit)

        flow.selectCategory(.dining)

        #expect(flow.selectedCategory == .dining)
        #expect(flow.canSubmit)
    }

    @Test("恢复草稿保留原分类且切换分类不丢失其他输入")
    func categorySelectionPreservesDraft() {
        let accountID = UUID()
        let flow = DiningExpenseEntryFlow(
            draft: DiningExpenseDraft(
                accountID: accountID,
                amountText: "88.50",
                transactionDay: 20260831,
                note: "周末出行"
            ),
            saveAction: { _ in }
        )

        #expect(flow.selectedCategory == .dining)

        flow.selectCategory(.travel)

        #expect(flow.draft.category == .travel)
        #expect(flow.selectedCategory == .travel)
        #expect(flow.draft.accountID == accountID)
        #expect(flow.draft.amountText == "88.50")
        #expect(flow.draft.note == "周末出行")
    }

    @Test("默认只初始化一次，手动选择和后续默认变化不覆盖草稿")
    func defaultIsOneTimeOnly() {
        let originalID = UUID()
        let manuallySelectedID = UUID()
        let flow = DiningExpenseEntryFlow(
            draft: DiningExpenseDraft(
                accountID: nil,
                amountText: "12.50",
                transactionDay: 20260821
            ),
            saveAction: { _ in }
        )

        flow.applyInitialDefault(originalID)
        #expect(flow.draft.accountID == originalID)

        flow.selectAccount(id: manuallySelectedID)
        flow.applyInitialDefault(UUID())
        #expect(flow.draft.accountID == manuallySelectedID)
        #expect(flow.draft.amountText == "12.50")
    }

    @Test("失效账户仍保留 UUID 和其他草稿字段，恢复同一 UUID 后可继续")
    func draftPreservesInvalidSelection() {
        let accountID = UUID()
        let flow = DiningExpenseEntryFlow(
            draft: DiningExpenseDraft(
                accountID: accountID,
                amountText: "8",
                transactionDay: 20260821,
                note: "午餐"
            ),
            saveAction: { _ in }
        )

        #expect(flow.draft.accountID == accountID)
        #expect(flow.draft.note == "午餐")
        flow.applyInitialDefault(UUID())
        #expect(flow.draft.accountID == accountID)
    }
}
