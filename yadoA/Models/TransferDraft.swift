import Foundation

/// 转账表单生命周期内持有的单份草稿。
struct TransferDraft: Identifiable, Equatable, Sendable {
    /// 表单打开时生成、失败重试期间保持不变的流水 UUID。
    let id: UUID

    /// 转出账户；流水挂在这个账户上。
    var fromAccountID: UUID?

    /// 转入账户。
    var toAccountID: UUID?

    /// 系统数字键盘维护的非负金额字符，小数点统一为英文句点。
    var amountText: String

    /// 用户选择的 `YYYYMMDD` 公历记账日。
    var transactionDay: Int

    /// 允许为空的备注原始值。
    var note: String

    /// 创建一份转账草稿。
    ///
    /// - Parameters:
    ///   - id: 表单生命周期内稳定的流水 UUID。
    ///   - fromAccountID: 预选的转出账户。
    ///   - toAccountID: 预选的转入账户。
    ///   - amountText: 使用英文句点的非负金额字符。
    ///   - transactionDay: 记账日。
    ///   - note: 允许为空的备注。
    init(
        id: UUID = UUID(),
        fromAccountID: UUID? = nil,
        toAccountID: UUID? = nil,
        amountText: String = "",
        transactionDay: Int,
        note: String = ""
    ) {
        self.id = id
        self.fromAccountID = fromAccountID
        self.toAccountID = toAccountID
        self.amountText = amountText
        self.transactionDay = transactionDay
        self.note = note
    }

    /// 已解析的正数转账金额；为空、为零或超过两位小数时返回 `nil`。
    var amount: Decimal? {
        guard let amount = AccountAmountParser.cnyAmount(fromNormalized: amountText), amount > 0 else {
            return nil
        }
        return amount
    }

    /// 两个账户都已选择且不是同一个。
    var hasValidAccounts: Bool {
        guard let fromAccountID, let toAccountID else { return false }
        return fromAccountID != toAccountID
    }

    /// 草稿是否可以提交。
    var isComplete: Bool {
        amount != nil && hasValidAccounts && TransactionDay.isValid(transactionDay)
    }

    /// 交换转出和转入账户。
    mutating func swapAccounts() {
        swap(&fromAccountID, &toAccountID)
    }
}
