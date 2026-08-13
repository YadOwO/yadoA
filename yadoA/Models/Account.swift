import Foundation
import SwiftData

/// 账户草稿无法转换为持久化模型时的领域校验错误。
enum AccountValidationError: Error, Equatable {
    /// 清理后的账户名称为空。
    case emptyName
    /// 金额为空、为负数，或不符合当前语言环境的十进制格式。
    case invalidAmount
    /// 所选模板缺失、与账户类型不匹配或不是当前支持的稳定模板。
    case invalidTemplate
}

/// SwiftData 本地财务 schema 中的账户实体。
@Model
final class Account {
    /// 跨启动、列表和详情导航保持稳定的账户标识。
    @Attribute(.unique) var id: UUID

    /// `AccountType.rawValue` 的持久化值；未知值由展示层安全降级。
    var typeRawValue: String

    /// 静态账户模板的稳定标识；直接创建的账户没有模板。
    var templateID: String?

    /// 去除首尾空白后的账户展示名称。
    var name: String

    /// 去除首尾空白后的可选备注。
    var note: String?

    /// 最多四位数字组成的可选卡号后缀。
    var lastFourDigits: String?

    /// 账户创建时为非负精确十进制数；支出或手动调整后允许为负。
    var balance: Decimal

    /// 决定金额格式的 ISO 4217 货币代码；当前仅支持 `CNY`。
    var currencyCode: String

    /// 账户首次成功保存的时间。
    var createdAt: Date

    /// 账户资料最近一次成功更新的时间；余额流水活动不会修改该字段。
    var updatedAt: Date

    /// 已知持久化类型对应的账户类型；未来或损坏的值返回 `nil`。
    var accountType: AccountType? {
        AccountType(rawValue: typeRawValue)
    }

    /// 直接构造已完成校验的持久化账户。
    init(
        id: UUID,
        typeRawValue: String,
        templateID: String?,
        name: String,
        note: String?,
        lastFourDigits: String?,
        balance: Decimal,
        currencyCode: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.typeRawValue = typeRawValue
        self.templateID = templateID
        self.name = name
        self.note = note
        self.lastFourDigits = lastFourDigits
        self.balance = balance
        self.currencyCode = currencyCode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 校验并清理表单草稿，生成尚未插入 context 的账户。
    ///
    /// - Parameters:
    ///   - draft: 创建流程持有的原始草稿；其 UUID 会原样复用。
    ///   - locale: 解析金额时使用的语言环境。
    ///   - now: 注入的创建和更新时间，便于确定性测试。
    /// - Returns: 已完成领域校验和字段清理的账户。
    /// - Throws: 名称或金额不符合持久化约束时抛出 `AccountValidationError`。
    static func validating(
        draft: AccountDraft,
        locale: Locale = .current,
        now: Date = .now
    ) throws -> Account {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AccountValidationError.emptyName }
        guard let balance = AccountAmountParser.amount(from: draft.amountText, locale: locale) else {
            throw AccountValidationError.invalidAmount
        }
        if draft.accountType.requiresTemplateSelection {
            guard let template = draft.template,
                  template.accountType == draft.accountType,
                  draft.accountType.templates.contains(where: { $0.id == template.id })
            else { throw AccountValidationError.invalidTemplate }
        } else if draft.template != nil {
            throw AccountValidationError.invalidTemplate
        }

        return Account(
            id: draft.id,
            typeRawValue: draft.accountType.rawValue,
            templateID: draft.template?.id,
            name: name,
            note: sanitizedOptionalText(draft.note),
            lastFourDigits: sanitizedLastFourDigits(draft.lastFourDigits),
            balance: balance,
            currencyCode: "CNY",
            createdAt: now,
            updatedAt: now
        )
    }

    /// 将空白可选文本归一为 `nil`，其余内容去除首尾空白。
    private static func sanitizedOptionalText(_ value: String) -> String? {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// 仅保留卡号输入中的前四位数字，并将空结果归一为 `nil`。
    private static func sanitizedLastFourDigits(_ value: String) -> String? {
        let cleaned = String(value.filter(\.isWholeNumber).prefix(4))
        return cleaned.isEmpty ? nil : cleaned
    }
}

/// 账户列表与仓库共享的确定性排序规则。
enum AccountOrdering {
    /// 最新更新时间优先；时间相同时按 UUID 字符串升序。
    nonisolated static func newestFirst(_ lhs: Account, _ rhs: Account) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
