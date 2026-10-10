import Foundation

/// 记账票据页面对草稿流程的统一要求。
///
/// 新增记账与编辑记账各自保留草稿模型和保存规则，只通过这层契约共用同一套页面。
@MainActor
protocol BookkeepingEntryFormFlow: ObservableObject {
    /// 当前收支方向。
    var formEntryType: BookkeepingEntryType { get }

    /// 支出方向下已确认的分类；尚未选择或当前为收入时返回 `nil`。
    var formExpenseCategory: ExpenseCategory? { get }

    /// 收入方向下已确认的分类；尚未选择或当前为支出时返回 `nil`。
    var formIncomeCategory: IncomeCategory? { get }

    /// 可编辑的流水标题；返回 `nil` 表示这份草稿没有标题字段，页面不展示标题行。
    var formTitle: String? { get }

    /// 使用英文句点的金额字符缓冲区。
    var formAmountText: String { get }

    /// 当前绑定的账户 UUID；未选择时为 `nil`。
    var formAccountID: UUID? { get }

    /// 当前业务日对应的日期，供系统日期选择器使用。
    var formTransactionDate: Date { get }

    /// 备注原始值。
    var formNote: String { get }

    /// 当前是否正在保存。
    var isSaving: Bool { get }

    /// 最近一次保存是否失败。
    var hasSaveError: Bool { get }

    /// 草稿自身是否满足提交条件；账户是否仍然可用由页面另行确认。
    var canSubmit: Bool { get }

    /// 切换收支方向。
    func selectEntryType(_ entryType: BookkeepingEntryType)

    /// 选择支出分类。
    func selectCategory(_ category: ExpenseCategory)

    /// 选择收入分类。
    func selectIncomeCategory(_ category: IncomeCategory)

    /// 修改标题；没有标题字段的草稿忽略这次输入。
    func updateTitle(_ title: String)

    /// 接收金额输入，统一小数点格式并限制最多两位小数。
    func updateAmountText(_ amountText: String, decimalSeparator: String)

    /// 回填用户选中的账户。
    func selectFormAccount(id: UUID)

    /// 修改记账日期。
    func updateTransactionDate(_ date: Date)

    /// 修改备注。
    func updateNote(_ note: String)

    /// 执行一次显式保存，仅在持久化成功后调用 `onSaved`。
    func submit(onSaved: @escaping @MainActor () -> Void) async
}

/// 新增记账流程：分类需要用户明确确认，草稿没有标题字段。
extension DiningExpenseEntryFlow: BookkeepingEntryFormFlow {
    var formEntryType: BookkeepingEntryType { draft.entryType }

    var formExpenseCategory: ExpenseCategory? { selectedCategory }

    var formIncomeCategory: IncomeCategory? { selectedIncomeCategory }

    var formTitle: String? { nil }

    var formAmountText: String { draft.amountText }

    var formAccountID: UUID? { draft.accountID }

    var formTransactionDate: Date { transactionDate }

    var formNote: String { draft.note }

    func updateTitle(_ title: String) {}

    func selectFormAccount(id: UUID) {
        selectAccount(id: id)
    }
}

/// 编辑记账流程：两个方向的分类都保留在草稿里，切换方向后无需重新确认。
extension DiningExpenseEditFlow: BookkeepingEntryFormFlow {
    var formEntryType: BookkeepingEntryType { draft.entryType }

    var formExpenseCategory: ExpenseCategory? {
        draft.entryType == .expense ? draft.category : nil
    }

    var formIncomeCategory: IncomeCategory? {
        draft.entryType == .income ? draft.incomeCategory : nil
    }

    var formTitle: String? { draft.title }

    var formAmountText: String { draft.amountText }

    var formAccountID: UUID? { draft.accountID }

    var formTransactionDate: Date {
        TransactionDay.date(from: draft.transactionDay, calendar: .current) ?? .now
    }

    var formNote: String { draft.note }

    func selectEntryType(_ entryType: BookkeepingEntryType) {
        update { $0.entryType = entryType }
    }

    func selectCategory(_ category: ExpenseCategory) {
        update { $0.category = category }
    }

    func selectIncomeCategory(_ category: IncomeCategory) {
        update { $0.incomeCategory = category }
    }

    func selectFormAccount(id: UUID) {
        update { $0.accountID = id }
    }

    func updateTransactionDate(_ date: Date) {
        update { $0.transactionDay = TransactionDay.encode(date, calendar: .current) }
    }

    func updateNote(_ note: String) {
        update { $0.note = note }
    }
}
