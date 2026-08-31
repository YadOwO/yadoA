import Foundation
import SwiftData

/// 账户流水无法转换为持久化模型时的领域校验错误。
enum AccountTransactionValidationError: Error, Equatable {
    /// 持久化类型不在当前版本支持的账户流水集合内。
    case unknownType(String)

    /// 类型与支出、余额快照等专属字段组合不匹配。
    case invalidPayload

    /// 支出金额必须大于零，且最多精确到 CNY 的两位小数。
    case invalidAmount

    /// 余额调整的前后值、差额或 CNY 精度不自洽。
    case invalidBalanceAdjustment

    /// 余额调整的精确十进制差额计算失败。
    case balanceCalculationFailed

    /// 记账日必须是有效的 `YYYYMMDD` 公历日期。
    case invalidTransactionDay
}

/// 账户范围内持久化流水的稳定类型。
enum AccountTransactionType: String, Sendable {
    /// 支出流水；沿用首版餐饮流水的持久化值以兼容已有本地数据。
    case expense = "diningExpense"

    /// 直接设置账户总余额产生的调整流水。
    case balanceAdjustment
}

/// 当前版本支持的支出分类。
enum ExpenseCategory: String, CaseIterable, Identifiable, Sendable {
    /// 餐饮支出。
    case dining

    /// 购物支出。
    case shopping

    /// 日常用品支出。
    case dailyNecessities

    /// 公共交通与通勤支出。
    case transportation

    /// 游戏、影音等娱乐支出。
    case entertainment

    /// 电话、网络等通讯支出。
    case communication

    /// 服装鞋帽支出。
    case clothing

    /// 房租、房贷等住房支出。
    case housing

    /// 家具、家电等居家支出。
    case household

    /// 医疗与健康服务支出。
    case medical

    /// 学习与教育支出。
    case education

    /// 宠物相关支出。
    case pets

    /// 出行与旅行支出。
    case travel

    /// 汽车相关支出。
    case automotive

    /// 人情往来与礼物支出。
    case socialGifts

    /// 无法归入其他分类的支出。
    case other

    /// SwiftUI 列表使用稳定持久化值作为标识。
    var id: String { rawValue }
}

/// 从 SwiftData 可选字段中严格解码出的账户流水业务载荷。
enum AccountTransactionPayload: Equatable, Sendable {
    /// 带明确分类的支出金额。
    case expense(category: ExpenseCategory, amount: Decimal)

    /// 余额调整的完整前值、后值与带符号差额。
    case balanceAdjustment(before: Decimal, after: Decimal, delta: Decimal)
}

/// SwiftData 中持久化的类型化账户流水。
@Model
final class AccountTransaction {
    /// 跨启动保持稳定的流水标识。
    @Attribute(.unique) var id: UUID

    /// 流水绑定账户的稳定 UUID。
    var accountID: UUID

    /// `AccountTransactionType.rawValue` 的持久化值。
    var typeRawValue: String

    /// 支出使用的 `ExpenseCategory.rawValue`；其他类型必须为 `nil`。
    var categoryRawValue: String?

    /// 支出以正数保存的精确金额；其他类型必须为 `nil`。
    var amount: Decimal?

    /// 用户可选的流水标题；旧数据为空时由展示层回退到分类标题。
    var title: String?

    /// 余额调整保存时从账户重新读取的调整前余额。
    var balanceBefore: Decimal?

    /// 余额调整后直接设置的目标总余额。
    var balanceAfter: Decimal?

    /// `balanceAfter - balanceBefore` 的带符号差额。
    var balanceDelta: Decimal?

    /// 金额使用的 ISO 4217 货币代码；当前固定为 `CNY`。
    var currencyCode: String

    /// 用户业务日，使用 `YYYYMMDD` 整数保存。
    var transactionDay: Int

    /// 去除首尾空白后的可选备注。
    var note: String?

    /// 流水首次成功保存的时间，用于同一业务日内排序。
    var savedAt: Date

    /// 已知持久化值对应的账户流水类型；未知或损坏值返回 `nil`。
    var transactionType: AccountTransactionType? {
        AccountTransactionType(rawValue: typeRawValue)
    }

    /// 已知支出分类；非支出类型、未知或损坏值返回 `nil`。
    var category: ExpenseCategory? {
        guard transactionType == .expense, let categoryRawValue else { return nil }
        return ExpenseCategory(rawValue: categoryRawValue)
    }

    /// 严格校验并解码当前持久化字段，避免各消费层重复解释可选字段矩阵。
    func validatedPayload() throws -> AccountTransactionPayload {
        try Self.validatedPayload(
            typeRawValue: typeRawValue,
            categoryRawValue: categoryRawValue,
            amount: amount,
            title: title.flatMap { Self.sanitizedOptionalText($0) },
            balanceBefore: balanceBefore,
            balanceAfter: balanceAfter,
            balanceDelta: balanceDelta
        )
    }

    /// 直接构造已完成类型字段矩阵校验的持久化流水。
    private init(
        id: UUID,
        accountID: UUID,
        typeRawValue: String,
        categoryRawValue: String?,
        amount: Decimal?,
        title: String?,
        balanceBefore: Decimal?,
        balanceAfter: Decimal?,
        balanceDelta: Decimal?,
        currencyCode: String,
        transactionDay: Int,
        note: String?,
        savedAt: Date
    ) {
        self.id = id
        self.accountID = accountID
        self.typeRawValue = typeRawValue
        self.categoryRawValue = categoryRawValue
        self.amount = amount
        self.title = title
        self.balanceBefore = balanceBefore
        self.balanceAfter = balanceAfter
        self.balanceDelta = balanceDelta
        self.currencyCode = currencyCode
        self.transactionDay = transactionDay
        self.note = note
        self.savedAt = savedAt
    }

    /// 校验并清理支出字段，生成尚未插入 context 的账户流水。
    ///
    /// - Parameters:
    ///   - id: 页面草稿生命周期内保持稳定的流水 UUID。
    ///   - accountID: 流水绑定账户的稳定 UUID。
    ///   - category: 用户选择的支出分类。
    ///   - amount: 大于零且最多两位小数的 CNY 支出金额。
    ///   - transactionDay: 用户选择的 `YYYYMMDD` 公历记账日。
    ///   - title: 用户可选的流水标题。
    ///   - note: 允许为空的备注原始值。
    ///   - savedAt: 注入的保存时间，便于同日排序与确定性测试。
    /// - Returns: 已完成支出专属字段校验和清理的账户流水。
    /// - Throws: 金额、记账日或字段组合不符合持久化约束时抛出校验错误。
    static func validatingExpense(
        id: UUID,
        accountID: UUID,
        category: ExpenseCategory,
        amount: Decimal,
        transactionDay: Int,
        title: String? = nil,
        note: String = "",
        savedAt: Date = .now
    ) throws -> AccountTransaction {
        try validatingPersistedFields(
            id: id,
            accountID: accountID,
            typeRawValue: AccountTransactionType.expense.rawValue,
            categoryRawValue: category.rawValue,
            amount: amount,
            balanceBefore: nil,
            balanceAfter: nil,
            balanceDelta: nil,
            transactionDay: transactionDay,
            note: note,
            savedAt: savedAt,
            title: title
        )
    }

    /// 使用餐饮默认分类创建支出，兼容首版调用与测试夹具。
    static func validatingDiningExpense(
        id: UUID,
        accountID: UUID,
        amount: Decimal,
        transactionDay: Int,
        title: String? = nil,
        note: String = "",
        savedAt: Date = .now
    ) throws -> AccountTransaction {
        try validatingExpense(
            id: id,
            accountID: accountID,
            category: .dining,
            amount: amount,
            transactionDay: transactionDay,
            title: title,
            note: note,
            savedAt: savedAt
        )
    }

    /// 根据调整前后余额派生差额，生成尚未插入 context 的调整流水。
    ///
    /// - Parameters:
    ///   - id: 调整 Sheet 生命周期内保持稳定的流水 UUID。
    ///   - accountID: 流水绑定账户的稳定 UUID。
    ///   - balanceBefore: 保存边界从账户重新读取的当前余额。
    ///   - balanceAfter: 用户直接设置的目标总余额。
    ///   - transactionDay: 保存当天的 `YYYYMMDD` 公历业务日。
    ///   - note: 允许为空的调整原因原始值。
    ///   - savedAt: 注入的保存时间，便于同日排序与确定性测试。
    /// - Returns: 已自动计算并校验带符号差额的余额调整流水。
    /// - Throws: 快照精度、差额或记账日不符合持久化约束时抛出校验错误。
    static func validatingBalanceAdjustment(
        id: UUID,
        accountID: UUID,
        balanceBefore: Decimal,
        balanceAfter: Decimal,
        transactionDay: Int,
        note: String = "",
        savedAt: Date = .now
    ) throws -> AccountTransaction {
        let balanceDelta = try calculatedBalanceDelta(
            balanceBefore: balanceBefore,
            balanceAfter: balanceAfter
        )
        return try validatingPersistedFields(
            id: id,
            accountID: accountID,
            typeRawValue: AccountTransactionType.balanceAdjustment.rawValue,
            categoryRawValue: nil,
            amount: nil,
            balanceBefore: balanceBefore,
            balanceAfter: balanceAfter,
            balanceDelta: balanceDelta,
            transactionDay: transactionDay,
            note: note,
            savedAt: savedAt
        )
    }

    /// 验证持久化字段是否严格符合指定流水类型的专属字段矩阵。
    ///
    /// 正常业务写入应使用类型专属工厂；该边界用于让 schema 转换与模型测试
    /// 确认未知类型、字段混用和不自洽快照无法进入持久层。
    static func validatingPersistedFields(
        id: UUID,
        accountID: UUID,
        typeRawValue: String,
        categoryRawValue: String?,
        amount: Decimal?,
        balanceBefore: Decimal?,
        balanceAfter: Decimal?,
        balanceDelta: Decimal?,
        transactionDay: Int,
        note: String = "",
        savedAt: Date = .now,
        title: String? = nil
    ) throws -> AccountTransaction {
        guard TransactionDay.isValid(transactionDay) else {
            throw AccountTransactionValidationError.invalidTransactionDay
        }
        let sanitizedTitle = title.flatMap { sanitizedOptionalText($0) }
        _ = try validatedPayload(
            typeRawValue: typeRawValue,
            categoryRawValue: categoryRawValue,
            amount: amount,
            title: sanitizedTitle,
            balanceBefore: balanceBefore,
            balanceAfter: balanceAfter,
            balanceDelta: balanceDelta
        )

        return AccountTransaction(
            id: id,
            accountID: accountID,
            typeRawValue: typeRawValue,
            categoryRawValue: categoryRawValue,
            amount: amount,
            title: sanitizedTitle,
            balanceBefore: balanceBefore,
            balanceAfter: balanceAfter,
            balanceDelta: balanceDelta,
            currencyCode: "CNY",
            transactionDay: transactionDay,
            note: sanitizedOptionalText(note),
            savedAt: savedAt
        )
    }

    /// 校验类型专属字段矩阵并返回不可混用的业务载荷。
    private static func validatedPayload(
        typeRawValue: String,
        categoryRawValue: String?,
        amount: Decimal?,
        title: String?,
        balanceBefore: Decimal?,
        balanceAfter: Decimal?,
        balanceDelta: Decimal?
    ) throws -> AccountTransactionPayload {
        guard let transactionType = AccountTransactionType(rawValue: typeRawValue) else {
            throw AccountTransactionValidationError.unknownType(typeRawValue)
        }

        switch transactionType {
        case .expense:
            guard let categoryRawValue,
                  let category = ExpenseCategory(rawValue: categoryRawValue),
                  let amount,
                  balanceBefore == nil,
                  balanceAfter == nil,
                  balanceDelta == nil
            else {
                throw AccountTransactionValidationError.invalidPayload
            }
            guard amount > 0, AccountAmountParser.hasCNYPrecision(amount) else {
                throw AccountTransactionValidationError.invalidAmount
            }
            return .expense(category: category, amount: amount)

        case .balanceAdjustment:
            guard categoryRawValue == nil,
                  amount == nil,
                  title == nil,
                  let balanceBefore,
                  let balanceAfter,
                  let balanceDelta
            else {
                throw AccountTransactionValidationError.invalidPayload
            }
            guard AccountAmountParser.hasCNYPrecision(balanceBefore),
                  AccountAmountParser.hasCNYPrecision(balanceAfter),
                  AccountAmountParser.hasCNYPrecision(balanceDelta),
                  balanceDelta != 0
            else {
                throw AccountTransactionValidationError.invalidBalanceAdjustment
            }
            let expectedDelta = try calculatedBalanceDelta(
                balanceBefore: balanceBefore,
                balanceAfter: balanceAfter
            )
            guard expectedDelta == balanceDelta else {
                throw AccountTransactionValidationError.invalidBalanceAdjustment
            }
            return .balanceAdjustment(
                before: balanceBefore,
                after: balanceAfter,
                delta: balanceDelta
            )
        }
    }

    /// 使用精确十进制减法派生带符号的余额变化。
    private static func calculatedBalanceDelta(
        balanceBefore: Decimal,
        balanceAfter: Decimal
    ) throws -> Decimal {
        var before = balanceBefore
        var after = balanceAfter
        var result = Decimal()
        let calculationError = NSDecimalSubtract(&result, &after, &before, .plain)
        guard calculationError == .noError else {
            throw AccountTransactionValidationError.balanceCalculationFailed
        }
        return result
    }

    /// 将空白备注归一为 `nil`，其余内容去除首尾空白。
    private static func sanitizedOptionalText(_ value: String) -> String? {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
