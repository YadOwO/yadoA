import Foundation

/// 一笔收支流水的完整字段快照，与持久化模型脱离，可以跨 context 传递。
///
/// 语音记账用它描述要写入的新流水，也用它在修改、删除前保存原样，供撤销时按原 UUID、
/// 保存时间和备注原样还原。只表达收入和支出，余额调整不使用它。
struct BookkeepingEntrySnapshot: Equatable, Sendable {
    /// 流水的稳定 UUID。
    let id: UUID

    /// 绑定账户的稳定 UUID。
    var accountID: UUID

    /// 收支方向。
    var entryType: BookkeepingEntryType

    /// 当前方向下的分类 key（预置 rawValue 或 `custom.<uuid>`）。
    var categoryKey: String

    /// 大于零、最多两位小数的 CNY 金额。
    var amount: Decimal

    /// `YYYYMMDD` 公历记账日。
    var transactionDay: Int

    /// 可选备注；为 `nil` 时展示层回退到分类名称。
    var note: String?

    /// 首次保存时间，用于同日排序；还原时保持不变，流水回到原来的位置。
    var savedAt: Date

    /// 成员逐一初始化。
    init(
        id: UUID,
        accountID: UUID,
        entryType: BookkeepingEntryType,
        categoryKey: String,
        amount: Decimal,
        transactionDay: Int,
        note: String? = nil,
        savedAt: Date
    ) {
        self.id = id
        self.accountID = accountID
        self.entryType = entryType
        self.categoryKey = categoryKey
        self.amount = amount
        self.transactionDay = transactionDay
        self.note = note
        self.savedAt = savedAt
    }

    /// 从合法的收入或支出流水生成快照；余额调整、非 CNY 或损坏数据返回 `nil`。
    ///
    /// - Parameter transaction: 需要拷贝的流水。
    init?(transaction: AccountTransaction) {
        guard transaction.currencyCode == "CNY",
              let payload = try? transaction.validatedPayload(),
              let entry = payload.bookkeepingAmount,
              let reference = payload.categoryReference
        else { return nil }
        self.init(
            id: transaction.id,
            accountID: transaction.accountID,
            entryType: entry.entryType,
            categoryKey: reference.key,
            amount: entry.amount,
            transactionDay: transaction.transactionDay,
            note: transaction.note,
            savedAt: transaction.savedAt
        )
    }

    /// 复用收支校验工厂生成尚未插入 context 的流水。
    ///
    /// - Returns: 已校验金额、日期、分类 key 格式并清理备注的流水。
    /// - Throws: 字段不符合持久化约束时抛出 `AccountTransactionValidationError`。
    func validatedTransaction() throws -> AccountTransaction {
        switch entryType {
        case .expense:
            try AccountTransaction.validatingExpense(
                id: id, accountID: accountID, categoryKey: categoryKey, amount: amount,
                transactionDay: transactionDay, note: note ?? "", savedAt: savedAt
            )
        case .income:
            try AccountTransaction.validatingIncome(
                id: id, accountID: accountID, categoryKey: categoryKey, amount: amount,
                transactionDay: transactionDay, note: note ?? "", savedAt: savedAt
            )
        }
    }
}

/// 在一次保存内执行的一条收支变更。
enum BookkeepingEntryMutation: Equatable, Sendable {
    /// 按快照新增一笔流水，并把金额计入账户余额。
    case insert(BookkeepingEntrySnapshot)

    /// 用快照的字段替换同 UUID 的已有流水（保存时间保持原值），并修正新旧账户余额。
    case replace(BookkeepingEntrySnapshot)

    /// 删除一笔流水，并撤销它对账户余额的影响。
    case delete(UUID)
}
