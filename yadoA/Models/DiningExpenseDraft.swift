import Foundation

/// 餐饮支出草稿无法转换为待保存流水时的校验错误。
enum DiningExpenseDraftValidationError: Error, Equatable {
    /// 当前草稿尚未选择绑定账户。
    case accountRequired
}

/// 记账页面生命周期内持有的单份餐饮支出草稿。
struct DiningExpenseDraft: Equatable, Sendable {
    /// 页面打开时生成且在失败重试期间保持不变的流水 UUID。
    let id: UUID

    /// 当前选择的账户 UUID；未选择时为 `nil`。
    var accountID: UUID?

    /// 系统数字键盘维护的金额字符缓冲区。
    var amountText: String

    /// 用户选择的公历记账日，使用 `YYYYMMDD` 整数表达。
    var transactionDay: Int

    /// 允许为空的备注原始值。
    var note: String

    /// 创建餐饮支出草稿。
    ///
    /// - Parameters:
    ///   - id: 页面生命周期内稳定的流水 UUID。
    ///   - accountID: 可选的绑定账户 UUID。
    ///   - amountText: 系统数字键盘生成的金额字符。
    ///   - transactionDay: `YYYYMMDD` 公历记账日。
    ///   - note: 允许为空的备注。
    init(
        id: UUID = UUID(),
        accountID: UUID? = nil,
        amountText: String = "",
        transactionDay: Int,
        note: String = ""
    ) {
        self.id = id
        self.accountID = accountID
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
    /// 校验记账草稿并生成尚未插入 context 的餐饮支出流水。
    ///
    /// - Parameters:
    ///   - draft: 页面提交时复制的餐饮支出草稿。
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

        return try validatingDiningExpense(
            id: draft.id,
            accountID: accountID,
            amount: amount,
            transactionDay: draft.transactionDay,
            note: draft.note,
            savedAt: savedAt
        )
    }
}
