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
            amountText: "12.34",
                transactionDay: 20260901
        )
        var attempts: [DiningExpenseEditDraft] = []
        var dismissals = 0
        let flow = DiningExpenseEditFlow(draft: original) { draft in
            attempts.append(draft)
        }
        flow.updateNote("工作午餐")
        flow.updateAmountText("20.00", decimalSeparator: ".")

        await flow.submit {
            dismissals += 1
        }

        #expect(attempts.count == 1)
        #expect(attempts[0].note == "工作午餐")
        #expect(attempts[0].amount == Decimal(20))
        #expect(dismissals == 1)
        #expect(flow.submissionState == .editing)
    }

    @Test("备注留空可以保存，无效金额不会保存")
    func blankNoteSavesButInvalidAmountNeverSaves() async {
        let draft = DiningExpenseEditDraft(
            id: UUID(),
                accountID: UUID(),
            amountText: "12.34",
                transactionDay: 20260901,
            note: "午餐"
        )
        var attempts = 0
        let flow = DiningExpenseEditFlow(draft: draft) { _ in
            attempts += 1
        }

        flow.updateNote("  ")
        #expect(flow.canSubmit)
        await flow.submit {}
        #expect(attempts == 1)

        let invalidAmountFlow = DiningExpenseEditFlow(
            draft: DiningExpenseEditDraft(
                id: UUID(),
                accountID: UUID(),
                amountText: "1.001",
                transactionDay: 20260901
            )
        ) { _ in
            attempts += 1
        }
        await invalidAmountFlow.submit {}
        #expect(attempts == 1)
    }

    @Test("保存失败保留编辑内容，重试成功后只关闭一次")
    func failedEditPreservesDraftAndRetrySucceeds() async {
        let draft = DiningExpenseEditDraft(
            id: UUID(),
                accountID: UUID(),
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
        flow.updateNote("新的备注")

        await flow.submit { dismissals += 1 }
        #expect(flow.hasSaveError)
        #expect(flow.draft.note == "新的备注")
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
            id: UUID(), accountID: UUID(),
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
            $0.incomeCategoryKey = IncomeCategory.refund.rawValue
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
            id: UUID(), accountID: UUID(),
            amountText: "20", transactionDay: 20260230
        )) { _ in
            Issue.record("无效日期不应进入保存动作")
        }
        #expect(!flow.canSubmit)
        await flow.submit {}
    }

    @Test("草稿分类随流水删除后撤销选择，重新选择前不能提交")
    func clearedCategoryRequiresReselectionBeforeSubmit() async {
        let original = DiningExpenseEditDraft(
            id: UUID(), accountID: UUID(),
            amountText: "20", transactionDay: 20260901
        )
        var attempts: [DiningExpenseEditDraft] = []
        let flow = DiningExpenseEditFlow(draft: original) { attempts.append($0) }
        flow.selectCategory(key: "custom-pet")

        flow.clearCategory()
        #expect(flow.formCategoryKey == nil)
        #expect(!flow.canSubmit)
        await flow.submit {}
        #expect(attempts.isEmpty)

        // 另一方向不受影响；切回来仍需重新选择。
        flow.selectEntryType(.income)
        #expect(flow.formCategoryKey == IncomeCategory.salary.rawValue)
        #expect(flow.canSubmit)
        flow.selectEntryType(.expense)
        #expect(flow.formCategoryKey == nil)

        flow.selectCategory(key: ExpenseCategory.dining.rawValue)
        #expect(flow.formCategoryKey == ExpenseCategory.dining.rawValue)
        await flow.submit {}
        #expect(attempts.count == 1)
        #expect(attempts[0].expenseCategoryKey == ExpenseCategory.dining.rawValue)
    }

    @Test("所编辑的流水被删除后不能再提交")
    func removedTransactionPreventsSubmission() async {
        let flow = DiningExpenseEditFlow(draft: DiningExpenseEditDraft(
            id: UUID(), accountID: UUID(),
            amountText: "20", transactionDay: 20260901
        )) { _ in
            Issue.record("流水已删除时不应进入保存动作")
        }
        #expect(flow.canSubmit)

        flow.markTransactionRemoved()

        #expect(flow.isEntryRemoved)
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
