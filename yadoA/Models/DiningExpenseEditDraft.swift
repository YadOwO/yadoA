import Combine
import Foundation

/// 餐饮流水快速修改草稿的校验错误。
enum DiningExpenseEditDraftValidationError: Error, Equatable {
    /// 快速修改必须保留非空标题。
    case titleRequired
}

/// 首页快速修改餐饮流水时使用的值类型草稿。
struct DiningExpenseEditDraft: Equatable, Sendable {
    /// 需要更新的流水 UUID。
    let id: UUID

    /// 用户可编辑的流水标题。
    var title: String

    /// 系统数字键盘维护的金额字符缓冲区。
    var amountText: String

    /// 创建一份餐饮流水快速修改草稿。
    ///
    /// - Parameters:
    ///   - id: 需要更新的流水 UUID。
    ///   - title: 当前展示标题；旧数据应由调用方传入分类默认标题。
    ///   - amountText: 使用英文句点的小数金额字符。
    init(id: UUID, title: String, amountText: String) {
        self.id = id
        self.title = title
        self.amountText = amountText
    }

    /// 按页面统一的英文句点格式解析精确金额。
    var amount: Decimal? {
        guard let amount = AccountAmountParser.cnyAmount(fromNormalized: amountText),
              amount > 0
        else { return nil }
        return amount
    }

    /// 标题是否包含可持久化的有效内容。
    var hasValidTitle: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 快速编辑页使用的提交流程。
typealias DiningExpenseEditSaveAction = @MainActor (DiningExpenseEditDraft) async throws -> Void

/// 首页快速编辑提交期间的页面状态。
enum DiningExpenseEditSubmissionState: Equatable {
    /// 用户正在修改标题或金额。
    case editing

    /// 正在执行显式保存。
    case saving

    /// 保存失败，保留草稿供用户重试。
    case failed
}

/// 持有一笔餐饮流水的快速编辑草稿并协调防重复提交。
@MainActor
final class DiningExpenseEditFlow: ObservableObject {
    /// 当前快速编辑中的草稿。
    @Published private(set) var draft: DiningExpenseEditDraft

    /// 当前提交流程状态。
    @Published private(set) var submissionState: DiningExpenseEditSubmissionState = .editing

    /// 由上层注入的本地更新动作。
    private let saveAction: DiningExpenseEditSaveAction

    /// 创建一份可测试的快速编辑流程。
    init(
        draft: DiningExpenseEditDraft,
        saveAction: @escaping DiningExpenseEditSaveAction
    ) {
        self.draft = draft
        self.saveAction = saveAction
    }

    /// 当前是否正在保存。
    var isSaving: Bool {
        submissionState == .saving
    }

    /// 最近一次保存是否失败。
    var hasSaveError: Bool {
        submissionState == .failed
    }

    /// 标题和金额均有效且当前没有保存任务时允许提交。
    var canSubmit: Bool {
        draft.hasValidTitle && draft.amount != nil && !isSaving
    }

    /// 接收标题输入，并在修改后清除失败状态。
    func updateTitle(_ title: String) {
        guard !isSaving else { return }
        draft.title = title
        markAsEditing()
    }

    /// 接收系统数字键盘输入，统一小数点格式并限制最多两位小数。
    ///
    /// - Parameters:
    ///   - amountText: 文本框当前尝试写入的金额字符。
    ///   - decimalSeparator: 当前系统区域使用的小数分隔符。
    func updateAmountText(_ amountText: String, decimalSeparator: String) {
        guard !isSaving,
              let normalizedAmountText = AccountAmountParser.normalizedCNYAmountText(
                  amountText,
                  decimalSeparator: decimalSeparator
              )
        else { return }

        draft.amountText = normalizedAmountText
        markAsEditing()
    }

    /// 复制当前草稿并执行一次显式更新；失败时保留编辑内容。
    ///
    /// - Parameter onSaved: 仅在持久化成功后调用的返回动作。
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
