import Combine
import Foundation

/// 转账页面注入的显式保存动作。
typealias TransferSaveAction = @MainActor (TransferDraft) async throws -> Void

/// 转账提交期间的页面状态。
enum TransferSubmissionState: Equatable {
    case editing
    case saving
    case failed
}

/// 持有转账草稿，协调金额输入、账户选择和防重复提交。
@MainActor
final class TransferFlow: ObservableObject {
    /// 表单生命周期内及失败重试期间共享的同一份草稿。
    @Published private(set) var draft: TransferDraft

    /// 当前提交状态；失败时保留草稿供用户修改或重试。
    @Published private(set) var submissionState: TransferSubmissionState = .editing

    /// 由上层注入的本地持久化动作。
    private let saveAction: TransferSaveAction

    /// 创建转账流程。
    ///
    /// - Parameters:
    ///   - draft: 已预选当前账户的草稿。
    ///   - saveAction: 原子保存转账和两边余额的动作。
    init(draft: TransferDraft, saveAction: @escaping TransferSaveAction) {
        self.draft = draft
        self.saveAction = saveAction
    }

    /// 当前是否正在保存，用于拒绝重复操作。
    var isSaving: Bool { submissionState == .saving }

    /// 最近一次保存是否失败。
    var hasSaveError: Bool { submissionState == .failed }

    /// 草稿完整且不在保存中时才能提交。
    var canSubmit: Bool { draft.isComplete && !isSaving }

    /// 接收系统数字键盘输入，统一小数点并限制最多两位小数。
    func updateAmountText(_ amountText: String, decimalSeparator: String) {
        guard !isSaving,
              let normalizedText = AccountAmountParser.normalizedCNYAmountText(
                  amountText,
                  decimalSeparator: decimalSeparator
              )
        else { return }
        draft.amountText = normalizedText
        markAsEditing()
    }

    /// 选择转出账户；选到当前的转入账户时两边互换，避免出现同一个账户。
    func selectFromAccount(_ accountID: UUID) {
        guard !isSaving else { return }
        if accountID == draft.toAccountID {
            draft.swapAccounts()
        } else {
            draft.fromAccountID = accountID
        }
        markAsEditing()
    }

    /// 选择转入账户；选到当前的转出账户时两边互换，避免出现同一个账户。
    func selectToAccount(_ accountID: UUID) {
        guard !isSaving else { return }
        if accountID == draft.fromAccountID {
            draft.swapAccounts()
        } else {
            draft.toAccountID = accountID
        }
        markAsEditing()
    }

    /// 交换转出和转入账户。
    func swapAccounts() {
        guard !isSaving else { return }
        draft.swapAccounts()
        markAsEditing()
    }

    /// 更新记账日。
    func updateTransactionDay(_ transactionDay: Int) {
        guard !isSaving, TransactionDay.isValid(transactionDay) else { return }
        draft.transactionDay = transactionDay
        markAsEditing()
    }

    /// 更新可选备注。
    func updateNote(_ note: String) {
        guard !isSaving else { return }
        draft.note = note
        markAsEditing()
    }

    /// 复制草稿并执行一次显式保存；失败时原草稿保持不变。
    ///
    /// - Parameter onSaved: 仅在转账与两边余额均成功持久化后调用。
    func submit(onSaved: @escaping @MainActor () -> Void) async {
        guard canSubmit else { return }
        let submittedDraft = draft
        submissionState = .saving
        do {
            try await saveAction(submittedDraft)
            submissionState = .editing
            onSaved()
        } catch {
            submissionState = .failed
        }
    }

    /// 用户修改草稿后回到可提交状态。
    private func markAsEditing() {
        if submissionState == .failed {
            submissionState = .editing
        }
    }
}
