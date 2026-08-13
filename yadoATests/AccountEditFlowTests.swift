import Foundation
import Testing
@testable import yadoA

@Suite("账户编辑流程", .serialized)
@MainActor
struct AccountEditFlowTests {
    @Test("有效编辑只保存一次且成功后关闭")
    func validEditSavesOnceAndDismissesAfterSuccess() async throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let repository = LocalAccountRepository(container: dataContainer.modelContainer)
        try repository.save(
            AccountDraft(
                accountType: .cash,
                name: "现金",
                amountText: "40"
            )
        )
        let account = try #require(try repository.accounts().first)
        var draft = AccountEditDraft(account: account)
        draft.name = "旅行现金"
        var saveAttempts = 0
        var dismissals = 0
        let flow = AccountEditFlow(draft: draft) { submittedDraft in
            saveAttempts += 1
            try repository.update(submittedDraft)
        }

        await flow.submit {
            dismissals += 1
        }

        #expect(saveAttempts == 1)
        #expect(dismissals == 1)
        #expect(try repository.account(id: account.id)?.name == "旅行现金")
        #expect(flow.submissionState == .editing)
    }

    @Test("空名称不会保存或关闭")
    func invalidEditNeverSaves() async {
        let account = Account(
            id: UUID(),
            typeRawValue: AccountType.cash.rawValue,
            templateID: nil,
            name: "现金",
            note: nil,
            lastFourDigits: nil,
            balance: 40,
            currencyCode: "CNY",
            createdAt: .now,
            updatedAt: .now
        )
        var draft = AccountEditDraft(account: account)
        draft.name = "   "
        var saveAttempts = 0
        var dismissals = 0
        let flow = AccountEditFlow(draft: draft) { _ in
            saveAttempts += 1
        }

        await flow.submit {
            dismissals += 1
        }

        #expect(saveAttempts == 0)
        #expect(dismissals == 0)
        #expect(flow.submissionState == .editing)
    }

    @Test("保存失败保留编辑内容，重试后只关闭一次")
    func failurePreservesDraftAndRetrySucceeds() async {
        let account = Account(
            id: UUID(),
            typeRawValue: AccountType.debitCard.rawValue,
            templateID: AccountTemplate.banks(for: .debitCard)[1].id,
            name: "建设银行",
            note: "旧备注",
            lastFourDigits: "1234",
            balance: 100,
            currencyCode: "CNY",
            createdAt: .now,
            updatedAt: .now
        )
        var draft = AccountEditDraft(account: account)
        draft.note = "新备注"
        draft.lastFourDigits = "9876"
        let failureState = AccountEditFailureState()
        var attempts: [AccountEditDraft] = []
        var dismissals = 0
        let flow = AccountEditFlow(draft: draft) { submittedDraft in
            attempts.append(submittedDraft)
            if failureState.shouldFail {
                throw InjectedEditFailure()
            }
        }

        await flow.submit { dismissals += 1 }

        #expect(flow.submissionState == .failed)
        #expect(flow.hasSaveError)
        #expect(flow.draft == draft)
        #expect(dismissals == 0)

        failureState.shouldFail = false
        await flow.submit { dismissals += 1 }

        #expect(attempts.count == 2)
        #expect(attempts[0] == attempts[1])
        #expect(dismissals == 1)
        #expect(flow.submissionState == .editing)
    }

    @Test("编辑入口文案支持中英文")
    func visibleCopyIsLocalized() {
        #expect(
            AccountLocalization.string(
                "account.detail.edit",
                locale: Locale(identifier: "en")
            ) == "Edit"
        )
        #expect(
            AccountLocalization.string(
                "account.edit.title",
                locale: Locale(identifier: "zh-Hans")
            ) == "编辑账户"
        )
    }
}

@MainActor
private final class AccountEditFailureState {
    /// 下一次编辑保存是否注入失败。
    var shouldFail = true
}

private struct InjectedEditFailure: Error {}
