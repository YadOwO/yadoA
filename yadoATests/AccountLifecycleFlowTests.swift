import Foundation
import Testing
@testable import yadoA

@Suite("账户生命周期流程")
@MainActor
struct AccountLifecycleFlowTests {
    @Test("保存失败保留确认内容并支持重试")
    func failurePreservesExpectation() {
        let state = FailureState()
        let expectation = AccountDisposalExpectation(
            accountID: UUID(),
            action: .deactivate,
            expectedDefaultAccountID: UUID(),
            replacementAccountID: UUID(),
            allowsNoDefault: false
        )
        var savedCount = 0
        let flow = AccountLifecycleFlow(expectation: expectation) { _ in
            if state.shouldFail {
                throw AccountRepositoryError.nonZeroBalance(expectation.accountID)
            }
            savedCount += 1
        }

        flow.submit()
        #expect(flow.submissionState == .editing)
        #expect(flow.lastError == .nonZeroBalance(expectation.accountID))
        state.shouldFail = false
        flow.submit()
        #expect(savedCount == 1)
        #expect(flow.lastError == nil)
    }

    @Test("状态漂移会要求关闭旧确认并刷新")
    func expectedStateChangeRequestsRefresh() {
        let expectation = AccountDisposalExpectation(
            accountID: UUID(),
            action: .delete,
            expectedDefaultAccountID: nil,
            replacementAccountID: nil,
            allowsNoDefault: true
        )
        var needsRefresh = false
        let flow = AccountLifecycleFlow(expectation: expectation) { _ in
            throw AccountRepositoryError.expectedStateChanged
        }

        flow.submit(onNeedsRefresh: { needsRefresh = true })

        #expect(flow.submissionState == .needsRefresh)
        #expect(needsRefresh)
        #expect(flow.lastError == .expectedStateChanged)
    }
}

@MainActor
private final class FailureState {
    var shouldFail = true
}
