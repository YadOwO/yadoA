import Foundation
import Testing
@testable import yadoA

@Suite("转账流程", .serialized)
@MainActor
struct TransferFlowTests {
    @Test("选到对面已选的账户时两边互换，不会出现同一个账户")
    func selectingCounterpartSwapsAccounts() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let flow = makeFlow(draft: TransferDraft(fromAccountID: first, toAccountID: second, transactionDay: 20261022))

        flow.selectToAccount(first)
        #expect(flow.draft.fromAccountID == second)
        #expect(flow.draft.toAccountID == first)

        flow.selectFromAccount(third)
        #expect(flow.draft.fromAccountID == third)
        #expect(flow.draft.toAccountID == first)

        flow.swapAccounts()
        #expect(flow.draft.fromAccountID == first)
        #expect(flow.draft.toAccountID == third)
    }

    @Test("金额为正、两个账户都选好才能提交")
    func canSubmitRequiresAmountAndBothAccounts() {
        let flow = makeFlow(draft: TransferDraft(fromAccountID: UUID(), transactionDay: 20261022))
        #expect(!flow.canSubmit)

        flow.selectToAccount(UUID())
        #expect(!flow.canSubmit)

        flow.updateAmountText("0", decimalSeparator: ".")
        #expect(!flow.canSubmit)

        flow.updateAmountText(",5", decimalSeparator: ",")
        #expect(flow.draft.amountText == "0.5")
        #expect(flow.canSubmit)

        flow.updateAmountText("1.234", decimalSeparator: ".")
        #expect(flow.draft.amountText == "0.5")
    }

    @Test("保存失败保留草稿，修改后回到可编辑状态")
    func failedSaveKeepsDraft() async {
        struct InjectedFailure: Error {}
        var savedDrafts: [TransferDraft] = []
        let flow = TransferFlow(
            draft: TransferDraft(
                fromAccountID: UUID(),
                toAccountID: UUID(),
                amountText: "12",
                transactionDay: 20261022
            )
        ) { draft in
            savedDrafts.append(draft)
            throw InjectedFailure()
        }
        var didFinish = false

        await flow.submit { didFinish = true }

        #expect(flow.hasSaveError)
        #expect(!didFinish)
        #expect(savedDrafts.count == 1)
        #expect(flow.draft.amountText == "12")

        flow.updateNote("午饭 AA")
        #expect(!flow.hasSaveError)
    }

    /// 创建一个保存总是成功的转账流程。
    private func makeFlow(draft: TransferDraft) -> TransferFlow {
        TransferFlow(draft: draft) { _ in }
    }
}
