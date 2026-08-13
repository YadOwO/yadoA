import Foundation
import Testing
@testable import yadoA

@Suite("余额调整流程", .serialized)
@MainActor
struct BalanceAdjustmentFlowTests {
    @Test("当前负余额正确预填，目标值按总余额解析")
    func draftPrefillsNegativeTotal() throws {
        let accountID = UUID()
        let draft = BalanceAdjustmentDraft(accountID: accountID, currentBalance: -10.25)

        #expect(draft.accountID == accountID)
        #expect(draft.amountText == "10.25")
        #expect(draft.sign == .negative)
        #expect(draft.targetBalance == Decimal(string: "-10.25"))
    }

    @Test("区域小数输入限制两位且零不保留负号")
    func nativeAmountInputNormalizesPrecisionAndZeroSign() {
        let flow = makeFlow(currentBalance: 10)

        flow.updateAmountText(",5", decimalSeparator: ",")
        #expect(flow.draft.amountText == "0.5")
        flow.updateSign(.negative)
        #expect(flow.draft.targetBalance == Decimal(string: "-0.5"))

        flow.updateAmountText("0", decimalSeparator: ".")
        flow.updateSign(.negative)
        #expect(flow.draft.sign == .positive)
        #expect(flow.draft.targetBalance == 0)

        flow.updateAmountText("1.234", decimalSeparator: ".")
        #expect(flow.draft.amountText == "0")
    }

    @Test("保存挂起时连续提交只执行一次")
    func rapidSubmissionsOnlyStartOneSave() async {
        let gate = AsyncSaveGate()
        var attempts = 0
        var completions = 0
        let flow = makeFlow(currentBalance: 100) { draft in
            attempts += 1
            await gate.wait()
            return .saved(currentBalance: 120)
        }
        flow.updateAmountText("120", decimalSeparator: ".")

        let first = Task { await flow.submit { completions += 1 } }
        while !gate.hasStarted { await Task.yield() }
        await flow.submit { completions += 1 }

        #expect(attempts == 1)
        #expect(completions == 0)
        #expect(flow.isSaving)

        gate.resume()
        await first.value

        #expect(attempts == 1)
        #expect(completions == 1)
    }

    @Test("失败保留草稿，重试复用同一 UUID")
    func failurePreservesDraftAndRetryUsesSameID() async {
        let failureState = BalanceAdjustmentFailureState()
        var submittedIDs: [UUID] = []
        let flow = makeFlow(currentBalance: 100) { draft in
            submittedIDs.append(draft.id)
            if failureState.shouldFail { throw InjectedBalanceAdjustmentFailure() }
            return .saved(currentBalance: 120)
        }
        flow.updateAmountText("120", decimalSeparator: ".")
        flow.updateNote("  校准  ")
        let originalDraft = flow.draft
        var completions = 0

        await flow.submit { completions += 1 }
        #expect(flow.hasSaveError)
        #expect(flow.draft == originalDraft)
        #expect(completions == 0)

        failureState.shouldFail = false
        await flow.submit { completions += 1 }

        #expect(submittedIDs == [originalDraft.id, originalDraft.id])
        #expect(completions == 1)
    }

    @Test("保存时已同值保持编辑态且不关闭")
    func unchangedResultUpdatesComparisonWithoutClosing() async {
        let flow = makeFlow(currentBalance: 100) { _ in
            .unchanged(currentBalance: 120)
        }
        flow.updateAmountText("120", decimalSeparator: ".")
        var completions = 0

        await flow.submit { completions += 1 }

        #expect(completions == 0)
        #expect(flow.submissionState == .editing)
        #expect(flow.currentBalance == 120)
        #expect(!flow.canSubmit)
    }

    /// 构造带可替换保存动作的流程。
    private func makeFlow(
        currentBalance: Decimal,
        save: @escaping BalanceAdjustmentSaveAction = { _ in
            .unchanged(currentBalance: 0)
        }
    ) -> BalanceAdjustmentFlow {
        let draft = BalanceAdjustmentDraft(accountID: UUID(), currentBalance: currentBalance)
        return BalanceAdjustmentFlow(
            draft: draft,
            currentBalance: currentBalance,
            saveAction: save
        )
    }
}

private struct InjectedBalanceAdjustmentFailure: Error {}

@MainActor
private final class BalanceAdjustmentFailureState {
    /// 下一次保存是否注入失败。
    var shouldFail = true
}
