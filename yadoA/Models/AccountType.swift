import Foundation
import SwiftUI

/// 账户功能使用的本地化查询边界。
enum AccountLocalization {
    /// 已解析语言资源包缓存，避免列表重绘时重复查找 `.lproj`。
    private static let bundleCache = NSCache<NSString, Bundle>()

    /// 按指定语言环境解析稳定的字符串目录键。
    ///
    /// - Parameters:
    ///   - key: `Localizable.xcstrings` 中的稳定键。
    ///   - locale: 用于解析文案的语言环境，默认跟随系统设置。
    /// - Returns: 已本地化的文案；资源缺失时由系统安全回退为键本身。
    static func string(_ key: String, locale: Locale = .current) -> String {
        let localizedBundle = bundle(for: locale)
        return localizedBundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// 查找并缓存指定语言环境对应的资源包。
    private static func bundle(for locale: Locale) -> Bundle {
        let cacheKey = locale.identifier as NSString
        if let cachedBundle = bundleCache.object(forKey: cacheKey) {
            return cachedBundle
        }

        let availableLocalizations = Bundle.main.localizations.filter { $0 != "Base" }
        let preferredLocalization = Bundle.preferredLocalizations(
            from: availableLocalizations,
            forPreferences: [locale.identifier]
        ).first
        let localizedBundle = preferredLocalization
            .flatMap { Bundle.main.path(forResource: $0, ofType: "lproj") }
            .flatMap(Bundle.init(path:))
            ?? .main
        bundleCache.setObject(localizedBundle, forKey: cacheKey)
        return localizedBundle
    }

    /// 将单个展示名称填入本地化格式字符串。
    ///
    /// - Parameters:
    ///   - key: 包含单个字符串占位符的稳定键。
    ///   - value: 需要插入的本地化展示名称。
    ///   - locale: 用于格式化文案的语言环境。
    /// - Returns: 完成插值的本地化文案。
    static func formatted(
        _ key: String,
        value: String,
        locale: Locale = .current
    ) -> String {
        String(format: string(key, locale: locale), locale: locale, value)
    }
}

/// 应用支持的账户业务类型及其展示契约。
enum AccountType: String, CaseIterable, Identifiable, Hashable, Sendable {
    case cash
    case debitCard
    case creditCard
    case virtualAccount
    case investment
    case liability
    case receivable
    case customAsset

    /// 用作列表和持久化引用的稳定类型标识。
    var id: String { rawValue }

    /// 账户类型标题对应的稳定本地化键。
    var titleLocalizationKey: String {
        "account.type.\(rawValue).title"
    }

    /// 当前语言环境下的账户类型标题。
    var title: String {
        title(locale: .current)
    }

    /// 解析指定语言环境下的账户类型标题。
    func title(locale: Locale) -> String {
        AccountLocalization.string(titleLocalizationKey, locale: locale)
    }

    /// 账户类型说明对应的稳定本地化键；无需说明时为 `nil`。
    var subtitleLocalizationKey: String? {
        switch self {
        case .cash, .debitCard, .customAsset:
            nil
        case .creditCard:
            "account.type.creditCard.subtitle"
        case .virtualAccount:
            "account.type.virtualAccount.subtitle"
        case .investment:
            "account.type.investment.subtitle"
        case .liability:
            "account.type.liability.subtitle"
        case .receivable:
            "account.type.receivable.subtitle"
        }
    }

    /// 当前语言环境下的账户类型说明。
    var subtitle: String? {
        subtitle(locale: .current)
    }

    /// 解析指定语言环境下的账户类型说明。
    func subtitle(locale: Locale) -> String? {
        subtitleLocalizationKey.map {
            AccountLocalization.string($0, locale: locale)
        }
    }

    /// 账户类型的默认 SF Symbol；品牌图片不可用时可安全回退到该符号。
    var symbolName: String {
        switch self {
        case .cash: "banknote.fill"
        case .debitCard: "creditcard.fill"
        case .creditCard: "creditcard.trianglebadge.exclamationmark"
        case .virtualAccount: "wallet.bifold.fill"
        case .investment: "chart.line.uptrend.xyaxis"
        case .liability: "arrow.down.right.circle.fill"
        case .receivable: "arrow.up.left.circle.fill"
        case .customAsset: "square.stack.3d.up.fill"
        }
    }

    /// 账户图标使用的系统动态色调，可同时适配浅色与深色外观。
    var tint: Color {
        switch self {
        case .cash: .green
        case .debitCard, .creditCard, .virtualAccount, .investment: .orange
        case .liability: .red
        case .receivable: .blue
        case .customAsset: .indigo
        }
    }

    /// 金额语义对应的稳定本地化键。
    var amountLabelLocalizationKey: String {
        switch self {
        case .cash, .debitCard, .virtualAccount:
            "account.amount.balance"
        case .creditCard, .liability:
            "account.amount.debt"
        case .receivable, .investment, .customAsset:
            "account.amount.value"
        }
    }

    /// 当前语言环境下的金额语义标签。
    var amountLabel: String {
        amountLabel(locale: .current)
    }

    /// 解析指定语言环境下的金额语义标签。
    func amountLabel(locale: Locale) -> String {
        AccountLocalization.string(amountLabelLocalizationKey, locale: locale)
    }

    /// 直接创建账户时预填的名称。
    var defaultAccountName: String {
        defaultAccountName(locale: .current)
    }

    /// 指定语言环境下直接创建账户时预填的名称。
    func defaultAccountName(locale: Locale) -> String {
        self == .cash ? title(locale: locale) : ""
    }

    /// 表单是否展示所属机构。
    var showsInstitution: Bool {
        self == .debitCard || self == .creditCard
    }

    /// 表单是否展示卡号后四位输入项。
    var showsLastFourDigits: Bool {
        self == .debitCard || self == .creditCard
    }

    /// 表单是否允许直接编辑账户名称。
    var showsEditableName: Bool {
        !showsInstitution
    }

    /// 当前账户类型支持的静态模板。
    var templates: [AccountTemplate] {
        switch self {
        case .debitCard:
            AccountTemplate.banks(for: self)
        case .creditCard:
            AccountTemplate.creditInstitutions
        case .virtualAccount:
            AccountTemplate.virtualAccounts
        case .investment:
            AccountTemplate.investments
        case .cash, .liability, .receivable, .customAsset:
            []
        }
    }

    /// 创建该类型账户前是否必须选择模板。
    var requiresTemplateSelection: Bool {
        !templates.isEmpty
    }
}

/// 账户创建流程中的静态机构或产品模板。
struct AccountTemplate: Identifiable, Hashable, Sendable {
    /// 跨版本保持稳定的模板标识。
    let id: String

    /// 模板所属的账户类型。
    let accountType: AccountType

    /// 模板名称对应的稳定本地化键。
    let nameLocalizationKey: String

    /// 品牌图片不可用时使用的 SF Symbol。
    let symbolName: String

    /// Asset Catalog 中的可选品牌图片名称。
    let brandImageName: String?

    /// 当前语言环境下的模板名称。
    var name: String {
        name(locale: .current)
    }

    /// 创建账户模板。
    init(
        id: String,
        accountType: AccountType,
        nameLocalizationKey: String,
        symbolName: String,
        brandImageName: String? = nil
    ) {
        self.id = id
        self.accountType = accountType
        self.nameLocalizationKey = nameLocalizationKey
        self.symbolName = symbolName
        self.brandImageName = brandImageName
    }

    /// 解析指定语言环境下的模板名称。
    func name(locale: Locale) -> String {
        AccountLocalization.string(nameLocalizationKey, locale: locale)
    }

    /// 返回指定银行卡类型的机构模板。
    static func banks(for accountType: AccountType) -> [AccountTemplate] {
        let banks: [(code: String, brandImageName: String?)] = [
            ("icbc", "BrandICBC"),
            ("ccb", "BrandCCB"),
            ("abc", "BrandABC"),
            ("boc", "BrandBOC"),
            ("cmb", "BrandCMB"),
            ("bocom", "BrandBOCOM"),
            ("citic", "BrandCITIC"),
            ("spdb", "BrandSPDB"),
            ("ceb", "BrandCEB"),
            ("cgb", "BrandCGB"),
            ("other", nil)
        ]

        return banks.map { code, brandImageName in
            AccountTemplate(
                id: "\(accountType.rawValue).\(code)",
                accountType: accountType,
                nameLocalizationKey: "account.template.bank.\(code)",
                symbolName: "building.columns.fill",
                brandImageName: brandImageName
            )
        }
    }

    /// 信用账户可选机构模板。
    static let creditInstitutions: [AccountTemplate] = [
        AccountTemplate(id: "creditCard.huabei", accountType: .creditCard, nameLocalizationKey: "account.template.credit.huabei", symbolName: "a.circle.fill", brandImageName: "BrandHuabei"),
        AccountTemplate(id: "creditCard.baitiao", accountType: .creditCard, nameLocalizationKey: "account.template.credit.baitiao", symbolName: "b.circle.fill", brandImageName: "BrandJDBaitiao"),
        AccountTemplate(id: "creditCard.suning", accountType: .creditCard, nameLocalizationKey: "account.template.credit.suning", symbolName: "s.circle.fill", brandImageName: "BrandSuningFinance")
    ] + banks(for: .creditCard)

    /// 虚拟账户可选模板。
    static let virtualAccounts: [AccountTemplate] = [
        AccountTemplate(id: "virtualAccount.alipay", accountType: .virtualAccount, nameLocalizationKey: "account.template.virtual.alipay", symbolName: "a.circle.fill", brandImageName: "BrandAlipay"),
        AccountTemplate(id: "virtualAccount.wechat", accountType: .virtualAccount, nameLocalizationKey: "account.template.virtual.wechat", symbolName: "message.fill", brandImageName: "BrandWeChat"),
        AccountTemplate(id: "virtualAccount.other", accountType: .virtualAccount, nameLocalizationKey: "account.template.virtual.other", symbolName: "wallet.bifold.fill")
    ]

    /// 投资账户可选模板。
    static let investments: [AccountTemplate] = [
        AccountTemplate(id: "investment.stock", accountType: .investment, nameLocalizationKey: "account.template.investment.stock", symbolName: "chart.xyaxis.line"),
        AccountTemplate(id: "investment.fund", accountType: .investment, nameLocalizationKey: "account.template.investment.fund", symbolName: "chart.pie.fill"),
        AccountTemplate(id: "investment.other", accountType: .investment, nameLocalizationKey: "account.template.investment.other", symbolName: "chart.line.uptrend.xyaxis")
    ]
}

/// 账户创建期间尚未持久化的表单草稿。
struct AccountDraft: Identifiable, Equatable, Sendable {
    /// 草稿及未来账户共用的稳定标识。
    let id: UUID

    /// 所选账户类型。
    let accountType: AccountType

    /// 所选静态模板；直接创建的类型没有模板。
    let template: AccountTemplate?

    /// 用户确认或编辑的账户名称。
    var name: String

    /// 用户填写的可选备注。
    var note: String

    /// 银行卡号后四位。
    var lastFourDigits: String

    /// 尚未转换为精确金额的用户输入。
    var amountText: String

    /// 创建账户草稿并按当前语言预填可用名称。
    init(
        id: UUID = UUID(),
        accountType: AccountType,
        template: AccountTemplate? = nil,
        name: String? = nil,
        note: String = "",
        lastFourDigits: String = "",
        amountText: String = "",
        locale: Locale = .current
    ) {
        self.id = id
        self.accountType = accountType
        self.template = template
        self.name = name
            ?? template?.name(locale: locale)
            ?? accountType.defaultAccountName(locale: locale)
        self.note = note
        self.lastFourDigits = lastFourDigits
        self.amountText = amountText
    }

    /// 名称非空且金额可解析为非负值时允许保存。
    var isFormValid: Bool {
        isFormValid(locale: .current)
    }

    /// 使用与最终持久化一致的语言环境校验名称和金额。
    func isFormValid(locale: Locale) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedName.isEmpty
            && AccountAmountParser.amount(from: amountText, locale: locale) != nil
    }
}
