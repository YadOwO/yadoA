import Foundation

/// 记账草稿无法转换为待保存流水时的校验错误。
enum DiningExpenseDraftValidationError: Error, Equatable {
    /// 当前草稿尚未选择绑定账户。
    case accountRequired
}

/// 记账草稿当前选择的收支方向。
enum BookkeepingEntryType: String, CaseIterable, Identifiable, Sendable {
    /// 支出记账。
    case expense

    /// 收入记账。
    case income

    /// SwiftUI 选择器使用稳定值作为标识。
    var id: String { rawValue }
}

/// 记账页面生命周期内持有的单份收支草稿。
struct DiningExpenseDraft: Equatable, Sendable {
    /// 页面打开时生成且在失败重试期间保持不变的流水 UUID。
    let id: UUID

    /// 当前选择的账户 UUID；未选择时为 `nil`。
    var accountID: UUID?

    /// 当前记账方向，新草稿默认支出以兼容现有流程。
    var entryType: BookkeepingEntryType

    /// 用户选择的支出分类，新草稿默认使用餐饮。
    var category: ExpenseCategory

    /// 用户选择的收入分类，新草稿默认工资。
    var incomeCategory: IncomeCategory

    /// 系统数字键盘维护的金额字符缓冲区。
    var amountText: String

    /// 用户选择的公历记账日，使用 `YYYYMMDD` 整数表达。
    var transactionDay: Int

    /// 允许为空的备注原始值。
    var note: String

    /// 创建收支草稿。
    ///
    /// - Parameters:
    ///   - id: 页面生命周期内稳定的流水 UUID。
    ///   - accountID: 可选的绑定账户 UUID。
    ///   - entryType: 收支方向，默认支出。
    ///   - category: 用户选择的支出分类，默认餐饮。
    ///   - incomeCategory: 用户选择的收入分类，默认工资。
    ///   - amountText: 系统数字键盘生成的金额字符。
    ///   - transactionDay: `YYYYMMDD` 公历记账日。
    ///   - note: 允许为空的备注。
    init(
        id: UUID = UUID(),
        accountID: UUID? = nil,
        entryType: BookkeepingEntryType = .expense,
        category: ExpenseCategory = .dining,
        incomeCategory: IncomeCategory = .salary,
        amountText: String = "",
        transactionDay: Int,
        note: String = ""
    ) {
        self.id = id
        self.accountID = accountID
        self.entryType = entryType
        self.category = category
        self.incomeCategory = incomeCategory
        self.amountText = amountText
        self.transactionDay = transactionDay
        self.note = note
    }

    /// 按页面统一后的英文句点格式解析精确金额。
    var amount: Decimal? {
        guard let amount = AccountAmountParser.cnyAmount(fromNormalized: amountText),
              amount > 0
        else { return nil }
        return amount
    }
}

extension AccountTransaction {
    /// 校验记账草稿并生成尚未插入 context 的收支流水。
    ///
    /// - Parameters:
    ///   - draft: 页面提交时复制的记账草稿。
    ///   - savedAt: 注入的真实保存时间。
    /// - Returns: 已校验账户选择、金额、日期和备注的流水。
    /// - Throws: 账户未选择或流水字段无效时抛出对应校验错误。
    static func validating(
        draft: DiningExpenseDraft,
        savedAt: Date = .now
    ) throws -> AccountTransaction {
        guard let accountID = draft.accountID else {
            throw DiningExpenseDraftValidationError.accountRequired
        }
        guard let amount = draft.amount else {
            throw AccountTransactionValidationError.invalidAmount
        }

        switch draft.entryType {
        case .expense:
            return try validatingExpense(
                id: draft.id,
                accountID: accountID,
                category: draft.category,
                amount: amount,
                transactionDay: draft.transactionDay,
                note: draft.note,
                savedAt: savedAt
            )
        case .income:
            return try validatingIncome(
                id: draft.id,
                accountID: accountID,
                category: draft.incomeCategory,
                amount: amount,
                transactionDay: draft.transactionDay,
                note: draft.note,
                savedAt: savedAt
            )
        }
    }
}
