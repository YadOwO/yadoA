import Foundation

/// 余额调整金额的独立正负状态。
enum BalanceAdjustmentSign: Hashable, Sendable {
    /// 非负目标总余额。
    case positive

    /// 负数目标总余额。
    case negative

}

/// 余额调整 Sheet 生命周期内持有的单份目标总余额草稿。
struct BalanceAdjustmentDraft: Equatable, Sendable {
    /// Sheet 打开时生成、失败重试期间保持不变的流水 UUID。
    let id: UUID

    /// 当前调整账户的稳定 UUID。
    let accountID: UUID

    /// 系统数字键盘维护的非负金额字符。
    var amountText: String

    /// 与金额字符分开维护的正负状态。
    var sign: BalanceAdjustmentSign

    /// 允许为空的调整原因原始值。
    var note: String

    /// 创建一份余额调整草稿。
    ///
    /// - Parameters:
    ///   - id: Sheet 生命周期内稳定的流水 UUID。
    ///   - accountID: 当前账户 UUID。
    ///   - amountText: 使用英文句点的非负金额字符。
    ///   - sign: 目标余额的正负状态。
    ///   - note: 允许为空的调整原因。
    init(
        id: UUID = UUID(),
        accountID: UUID,
        amountText: String,
        sign: BalanceAdjustmentSign = .positive,
        note: String = ""
    ) {
        self.id = id
        self.accountID = accountID
        self.amountText = amountText
        self.sign = sign
        self.note = note
    }

    /// 使用当前精确余额预填绝对金额与正负状态。
    ///
    /// - Parameters:
    ///   - id: Sheet 生命周期内稳定的流水 UUID。
    ///   - accountID: 当前账户 UUID。
    ///   - currentBalance: 打开 Sheet 时用于预填的账户余额。
    init(
        id: UUID = UUID(),
        accountID: UUID,
        currentBalance: Decimal
    ) {
        self.init(
            id: id,
            accountID: accountID,
            amountText: NSDecimalNumber(decimal: abs(currentBalance)).stringValue,
            sign: currentBalance < 0 ? .negative : .positive
        )
    }

    /// 已解析的目标总余额；零始终归一为非负零。
    var targetBalance: Decimal? {
        guard let magnitude = AccountAmountParser.cnyAmount(fromNormalized: amountText) else {
            return nil
        }
        guard magnitude != 0 else { return .zero }
        return sign == .negative ? -magnitude : magnitude
    }
}
