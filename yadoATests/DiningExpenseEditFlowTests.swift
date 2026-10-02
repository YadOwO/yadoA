import Foundation
import Testing
@testable import yadoA

@Suite("收支完整编辑流程", .serialized)
@MainActor
struct DiningExpenseEditFlowTests {
    @Test("有效修改只保存一次且成功后关闭")
    func validEditSavesOnceAndDismissesAfterSuccess() async {
        let original = DiningExpenseEditDraft(
            id: UUID(),
                accountID: UUID(),
            title: "餐饮",
            amountText: "12.34",
                transactionDay: 20260901
        )
        var attempts: [DiningExpenseEditDraft] = []
        var dismissals = 0
        let flow = DiningExpenseEditFlow(draft: original) { draft in
            attempts.append(draft)
        }
        flow.updateTitle("工作午餐")
        flow.updateAmountText("20.00", decimalSeparator: ".")

        await flow.submit {
            dismissals += 1
        }

        #expect(attempts.count == 1)
        #expect(attempts[0].title == "工作午餐")
        #expect(attempts[0].amount == Decimal(20))
        #expect(dismissals == 1)
        #expect(flow.submissionState == .editing)
    }

    @Test("空标题或无效金额不会保存")
    func invalidEditNeverSaves() async {
        let draft = DiningExpenseEditDraft(
            id: UUID(),
                accountID: UUID(),
            title: "餐饮",
            amountText: "12.34",
                transactionDay: 20260901
        )
        var attempts = 0
        let flow = DiningExpenseEditFlow(draft: draft) { _ in
            attempts += 1
        }

        flow.updateTitle("  ")
        await flow.submit {}
        #expect(attempts == 0)

        let invalidAmountFlow = DiningExpenseEditFlow(
            draft: DiningExpenseEditDraft(
                id: UUID(),
                accountID: UUID(),
                title: "晚餐",
                amountText: "1.001",
                transactionDay: 20260901
            )
        ) { _ in
            attempts += 1
        }
        await invalidAmountFlow.submit {}
        #expect(attempts == 0)
    }

    @Test("保存失败保留编辑内容，重试成功后只关闭一次")
    func failedEditPreservesDraftAndRetrySucceeds() async {
        let draft = DiningExpenseEditDraft(
            id: UUID(),
                accountID: UUID(),
            title: "餐饮",
            amountText: "12.34",
                transactionDay: 20260901
        )
        let failureState = EditFailureState()
        var attempts: [DiningExpenseEditDraft] = []
        var dismissals = 0
        let flow = DiningExpenseEditFlow(draft: draft) { submittedDraft in
            attempts.append(submittedDraft)
            if failureState.shouldFail {
                throw InjectedEditFailure()
            }
        }
        flow.updateTitle("新的标题")

        await flow.submit { dismissals += 1 }
        #expect(flow.hasSaveError)
        #expect(flow.draft.title == "新的标题")
        #expect(dismissals == 0)

        failureState.shouldFail = false
        await flow.submit { dismissals += 1 }

        #expect(attempts.count == 2)
        #expect(attempts[0] == attempts[1])
        #expect(dismissals == 1)
        #expect(flow.submissionState == .editing)
    }

    @Test("完整字段提交使用稳定快照，保存中禁止再次提交和修改")
    func pendingSaveFreezesAllFieldsAndPreventsDuplicateSubmission() async {
        let original = DiningExpenseEditDraft(
            id: UUID(), accountID: UUID(), title: "午餐",
            amountText: "20", transactionDay: 20260901
        )
        let gate = AsyncSaveGate()
        var attempts: [DiningExpenseEditDraft] = []
        let flow = DiningExpenseEditFlow(draft: original) { draft in
            attempts.append(draft)
            await gate.wait()
        }
        let targetAccount = UUID()
        flow.update {
            $0.accountID = targetAccount
            $0.entryType = .income
            $0.incomeCategory = .refund
            $0.transactionDay = 20260902
            $0.note = "已退回"
        }
        let submitted = flow.draft
        let saveTask = Task { await flow.submit {} }
        while !gate.hasStarted { await Task.yield() }
        flow.update { $0.note = "不应写入" }
        flow.updateAmountText("99", decimalSeparator: ".")
        await flow.submit {}
        #expect(attempts == [submitted])
        #expect(flow.draft == submitted)
        #expect(flow.isSaving)
        gate.resume()
        await saveTask.value
        #expect(!flow.isSaving)
    }

    @Test("无效公历日期不能提交")
    func invalidBusinessDayPreventsSubmission() async {
        let flow = DiningExpenseEditFlow(draft: DiningExpenseEditDraft(
            id: UUID(), accountID: UUID(), title: "午餐",
            amountText: "20", transactionDay: 20260230
        )) { _ in
            Issue.record("无效日期不应进入保存动作")
        }
        #expect(!flow.canSubmit)
        await flow.submit {}
    }
}

@MainActor
private final class EditFailureState {
    /// 下一次快速修改保存是否注入失败。
    var shouldFail = true
}

private struct InjectedEditFailure: Error {}
