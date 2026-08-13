import Foundation
import SwiftData

/// 餐饮支出流水无法转换为持久化模型时的领域校验错误。
enum ExpenseTransactionValidationError: Error, Equatable {
    /// 支出金额必须大于零，且最多精确到 CNY 的两位小数。
    case invalidAmount

    /// 记账日必须是有效的 `YYYYMMDD` 公历日期。
    case invalidTransactionDay
}

/// 当前版本支持的支出分类。
enum ExpenseCategory: String, Sendable {
    /// 固定餐饮支出分类。
    case dining
}

/// SwiftData 中持久化的账户支出流水。
@Model
final class ExpenseTransaction {
    /// 跨启动保持稳定的流水标识。
    @Attribute(.unique) var id: UUID

    /// 流水绑定账户的稳定 UUID。
    var accountID: UUID

    /// `ExpenseCategory.rawValue` 的持久化值。
    var categoryRawValue: String

    /// 始终以正数保存的精确支出金额。
    var amount: Decimal

    /// 金额使用的 ISO 4217 货币代码；当前固定为 `CNY`。
    var currencyCode: String

    /// 用户选择的公历记账日，使用 `YYYYMMDD` 整数保存。
    var transactionDay: Int

    /// 去除首尾空白后的可选备注。
    var note: String?

    /// 流水首次成功保存的时间，用于同一记账日内排序。
    var savedAt: Date

    /// 已知持久化分类对应的支出分类；未来或损坏的值返回 `nil`。
    var category: ExpenseCategory? {
        ExpenseCategory(rawValue: categoryRawValue)
    }

    /// 直接构造已完成校验的持久化流水。
    init(
        id: UUID,
        accountID: UUID,
        categoryRawValue: String,
        amount: Decimal,
        currencyCode: String,
        transactionDay: Int,
        note: String?,
        savedAt: Date
    ) {
        self.id = id
        self.accountID = accountID
        self.categoryRawValue = categoryRawValue
        self.amount = amount
        self.currencyCode = currencyCode
        self.transactionDay = transactionDay
        self.note = note
        self.savedAt = savedAt
    }

    /// 校验并清理餐饮支出字段，生成尚未插入 context 的流水。
    ///
    /// - Parameters:
    ///   - id: 页面草稿生命周期内保持稳定的流水 UUID。
    ///   - accountID: 流水绑定账户的稳定 UUID；账户存在性由写入仓库验证。
    ///   - amount: 大于零且最多两位小数的 CNY 支出金额。
    ///   - transactionDay: 用户选择的 `YYYYMMDD` 公历记账日。
    ///   - note: 允许为空的备注原始值。
    ///   - savedAt: 注入的保存时间，便于同日排序与确定性测试。
    /// - Returns: 已完成字段校验和清理的餐饮支出流水。
    /// - Throws: 金额或记账日不符合持久化约束时抛出校验错误。
    static func validating(
        id: UUID,
        accountID: UUID,
        amount: Decimal,
        transactionDay: Int,
        note: String = "",
        savedAt: Date = .now
    ) throws -> ExpenseTransaction {
        guard amount > 0, hasAtMostTwoFractionDigits(amount) else {
            throw ExpenseTransactionValidationError.invalidAmount
        }
        guard isValidTransactionDay(transactionDay) else {
            throw ExpenseTransactionValidationError.invalidTransactionDay
        }

        return ExpenseTransaction(
            id: id,
            accountID: accountID,
            categoryRawValue: ExpenseCategory.dining.rawValue,
            amount: amount,
            currencyCode: "CNY",
            transactionDay: transactionDay,
            note: sanitizedOptionalText(note),
            savedAt: savedAt
        )
    }

    /// 判断金额是否能在 CNY 两位小数精度内无损表示。
    private static func hasAtMostTwoFractionDigits(_ amount: Decimal) -> Bool {
        var source = amount
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, 2, .plain)
        return rounded == amount
    }

    /// 校验 `YYYYMMDD` 整数能否组成真实的公历日期。
    private static func isValidTransactionDay(_ value: Int) -> Bool {
        let year = value / 10_000
        let month = value / 100 % 100
        let day = value % 100
        guard year > 0, month > 0, day > 0 else { return false }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day
        )
        guard let date = calendar.date(from: components) else { return false }
        let normalized = calendar.dateComponents([.year, .month, .day], from: date)
        return normalized.year == year
            && normalized.month == month
            && normalized.day == day
    }

    /// 将空白备注归一为 `nil`，其余内容去除首尾空白。
    private static func sanitizedOptionalText(_ value: String) -> String? {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
