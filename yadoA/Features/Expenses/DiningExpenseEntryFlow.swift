import Combine
import Foundation

/// 记账页面注入的显式保存动作。
typealias DiningExpenseSaveAction = @MainActor (DiningExpenseDraft) async throws -> Void

/// 记账提交期间的页面状态。
enum DiningExpenseSubmissionState: Equatable {
    case editing
    case saving
    case failed
}

/// 持有单份记账草稿，并协调收支方向、分类、金额输入与防重复提交。
@MainActor
final class DiningExpenseEntryFlow: ObservableObject {
    /// 页面及其后续账户子流程共享的同一份草稿。
    @Published private(set) var draft: DiningExpenseDraft

    /// 当前提交状态；失败时保留草稿供用户继续修改或重试。
    @Published private(set) var submissionState: DiningExpenseSubmissionState = .editing

    /// 记账日期使用的公历，仅在界面边界转换年月日。
    private let calendar: Calendar

    /// 由上层注入的本地持久化动作。
    private let saveAction: DiningExpenseSaveAction

    /// 防止 SwiftUI 查询刷新或页面重新出现时重复覆盖用户选择。
    private var hasInitializedDefault = false

    /// 区分新草稿的占位分类与用户已经明确确认的分类。
    private var hasConfirmedCategory: Bool

    /// 创建一条带稳定 UUID 的支出流程。
    ///
    /// - Parameters:
    ///   - draft: 需要恢复的既有草稿；为空时以今天创建新草稿。
    ///   - now: 新草稿的默认记账日期。
    ///   - calendar: 提供当前时区的日历，内部统一转换为公历。
    ///   - saveAction: 显式保存支出流水与账户金额的动作。
    init(
        draft: DiningExpenseDraft? = nil,
        initialAccountID: UUID? = nil,
        now: Date = .now,
        calendar: Calendar = .current,
        saveAction: @escaping DiningExpenseSaveAction
    ) {
        let gregorianCalendar = TransactionDay.gregorianCalendar(basedOn: calendar)
        self.calendar = gregorianCalendar
        self.saveAction = saveAction
        if let draft {
            self.draft = draft
            self.hasConfirmedCategory = true
        } else {
            self.draft = DiningExpenseDraft(
                accountID: initialAccountID,
                transactionDay: TransactionDay.encode(now, calendar: gregorianCalendar)
            )
            self.hasConfirmedCategory = false
        }
        self.hasInitializedDefault = self.draft.accountID != nil
    }

    /// 当前是否正在保存，用于忽略重复完成操作。
    var isSaving: Bool {
        submissionState == .saving
    }

    /// 最近一次保存是否失败。
    var hasSaveError: Bool {
        submissionState == .failed
    }

    /// 供界面展示的已确认分类；新草稿在用户选择前返回 `nil`。
    var selectedCategory: ExpenseCategory? {
        hasConfirmedCategory && draft.entryType == .expense ? draft.category : nil
    }

    /// 供界面展示的已确认收入分类；其他状态返回 `nil`。
    var selectedIncomeCategory: IncomeCategory? {
        hasConfirmedCategory && draft.entryType == .income ? draft.incomeCategory : nil
    }

    /// 草稿是否已经具备明确分类、有效金额和账户选择。
    var canSubmit: Bool {
        hasConfirmedCategory && draft.amount != nil && draft.accountID != nil && !isSaving
    }

    /// 金额区域展示的字符；空草稿使用零作为视觉占位。
    var displayedAmount: String {
        draft.amountText.isEmpty ? "0" : draft.amountText
    }

    /// 当前 `YYYYMMDD` 草稿值对应的公历日期。
    var transactionDate: Date {
        TransactionDay.date(from: draft.transactionDay, calendar: calendar)
            ?? calendar.startOfDay(for: .now)
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

    /// 更新可选备注，并在编辑后清除上一次失败提示。
    func updateNote(_ note: String) {
        guard !isSaving else { return }
        draft.note = note
        markAsEditing()
    }

    /// 更新记账日期，仅把公历年月日写回草稿。
    func updateTransactionDate(_ date: Date) {
        guard !isSaving else { return }
        draft.transactionDay = TransactionDay.encode(date, calendar: calendar)
        markAsEditing()
    }

    /// 更新支出分类，并在编辑后清除上一次失败提示。
    func selectCategory(_ category: ExpenseCategory) {
        guard !isSaving else { return }
        hasConfirmedCategory = true
        draft.category = category
        markAsEditing()
    }

    /// 切换收支方向；新方向必须重新确认分类，避免把占位值当成用户选择。
    func selectEntryType(_ entryType: BookkeepingEntryType) {
        guard !isSaving, draft.entryType != entryType else { return }
        draft.entryType = entryType
        hasConfirmedCategory = false
        markAsEditing()
    }

    /// 更新收入分类，并在编辑后清除上一次失败提示。
    func selectIncomeCategory(_ category: IncomeCategory) {
        guard !isSaving else { return }
        hasConfirmedCategory = true
        draft.incomeCategory = category
        markAsEditing()
    }

    /// 回填唯一账户 UUID，不重建金额、日期或备注等其他草稿字段。
    func selectAccount(id: UUID?) {
        guard !isSaving else { return }
        hasInitializedDefault = true
        draft.accountID = id
        markAsEditing()
    }

    /// 只为尚未初始化且没有显式选择的新草稿注入一次默认账户。
    func applyInitialDefault(_ accountID: UUID?) {
        guard !hasInitializedDefault, draft.accountID == nil else { return }
        hasInitializedDefault = true
        draft.accountID = accountID
    }

    /// 复制当前草稿并执行一次显式保存；失败时原草稿保持不变。
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
