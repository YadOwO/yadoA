import Foundation
import SwiftUI

// 芽豆有物物品估值的纯计算：设置、折算金额、联动状态和账户页那一行的展示数据。
//
// 估值只存在于内存和 UserDefaults，不是 Account，也不是任何 @Model：Account 会自动同步、进导出和备份，估值都不该进去。

// MARK: - 设置

/// 用户对物品估值的三个设置，按 Logto 用户 ID 存在 UserDefaults，不随账本同步，也不在多台设备间一致。
nonisolated struct ItemValuationSettings: Codable, Equatable {
    /// 折扣百分比允许的范围。
    static let discountRange = 10...100

    /// 折扣百分比调整的步长。
    static let discountStep = 5

    /// 账户页是否显示「物品估值」那一行。
    var showsOnAccounts = true

    /// 用户选的「计入净资产」。实际是否计入看 `countsTowardNetWorth`：关掉「显示在账户页」时这项暂不生效，但值保留。
    var countsInNetWorth = true

    /// 折扣百分比：估值 = 购入价合计 × 折扣 ÷ 100。默认 70（七折）。
    var discountPercent = 70

    /// 估值实际是否计入账户页汇总卡片和资产分析的资产、净资产：「显示在账户页」「计入净资产」都打开才计入。
    ///
    /// 关掉显示时一并不计入，免得总资产里有一笔在账户页看不到的钱。
    var countsTowardNetWorth: Bool {
        showsOnAccounts && countsInNetWorth
    }

    private enum CodingKeys: String, CodingKey {
        case showsOnAccounts, countsInNetWorth, discountPercent
    }

    /// 逐项创建，不传参数时是默认设置：显示在账户页、计入净资产、七折；折扣会夹进范围并对齐到步长。
    init(showsOnAccounts: Bool = true, countsInNetWorth: Bool = true, discountPercent: Int = 70) {
        self.showsOnAccounts = showsOnAccounts
        self.countsInNetWorth = countsInNetWorth
        self.discountPercent = Self.clampedDiscount(discountPercent)
    }

    /// 缺字段时取默认值，折扣读出来也夹进范围，本机存的设置被改坏时不会让估值算出奇怪的数。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showsOnAccounts = try container.decodeIfPresent(Bool.self, forKey: .showsOnAccounts) ?? true
        countsInNetWorth = try container.decodeIfPresent(Bool.self, forKey: .countsInNetWorth) ?? true
        discountPercent = Self.clampedDiscount(try container.decodeIfPresent(Int.self, forKey: .discountPercent) ?? 70)
    }

    /// 把折扣夹进 `discountRange`，再对齐到最近的 `discountStep` 的倍数。
    ///
    /// - Parameter value: 想要的折扣百分比。
    /// - Returns: 10...100 之间、5 的倍数的折扣百分比；例如 7 得到 10，103 得到 100，72 得到 70。
    static func clampedDiscount(_ value: Int) -> Int {
        let clamped = min(max(value, discountRange.lowerBound), discountRange.upperBound)
        return (clamped + discountStep / 2) / discountStep * discountStep
    }
}

// MARK: - 计算

/// 物品估值的折算和文案。
nonisolated enum ItemValuation {
    /// 估值金额：（在用 + 退役）购入价合计 × 折扣 ÷ 100，四舍五入到分。
    ///
    /// 用 `Decimal` 计算，例如 (1234.56 + 100.01) × 75% = 1000.9275，舍入后是 1000.93。
    ///
    /// - Parameters:
    ///   - summary: 芽豆有物的购入价汇总。
    ///   - discountPercent: 折扣百分比，例如 70 表示七折。
    /// - Returns: 折算后、保留两位小数的金额。
    static func amount(summary: ItemValueSummary, discountPercent: Int) -> Decimal {
        var value = (summary.inServicePurchaseTotal + summary.retiredPurchaseTotal) * Decimal(discountPercent) / 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .plain)
        return rounded
    }

    /// 折扣在界面上的写法：中文是「7 折」「7.5 折」，100% 写「原价」；英文直接写百分比「70%」。
    ///
    /// - Parameters:
    ///   - percent: 折扣百分比。
    ///   - locale: 文案使用的语言环境。
    /// - Returns: 已本地化的折扣文本。
    @MainActor
    static func discountText(percent: Int, locale: Locale) -> String {
        let isChinese = locale.language.languageCode == .chinese
        if isChinese, percent >= 100 {
            return AccountLocalization.string("itemValuation.discount.original", locale: locale)
        }
        // 中文按「折」说（七折 = 70%），英文直接说百分比
        let shown = isChinese ? Double(percent) / 10 : Double(percent)
        let number = shown.formatted(.number.precision(.fractionLength(0...1)).locale(locale))
        return AccountLocalization.formatted("itemValuation.discount.format", value: number, locale: locale)
    }
}

// MARK: - 联动状态

/// 芽豆有物联动在界面上的四种状态。
nonisolated enum ItemValueLinkState: Equatable {
    /// 没有授权。
    case notGranted

    /// 已联动：已授权，估值可用或还没取到。
    case linked

    /// 已联动，但没有同步到这个账号的物品：一件在用或退役的物品都没有。
    case linkedNoItems

    /// 已联动，但物品都没填购入价，没有可以估值的。
    case linkedNoPrices

    /// 由授权状态和汇总推出界面状态。
    ///
    /// - Parameters:
    ///   - isGranted: 是否已授权。
    ///   - summary: 最近一次的汇总；还没取到时为 nil，按已联动处理。
    /// - Returns: 界面状态。
    static func state(isGranted: Bool, summary: ItemValueSummary?) -> ItemValueLinkState {
        guard isGranted else { return .notGranted }
        guard let summary else { return .linked }
        if summary.pricedItemCount + summary.unpricedItemCount == 0 {
            return .linkedNoItems
        }
        if summary.pricedItemCount == 0 {
            return .linkedNoPrices
        }
        return .linked
    }
}

// MARK: - 账户页的一行

/// 「物品估值」在账户页和资产分析排行里的展示数据，沿用账户行的结构，由 `AccountListRow` 渲染。
enum ItemValuationPresentation {
    /// 这一行固定的标识：不是任何账户的 ID，只用来给行、无障碍标识和笔迹种子一个稳定的值。
    static let rowID = UUID(uuid: (0x59, 0x4F, 0x49, 0x56, 0x41, 0x4C, 0x55, 0x45, 0, 0, 0, 0, 0, 0, 0, 1))

    /// 账户页那一行：副标题写明购入价、折扣和件数；不计入净资产时金额上方的标签改成「不计入净资产」。
    ///
    /// - Parameters:
    ///   - summary: 芽豆有物的购入价汇总。
    ///   - settings: 当前用户的估值设置。
    ///   - locale: 文案与金额使用的语言环境。
    ///   - currencyCode: 金额使用的账本币种；估值数字直接按它显示，不换算。
    /// - Returns: 沿用账户行结构的展示数据。
    static func row(
        summary: ItemValueSummary,
        settings: ItemValuationSettings,
        locale: Locale,
        currencyCode: String
    ) -> AccountRowPresentation {
        row(
            amount: ItemValuation.amount(summary: summary, discountPercent: settings.discountPercent),
            detail: detail(
                summary: summary,
                discountPercent: settings.discountPercent,
                locale: locale,
                currencyCode: currencyCode
            ),
            amountLabel: AccountLocalization.string(
                settings.countsTowardNetWorth ? "itemValuation.amount.label" : "itemValuation.notCounted",
                locale: locale
            ),
            locale: locale,
            currencyCode: currencyCode
        )
    }

    /// 资产分析排行里的一行：只有计入净资产的估值才会进排行，所以标签固定是「估值」，副标题写来源「芽豆有物」。
    ///
    /// - Parameters:
    ///   - amount: 折算后的估值金额。
    ///   - locale: 文案与金额使用的语言环境。
    ///   - currencyCode: 金额使用的账本币种。
    /// - Returns: 沿用账户行结构的展示数据。
    static func row(amount: Decimal, locale: Locale, currencyCode: String) -> AccountRowPresentation {
        row(
            amount: amount,
            detail: AccountLocalization.string("itemValuation.section.title", locale: locale),
            amountLabel: AccountLocalization.string("itemValuation.amount.label", locale: locale),
            locale: locale,
            currencyCode: currencyCode
        )
    }

    /// 由金额、副标题和金额标签拼出一行；两种场景共用，图标、名称、上色规则只在这里定义一处。
    ///
    /// - Parameters:
    ///   - amount: 折算后的估值金额。
    ///   - detail: 名称下面的副标题。
    ///   - amountLabel: 金额上方的标签。
    ///   - locale: 文案与金额使用的语言环境。
    ///   - currencyCode: 金额使用的账本币种。
    private static func row(
        amount: Decimal,
        detail: String,
        amountLabel: String,
        locale: Locale,
        currencyCode: String
    ) -> AccountRowPresentation {
        let formattedAmount = amount.formattedCurrency(locale: locale, currencyCode: currencyCode)
        return AccountRowPresentation(
            id: rowID,
            name: AccountLocalization.string("itemValuation.title", locale: locale),
            detail: detail,
            formattedAmount: formattedAmount,
            amountLabel: amountLabel,
            amountAccessibilityLabel: String(
                format: AccountLocalization.string("account.list.amount_accessibility_format", locale: locale),
                locale: locale,
                amountLabel,
                formattedAmount
            ),
            amountTone: .neutral,
            isDefault: false,
            icon: AccountIconPresentation(brandImageName: nil, symbolName: "shippingbox.fill", tint: .secondary)
        )
    }

    /// 副标题：「购入价 ¥X × 7 折 · N 件」；有没填价格的物品时接上「另有 M 件没填价格」。
    ///
    /// - Parameters:
    ///   - summary: 芽豆有物的购入价汇总。
    ///   - discountPercent: 折扣百分比。
    ///   - locale: 文案与金额使用的语言环境。
    ///   - currencyCode: 金额使用的账本币种。
    static func detail(
        summary: ItemValueSummary,
        discountPercent: Int,
        locale: Locale,
        currencyCode: String
    ) -> String {
        let purchaseTotal = summary.inServicePurchaseTotal + summary.retiredPurchaseTotal
        let base = String(
            format: AccountLocalization.string("itemValuation.detail.format", locale: locale),
            locale: locale,
            purchaseTotal.formattedCurrency(locale: locale, currencyCode: currencyCode),
            ItemValuation.discountText(percent: discountPercent, locale: locale),
            summary.pricedItemCount
        )
        guard summary.unpricedItemCount > 0 else { return base }
        let unpriced = String(
            format: AccountLocalization.string("itemValuation.detail.unpriced.format", locale: locale),
            locale: locale,
            summary.unpricedItemCount
        )
        return String(
            format: AccountLocalization.string("itemValuation.detail.join.format", locale: locale),
            locale: locale,
            base,
            unpriced
        )
    }
}
