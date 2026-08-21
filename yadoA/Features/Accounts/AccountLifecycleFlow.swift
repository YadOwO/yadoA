import Combine
import Foundation

/// 账户处置流程的提交状态。
enum AccountLifecycleSubmissionState: Equatable {
    /// 尚未提交或上一次提交失败后可重试。
    case editing

    /// 正在执行最终的生命周期命令。
    case saving

    /// 最终状态已漂移，需要重新预检和确认。
    case needsRefresh
}

/// 账户生命周期页面注入的同步保存动作。
typealias AccountLifecycleSaveAction = @MainActor (AccountDisposalExpectation) throws -> Void

/// 管理账户删除/停用确认内容并防止重复提交。
@MainActor
final class AccountLifecycleFlow: ObservableObject {
    /// 用户当前选择的处置预期。
    @Published private(set) var expectation: AccountDisposalExpectation

    /// 当前提交状态。
    @Published private(set) var submissionState: AccountLifecycleSubmissionState = .editing

    /// 最近一次提交错误；失败时保留确认内容供重试。
    @Published private(set) var lastError: AccountRepositoryError?

    /// 注入的账户生命周期保存动作。
    private let saveAction: AccountLifecycleSaveAction

    /// 创建一条账户生命周期流程。
    init(
        expectation: AccountDisposalExpectation,
        saveAction: @escaping AccountLifecycleSaveAction
    ) {
        self.expectation = expectation
        self.saveAction = saveAction
    }

    /// 保存进行中时阻止重复提交。
    var isSaving: Bool { submissionState == .saving }

    /// 更新接替者或无默认确认，不改变既有处置动作预期。
    func update(
        replacementAccountID: UUID?,
        allowsNoDefault: Bool
    ) {
        guard !isSaving else { return }
        expectation = AccountDisposalExpectation(
            accountID: expectation.accountID,
            action: expectation.action,
            expectedDefaultAccountID: expectation.expectedDefaultAccountID,
            replacementAccountID: replacementAccountID,
            allowsNoDefault: allowsNoDefault
        )
    }

    /// 提交账户处置；状态漂移单独标记，要求用户重新确认。
    func submit(
        onSaved: @MainActor () -> Void = {},
        onNeedsRefresh: @MainActor () -> Void = {}
    ) {
        guard !isSaving else { return }
        submissionState = .saving
        lastError = nil

        do {
            try saveAction(expectation)
            submissionState = .editing
            onSaved()
        } catch let error as AccountRepositoryError {
            lastError = error
            submissionState = error == .expectedStateChanged ? .needsRefresh : .editing
            if error == .expectedStateChanged {
                onNeedsRefresh()
            }
        } catch {
            submissionState = .editing
        }
    }
}
