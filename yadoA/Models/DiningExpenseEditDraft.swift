import Combine
import Foundation

/// 收支流水编辑草稿的校验错误。
enum DiningExpenseEditDraftValidationError: Error, Equatable {
    /// 完整编辑必须保留非空标题。
    case titleRequired
}

/// 完整编辑一笔收支流水的值类型草稿，不直接修改查询中的持久化模型。
struct DiningExpenseEditDraft: Equatable, Sendable, Identifiable {
    /// 需要更新的流水 UUID。
    let id: UUID

    /// 修改后绑定的账户，单次选择不改变全局默认记账账户。
    var accountID: UUID

    /// 修改后的收支方向。
    var entryType: BookkeepingEntryType

    /// 支出方向下使用的分类 key。
    var expenseCategoryKey: String

    /// 收入方向下使用的分类 key。
    var incomeCategoryKey: String

    /// 用户可编辑的流水标题。
    var title: String

    /// 系统数字键盘维护的金额字符缓冲区。
    var amountText: String

    /// 公历业务日；修改日期只影响归属与展示，不重放历史余额。
    var transactionDay: Int

    /// 可选备注；空白内容在保存时归一为 nil。
    var note: String

    /// 创建一份收支流水完整编辑草稿。
    ///
    /// - Parameters:
    ///   - id: 需要更新的流水 UUID。
    ///   - accountID: 修改后绑定的启用账户。
    ///   - entryType: 修改后的收入或支出方向。
    ///   - expenseCategoryKey: 支出分类 key。
    ///   - incomeCategoryKey: 收入分类 key。
    ///   - title: 当前展示标题；旧数据回退到分类默认标题。
    ///   - amountText: 使用英文句点的小数金额字符。
    ///   - transactionDay: 有效的公历业务日。
    ///   - note: 允许为空的备注。
    init(
        id: UUID,
        accountID: UUID,
        entryType: BookkeepingEntryType = .expense,
        expenseCategoryKey: String = ExpenseCategory.dining.rawValue,
        incomeCategoryKey: String = IncomeCategory.salary.rawValue,
        title: String,
        amountText: String,
        transactionDay: Int,
        note: String = ""
    ) {
        self.id = id
        self.accountID = accountID
        self.entryType = entryType
        self.expenseCategoryKey = expenseCategoryKey
        self.incomeCategoryKey = incomeCategoryKey
        self.title = title
        self.amountText = amountText
        self.transactionDay = transactionDay
        self.note = note
    }

    /// 从合法收入或支出初始化完整草稿；余额调整与损坏数据不进入编辑流程。
    ///
    /// - Parameters:
    ///   - transaction: 需要编辑的流水。
    ///   - locale: 旧数据没有标题时回退分类名称使用的语言环境。
    ///   - catalog: 解析分类名称和另一方向默认分类使用的分类目录。
    init?(
        transaction: AccountTransaction,
        locale: Locale = .current,
        catalog: BookkeepingCategoryCatalog = .presets
    ) {
        guard transaction.currencyCode == "CNY",
              TransactionDay.isValid(transaction.transactionDay),
              let payload = try? transaction.validatedPayload(),
              let entry = payload.bookkeepingAmount,
              let reference = payload.categoryReference
        else { return nil }
        // 另一方向使用目录的默认分类，用户在编辑时切换方向也能立即得到可选分类。
        var expenseCategoryKey = catalog.defaultKey(for: .expense)
        var incomeCategoryKey = catalog.defaultKey(for: .income)
        switch reference.direction {
        case .expense: expenseCategoryKey = reference.key
        case .income: incomeCategoryKey = reference.key
        }
        let categoryTitle = catalog
            .resolvedItem(direction: reference.direction, key: reference.key)
            .title(locale: locale)
        var value = entry.amount
        self.init(
            id: transaction.id,
            accountID: transaction.accountID,
            entryType: entry.entryType,
            expenseCategoryKey: expenseCategoryKey,
            incomeCategoryKey: incomeCategoryKey,
            title: transaction.title ?? categoryTitle,
            amountText: NSDecimalString(&value, Locale(identifier: "en_US_POSIX")),
            transactionDay: transaction.transactionDay,
            note: transaction.note ?? ""
        )
    }

    /// 复用新增收支的校验工厂，生成用于替换现有字段的已校验值。
    func validatedTransaction(savedAt: Date) throws -> AccountTransaction {
        guard hasValidTitle else { throw DiningExpenseEditDraftValidationError.titleRequired }
        let transaction = try AccountTransaction.validating(
            draft: DiningExpenseDraft(
                id: id, accountID: accountID, entryType: entryType,
                expenseCategoryKey: expenseCategoryKey, incomeCategoryKey: incomeCategoryKey,
                amountText: amountText, transactionDay: transactionDay, note: note
            ),
            savedAt: savedAt
        )
        transaction.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return transaction
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

/// 完整编辑页使用的提交流程。
typealias DiningExpenseEditSaveAction = @MainActor (DiningExpenseEditDraft) async throws -> Void

/// 收支完整编辑提交期间的页面状态。
enum DiningExpenseEditSubmissionState: Equatable {
    /// 用户正在修改流水字段。
    case editing

    /// 正在执行显式保存。
    case saving

    /// 保存失败，保留草稿供用户重试。
    case failed
}

/// 持有一笔收支流水的完整编辑草稿并协调防重复提交。
@MainActor
final class DiningExpenseEditFlow: ObservableObject {
    /// 当前完整编辑中的草稿。
    @Published private(set) var draft: DiningExpenseEditDraft

    /// 当前提交流程状态。
    @Published private(set) var submissionState: DiningExpenseEditSubmissionState = .editing

    /// 草稿分类已连同流水一起被删除、需要用户重新选择分类的收支方向。
    @Published private(set) var directionsAwaitingCategory: Set<BookkeepingEntryType> = []

    /// 所编辑的流水本身是否已被删除（例如随原分类一起删除），删除后不能再保存。
    @Published private(set) var isTransactionRemoved = false

    /// 由上层注入的本地更新动作。
    private let saveAction: DiningExpenseEditSaveAction

    /// 创建一份可测试的完整编辑流程。
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

    /// 标题、金额与业务日均有效、当前方向的分类仍然可用、流水仍然存在且没有保存任务时允许提交。
    var canSubmit: Bool {
        draft.hasValidTitle && draft.amount != nil
            && TransactionDay.isValid(draft.transactionDay)
            && !directionsAwaitingCategory.contains(draft.entryType)
            && !isTransactionRemoved && !isSaving
    }

    /// 通过同一入口修改分类、账户、日期等字段；提交期间保持草稿稳定。
    func update(_ mutation: (inout DiningExpenseEditDraft) -> Void) {
        guard !isSaving else { return }
        mutation(&draft)
        markAsEditing()
    }

    /// 选择当前方向下的分类；若该方向的分类刚被删除，重新选择后恢复可提交。
    ///
    /// - Parameter key: 用户在分类面板中点选的分类 key。
    func selectCategory(key: String) {
        guard !isSaving else { return }
        switch draft.entryType {
        case .expense: draft.expenseCategoryKey = key
        case .income: draft.incomeCategoryKey = key
        }
        directionsAwaitingCategory.remove(draft.entryType)
        markAsEditing()
    }

    /// 当前方向的草稿分类在分类管理里连同流水一起删除后，撤销这次选择，要求用户重新选择。
    ///
    /// 草稿里的 key 保持原值，只标记失效，避免把空字符串当成分类写进草稿。
    func clearCategory() {
        guard !isSaving else { return }
        directionsAwaitingCategory.insert(draft.entryType)
        markAsEditing()
    }

    /// 所编辑的流水已不存在时调用，此后草稿不再允许提交。
    func markTransactionRemoved() {
        isTransactionRemoved = true
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
