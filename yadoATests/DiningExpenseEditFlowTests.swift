import Foundation
import Testing
@testable import yadoA

@Suite("首页记账快速修改流程", .serialized)
@MainActor
struct DiningExpenseEditFlowTests {
    @Test("有效修改只保存一次且成功后关闭")
    func validEditSavesOnceAndDismissesAfterSuccess() async {
        let original = DiningExpenseEditDraft(
            id: UUID(),
            title: "餐饮",
            amountText: "12.34"
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
            title: "餐饮",
            amountText: "12.34"
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
                title: "晚餐",
                amountText: "1.001"
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
            title: "餐饮",
            amountText: "12.34"
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
}

@MainActor
private final class EditFailureState {
    /// 下一次快速修改保存是否注入失败。
    var shouldFail = true
}

private struct InjectedEditFailure: Error {}
