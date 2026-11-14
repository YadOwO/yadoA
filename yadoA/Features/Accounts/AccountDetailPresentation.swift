import Foundation
import SwiftData

/// 与 SwiftUI 渲染解耦的账户详情展示数据。
struct AccountDetailPresentation: Equatable {
    /// 当前展示账户的稳定标识。
    let id: UUID

    /// 当前语言环境下的账户展示名称。
    let name: String

    /// 本地化账户类型。
    let typeTitle: String

    /// 已知模板对应的当前本地化机构名称。
    let institution: String?

    /// 已清理的可选卡号后缀。
    let lastFourDigits: String?

    /// 已清理的可选备注。
    let note: String?

    /// 使用持久货币代码格式化后的金额。
    let formattedAmount: String

    /// 余额、金额或债务的本地化语义标签。
    let amountLabel: String

    /// 同时包含金额语义和值的无障碍播报文本。
    let amountAccessibilityLabel: String

    /// 与列表一致的金额上色语义：欠款、透支为负向。
    let amountTone: AmountTone

    /// 与列表一致的品牌图片或类型降级图标。
    let icon: AccountIconPresentation

    /// 账户是否仍处于启用状态。
    let isActive: Bool

    /// 是否是当前唯一默认记账账户。
    let isDefault: Bool
}

/// 账户详情的稳定 UUID 解析与展示转换边界。
enum AccountDetailPresentationFactory {
    /// 在当前持久化查询结果中精确解析 UUID；缺失时不降级到其他账户。
    static func account(id: UUID, in accounts: [Account]) -> Account? {
        accounts.first { $0.id == id }
    }

    /// 复用列表展示结果，确保名称、图标和金额语义保持一致。
    static func detail(
        for account: Account,
        locale: Locale = .current,
        defaultAccountID: UUID? = nil
    ) -> AccountDetailPresentation {
        let row = AccountListPresentation.row(
            for: account,
            locale: locale,
            isDefault: account.id == defaultAccountID
        )
        let accountType = account.accountType
        let template = AccountListPresentation.template(
            id: account.templateID,
            accountType: accountType
        )

        return AccountDetailPresentation(
            id: account.id,
            name: row.name,
            typeTitle: accountType?.title(locale: locale)
                ?? AccountLocalization.string("account.type.unknown.title", locale: locale),
            institution: template?.name(locale: locale),
            lastFourDigits: account.lastFourDigits,
            note: account.note,
            formattedAmount: row.formattedAmount,
            amountLabel: row.amountLabel,
            amountAccessibilityLabel: row.amountAccessibilityLabel,
            amountTone: row.amountTone,
            icon: row.icon,
            isActive: account.isActive,
            isDefault: row.isDefault
        )
    }
}
