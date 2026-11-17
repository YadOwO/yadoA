import Foundation
import SwiftData
import SwiftUI

/// 与 SwiftUI 渲染解耦的账户行展示数据，便于验证本地化和未知值降级。
struct AccountRowPresentation: Identifiable, Equatable {
    /// 持久账户的稳定标识。
    let id: UUID

    /// 不可改名的机构账户使用本地化模板标签，其余保留持久化账户名称。
    let name: String

    /// 本地化账户类型及可选掩码后缀。
    let detail: String

    /// 使用账户自身货币代码格式化后的金额。
    let formattedAmount: String

    /// 明确表达余额、金额或债务含义的可见标签。
    let amountLabel: String

    /// 同时包含金融语义与金额的无障碍播报文本。
    let amountAccessibilityLabel: String

    /// 金额的上色语义：欠款、透支为负向，其余不上色。
    let amountTone: AmountTone

    /// 是否是当前唯一默认记账账户。
    let isDefault: Bool

    /// 品牌图片或类型降级图标。
    let icon: AccountIconPresentation
}

/// 账户列表顶部资产汇总卡片的展示数据。
struct AccountSummaryPresentation: Equatable {
    /// 所有资产账户余额减去所有负债账户余额后的净资产。
    let netAssets: Decimal

    /// 非负债类型账户的余额总和。
    let assets: Decimal

    /// 信用卡和负债类型账户的债务总和。
    let liabilities: Decimal

    /// 当前语言环境下格式化后的净资产。
    let formattedNetAssets: String

    /// 当前语言环境下格式化后的资产总额。
    let formattedAssets: String

    /// 当前语言环境下格式化后的负债总额。
    let formattedLiabilities: String

    /// 包含三项汇总和金额的完整播报文本。
    let accessibilityLabel: String

    /// 净资产为负时用负向色提示，否则保持墨色。
    var netAssetsTone: AmountTone { netAssets < 0 ? .negative : .neutral }

    /// 有欠款时负债总额用负向色，与账户行的欠款一致。
    var liabilitiesTone: AmountTone { liabilities > 0 ? .negative : .neutral }

    /// 从账户列表生成资产、负债和净资产汇总。
    ///
    /// 未知账户类型按资产处理，以避免损坏或未来类型的余额从总览中无提示消失。
    static func summary(
        for accounts: [Account],
        locale: Locale = .current
    ) -> AccountSummaryPresentation {
        var assets = Decimal.zero
        var liabilities = Decimal.zero

        for account in accounts where account.isActive {
            if account.accountType?.expenseBalanceEffect == .increaseDebt {
                liabilities += account.balance
            } else {
                assets += account.balance
            }
        }
        return summary(assets: assets, liabilities: liabilities, locale: locale)
    }

    /// 由已经汇总好的资产和负债生成展示数据；首次引导的示例账户也用它，和账户页保持同一种写法。
    ///
    /// - Parameters:
    ///   - assets: 资产总额。
    ///   - liabilities: 负债总额，以正数表示欠款。
    ///   - locale: 金额与播报文本使用的语言环境。
    /// - Returns: 资产、负债和净资产汇总。
    static func summary(
        assets: Decimal,
        liabilities: Decimal,
        locale: Locale = .current
    ) -> AccountSummaryPresentation {
        let netAssets = assets - liabilities
        let formattedNetAssets = netAssets.formattedCurrency(locale: locale)
        let formattedAssets = assets.formattedCurrency(locale: locale)
        let formattedLiabilities = liabilities.formattedCurrency(locale: locale)
        let accessibilityLabel = String(
            format: AccountLocalization.string(
                "account.summary.accessibility_format",
                locale: locale
            ),
            locale: locale,
            AccountLocalization.string("account.summary.net_assets", locale: locale),
            formattedNetAssets,
            AccountLocalization.string("account.summary.assets", locale: locale),
            formattedAssets,
            AccountLocalization.string("account.summary.liabilities", locale: locale),
            formattedLiabilities
        )

        return AccountSummaryPresentation(
            netAssets: netAssets,
            assets: assets,
            liabilities: liabilities,
            formattedNetAssets: formattedNetAssets,
            formattedAssets: formattedAssets,
            formattedLiabilities: formattedLiabilities,
            accessibilityLabel: accessibilityLabel
        )
    }
}

/// 账户列表查询结果的确定性排序与展示转换边界。
enum AccountListPresentation {
    /// 只保留启用账户，并按全 App 统一的账户顺序排列。
    ///
    /// - Parameters:
    ///   - accounts: 查询到的全部账户。
    ///   - order: 当前账户分类顺序，由 `AccountDisplayOrder(preferences:)` 从记账偏好读取。
    /// - Returns: 排好序的启用账户。
    static func sorted(_ accounts: [Account], order: AccountDisplayOrder) -> [Account] {
        order.sorted(accounts.filter { $0.isActive })
    }

    /// 将持久模型安全转换为当前语言环境的行展示数据。
    static func row(
        for account: Account,
        locale: Locale = .current,
        isDefault: Bool = false
    ) -> AccountRowPresentation {
        row(
            id: account.id,
            accountType: account.accountType,
            templateID: account.templateID,
            name: account.name,
            lastFourDigits: account.lastFourDigits,
            balance: account.balance,
            currencyCode: account.currencyCode,
            locale: locale,
            isDefault: isDefault
        )
    }

    /// 由账户字段生成行展示数据；首次引导的示例账户不落库，也用它得到与账户页一致的一行。
    ///
    /// - Parameters:
    ///   - id: 账户标识。
    ///   - accountType: 账户类型；未知类型为 `nil`。
    ///   - templateID: 静态模板标识。
    ///   - name: 账户名称。
    ///   - lastFourDigits: 卡号后四位。
    ///   - balance: 当前余额或欠款。
    ///   - currencyCode: ISO 货币代码。
    ///   - locale: 文案与金额使用的语言环境。
    ///   - isDefault: 是否为默认记账账户。
    /// - Returns: 账户行展示数据。
    static func row(
        id: UUID,
        accountType: AccountType?,
        templateID: String?,
        name: String,
        lastFourDigits: String?,
        balance: Decimal,
        currencyCode: String,
        locale: Locale = .current,
        isDefault: Bool = false
    ) -> AccountRowPresentation {
        let template = template(id: templateID, accountType: accountType)
        let typeTitle = accountType?.title(locale: locale)
            ?? AccountLocalization.string("account.type.unknown.title", locale: locale)
        let amountLabel = accountType?.amountLabel(locale: locale)
            ?? AccountLocalization.string("account.amount.value", locale: locale)
        let formattedAmount = balance.formattedCurrency(locale: locale, currencyCode: currencyCode)
        let detail: String
        if let suffix = lastFourDigits {
            detail = String(
                format: AccountLocalization.string("account.list.type_suffix_format", locale: locale),
                locale: locale,
                typeTitle,
                suffix
            )
        } else {
            detail = typeTitle
        }
        let accessibilityLabel = String(
            format: AccountLocalization.string("account.list.amount_accessibility_format", locale: locale),
            locale: locale,
            amountLabel,
            formattedAmount
        )

        return AccountRowPresentation(
            id: id,
            name: accountType?.showsEditableName == false
                ? (template?.name(locale: locale) ?? name)
                : name,
            detail: detail,
            formattedAmount: formattedAmount,
            amountLabel: amountLabel,
            amountAccessibilityLabel: accessibilityLabel,
            amountTone: amountTone(accountType: accountType, balance: balance),
            isDefault: isDefault,
            icon: AccountIconPresentation(
                brandImageName: template?.brandImageName,
                symbolName: template?.symbolName ?? accountType?.symbolName ?? "questionmark.circle.fill",
                tint: accountType?.tint ?? .secondary
            )
        )
    }

    /// 账户金额的上色规则：只给拉低净资产的金额上负向色，资产余额保持墨色，作为资产与负债的轻提示。
    ///
    /// 负债类账户的正余额是欠款，负余额（溢缴）不上色；资产类（含未知类型，与汇总一致）的负余额是透支。
    ///
    /// - Parameters:
    ///   - accountType: 账户类型；未知类型为 `nil`，按资产处理。
    ///   - balance: 当前余额或欠款。
    /// - Returns: 负向或中性。
    static func amountTone(accountType: AccountType?, balance: Decimal) -> AmountTone {
        let isDebt = accountType?.expenseBalanceEffect == .increaseDebt
        let netAssetsEffect = isDebt ? -balance : balance
        return netAssetsEffect < 0 ? .negative : .neutral
    }

    /// 仅接受与持久账户类型一致的当前静态模板，避免过期或损坏 ID 误配品牌。
    static func template(id: String?, accountType: AccountType?) -> AccountTemplate? {
        guard let id, let accountType else { return nil }
        return accountType.templates.first { $0.id == id }
    }
}

/// 将账户数量映射为空/非空状态下唯一主要添加入口的位置。
enum AccountListState {
    /// 空状态是否展示内嵌添加入口。
    static func showsInlineAdd(accountCount: Int) -> Bool { accountCount == 0 }

    /// 非空状态是否在导航栏「更多」菜单中提供添加入口。
    static func showsToolbarAdd(accountCount: Int) -> Bool { accountCount > 0 }

}
