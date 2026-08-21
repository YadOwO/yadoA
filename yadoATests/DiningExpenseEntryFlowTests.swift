import Foundation
import Testing
@testable import yadoA

@Suite("默认记账账户草稿流程")
@MainActor
struct DiningExpenseEntryFlowTests {
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
