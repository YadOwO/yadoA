import Foundation
import Testing
@testable import yadoA

@Suite("账户创建流程", .serialized)
@MainActor
struct AccountCreationFlowTests {
    @Test("有效现金账户只保存一次且成功后才关闭")
    func validCashSavesOnceAndDismissesAfterSuccess() async throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let repository = LocalAccountRepository(container: dataContainer.modelContainer)
        let draft = AccountDraft(
            id: UUID(),
            accountType: .cash,
            name: "现金",
            note: "备用金",
            amountText: "40"
        )
        var saveAttempts = 0
        var dismissals = 0
        let flow = AccountCreationFlow(draft: draft) { submittedDraft in
            saveAttempts += 1
            try repository.save(
                submittedDraft,
                locale: Locale(identifier: "en_US")
            )
        }

        await flow.submit {
            dismissals += 1
        }

        let account = try #require(try repository.account(id: draft.id))
        #expect(saveAttempts == 1)
        #expect(dismissals == 1)
        #expect(account.id == draft.id)
        #expect(account.balance == 40)
        #expect(account.note == "备用金")
    }

    @Test("模板账户提交时保留所选类型和模板")
    func templateSelectionIsPreserved() async {
        let template = AccountTemplate.banks(for: .debitCard)[1]
        let draft = AccountDraft(
            accountType: .debitCard,
            template: template,
            lastFourDigits: "1234",
            amountText: "100"
        )
        var capturedDraft: AccountDraft?
        let flow = AccountCreationFlow(draft: draft) { submittedDraft in
            capturedDraft = submittedDraft
        }

        await flow.submit {}

        #expect(capturedDraft?.id == draft.id)
        #expect(capturedDraft?.accountType == .debitCard)
        #expect(capturedDraft?.template == template)
        #expect(capturedDraft?.lastFourDigits == "1234")
    }

    @Test("无效草稿不会调用保存或关闭")
    func invalidDraftNeverSaves() async {
        var saveAttempts = 0
        var dismissals = 0
        let flow = AccountCreationFlow(
            draft: AccountDraft(
                accountType: .customAsset,
                name: "   ",
                amountText: "invalid"
            )
        ) { _ in
            saveAttempts += 1
        }

        await flow.submit {
            dismissals += 1
        }

        #expect(saveAttempts == 0)
        #expect(dismissals == 0)
        #expect(flow.submissionState == .editing)
    }

    @Test("表单校验与保存共用指定语言环境")
    func validationUsesInjectedLocale() async {
        let germanLocale = Locale(identifier: "de_DE")
        var capturedDraft: AccountDraft?
        let flow = AccountCreationFlow(
            draft: AccountDraft(
                accountType: .cash,
                name: "Bargeld",
                amountText: "1,5"
            )
        ) { draft in
            capturedDraft = draft
        }

        await flow.submit(locale: germanLocale) {}

        #expect(capturedDraft?.amountText == "1,5")
    }

    @Test("第一次保存挂起时连续提交只执行一次")
    func rapidSubmissionsOnlyStartOneSave() async {
        let gate = AsyncSaveGate()
        var saveAttempts = 0
        var dismissals = 0
        let flow = AccountCreationFlow(
            draft: AccountDraft(
                accountType: .cash,
                name: "现金",
                amountText: "1"
            )
        ) { _ in
            saveAttempts += 1
            await gate.wait()
        }

        let firstSubmission = Task {
            await flow.submit { dismissals += 1 }
        }
        while !gate.hasStarted {
            await Task.yield()
        }

        let duplicateSubmission = Task {
            await flow.submit { dismissals += 1 }
        }
        await duplicateSubmission.value

        #expect(flow.submissionState == .saving)
        #expect(saveAttempts == 1)
        #expect(dismissals == 0)

        gate.resume()
        await firstSubmission.value

        #expect(saveAttempts == 1)
        #expect(dismissals == 1)
        #expect(flow.submissionState == .editing)
    }

    @Test("失败保留完整草稿与错误状态，重试后只关闭一次")
    func failurePreservesDraftAndRetrySucceeds() async {
        let template = AccountTemplate.creditInstitutions[0]
        let originalDraft = AccountDraft(
            id: UUID(),
            accountType: .creditCard,
            template: template,
            name: "花呗日常",
            note: "每月还款",
            lastFourDigits: "9876",
            amountText: "2800"
        )
        let failureState = AccountCreationFailureState()
        var attempts: [AccountDraft] = []
        var dismissals = 0
        let flow = AccountCreationFlow(draft: originalDraft) { draft in
            attempts.append(draft)
            if failureState.shouldFail {
                throw InjectedCreationFailure()
            }
        }

        await flow.submit { dismissals += 1 }

        #expect(flow.submissionState == .failed)
        #expect(flow.hasSaveError)
        #expect(flow.draft == originalDraft)
        #expect(dismissals == 0)

        failureState.shouldFail = false
        await flow.submit { dismissals += 1 }

        #expect(attempts.count == 2)
        #expect(attempts[0].id == attempts[1].id)
        #expect(attempts[1] == originalDraft)
        #expect(dismissals == 1)
        #expect(flow.submissionState == .editing)
    }

    @Test("取消与保存错误文案提供中英文值")
    func visibleCopyIsLocalized() {
        #expect(
            AccountLocalization.string(
                "common.cancel",
                locale: Locale(identifier: "en")
            ) == "Cancel"
        )
        #expect(
            AccountLocalization.string(
                "common.cancel",
                locale: Locale(identifier: "zh-Hans")
            ) == "取消"
        )
        #expect(
            AccountLocalization.string(
                "account.creation.save_error.message",
                locale: Locale(identifier: "en")
            ).contains("preserved")
        )
        #expect(
            AccountLocalization.string(
                "account.creation.save_error.message",
                locale: Locale(identifier: "zh-Hans")
            ).contains("保留")
        )
    }
}

private struct InjectedCreationFailure: Error {}

@MainActor
private final class AccountCreationFailureState {
    /// 下一次保存是否注入失败。
    var shouldFail = true
}
