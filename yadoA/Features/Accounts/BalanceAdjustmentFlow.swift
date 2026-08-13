import Combine
import Foundation

/// 余额调整写入边界的无副作用或成功结果。
enum BalanceAdjustmentSaveResult: Equatable, Sendable {
    /// 已原子保存余额和对应流水。
    case saved(currentBalance: Decimal)

    /// 保存时目标余额已等于实际余额，没有产生任何写入。
    case unchanged(currentBalance: Decimal)
}

/// 余额调整页面注入的显式保存动作。
typealias BalanceAdjustmentSaveAction = @MainActor (
    BalanceAdjustmentDraft
) async throws -> BalanceAdjustmentSaveResult

/// 余额调整提交期间的页面状态。
enum BalanceAdjustmentSubmissionState: Equatable {
    case editing
    case saving
    case failed
}

/// 持有目标总余额草稿，并协调原生金额输入和防重复提交。
@MainActor
final class BalanceAdjustmentFlow: ObservableObject {
    /// Sheet 生命周期内及失败重试期间共享的同一份草稿。
    @Published private(set) var draft: BalanceAdjustmentDraft

    /// 当前提交状态；失败时保留草稿供用户继续修改或重试。
    @Published private(set) var submissionState: BalanceAdjustmentSubmissionState = .editing

    /// 用于页面展示与同值判断的最近已知账户余额。
    @Published private(set) var currentBalance: Decimal

    /// 由上层注入的本地持久化动作。
    private let saveAction: BalanceAdjustmentSaveAction

    /// 创建目标总余额调整流程。
    ///
    /// - Parameters:
    ///   - draft: 已按当前余额预填的稳定草稿。
    ///   - currentBalance: 打开 Sheet 时最近已知的账户余额。
    ///   - saveAction: 显式保存目标余额与调整流水的动作。
    init(
        draft: BalanceAdjustmentDraft,
        currentBalance: Decimal,
        saveAction: @escaping BalanceAdjustmentSaveAction
    ) {
        self.draft = draft
        self.currentBalance = currentBalance
        self.saveAction = saveAction
    }

    /// 当前是否正在保存，用于拒绝重复操作。
    var isSaving: Bool { submissionState == .saving }

    /// 最近一次保存是否失败。
    var hasSaveError: Bool { submissionState == .failed }

    /// 草稿是否包含有效且相对最近已知余额发生变化的目标值。
    var canSubmit: Bool {
        guard let targetBalance = draft.targetBalance else { return false }
        return targetBalance != currentBalance && !isSaving
    }

    /// 接收系统数字键盘输入，统一小数点并限制最多两位小数。
    func updateAmountText(_ amountText: String, decimalSeparator: String) {
        guard !isSaving,
              let normalizedText = AccountAmountParser.normalizedCNYAmountText(
                  amountText,
                  decimalSeparator: decimalSeparator
              )
        else { return }

        draft.amountText = normalizedText
        if AccountAmountParser.cnyAmount(fromNormalized: normalizedText) == 0 {
            draft.sign = .positive
        }
        markAsEditing()
    }

    /// 更新正负状态；零值不保留负号语义。
    func updateSign(_ sign: BalanceAdjustmentSign) {
        guard !isSaving else { return }
        if AccountAmountParser.cnyAmount(fromNormalized: draft.amountText) == 0 {
            draft.sign = .positive
        } else {
            draft.sign = sign
        }
        markAsEditing()
    }

    /// 更新可选调整原因，并清除旧失败提示。
    func updateNote(_ note: String) {
        guard !isSaving else { return }
        draft.note = note
        markAsEditing()
    }

    /// 复制草稿并执行一次显式保存；失败时原草稿保持不变。
    ///
    /// - Parameter onSaved: 仅在余额与流水均成功持久化后调用。
    func submit(onSaved: @escaping @MainActor () -> Void) async {
        guard canSubmit else { return }

        let submittedDraft = draft
        submissionState = .saving
        do {
            switch try await saveAction(submittedDraft) {
            case let .saved(currentBalance):
                self.currentBalance = currentBalance
                submissionState = .editing
                onSaved()
            case let .unchanged(currentBalance):
                self.currentBalance = currentBalance
                submissionState = .editing
            }
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
