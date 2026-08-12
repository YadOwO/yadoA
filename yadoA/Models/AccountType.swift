import Foundation

enum AccountType: String, CaseIterable, Identifiable, Hashable, Sendable {
    case cash
    case debitCard
    case creditCard
    case virtualAccount
    case investment
    case liability
    case receivable
    case customAsset

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cash: "现金"
        case .debitCard: "储蓄卡"
        case .creditCard: "信用卡"
        case .virtualAccount: "虚拟账户"
        case .investment: "投资账户"
        case .liability: "负债"
        case .receivable: "债权"
        case .customAsset: "自定义资产"
        }
    }

    var subtitle: String? {
        switch self {
        case .cash: nil
        case .debitCard: nil
        case .creditCard: "信用卡、花呗、白条"
        case .virtualAccount: "支付宝、微信"
        case .investment: "股票、基金"
        case .liability: "贷款、借入"
        case .receivable: "应收、借出"
        case .customAsset: nil
        }
    }

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

    var amountLabel: String {
        switch self {
        case .cash, .debitCard, .virtualAccount:
            "余额"
        case .creditCard, .liability:
            "欠款"
        case .receivable, .investment, .customAsset:
            "金额"
        }
    }

    var defaultAccountName: String {
        self == .cash ? title : ""
    }

    var showsInstitution: Bool {
        self == .debitCard || self == .creditCard
    }

    var showsLastFourDigits: Bool {
        self == .debitCard || self == .creditCard
    }

    var showsEditableName: Bool {
        !showsInstitution
    }

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

    var requiresTemplateSelection: Bool {
        !templates.isEmpty
    }
}

struct AccountTemplate: Identifiable, Hashable, Sendable {
    let id: String
    let accountType: AccountType
    let name: String
    let symbolName: String
    let brandImageName: String?

    init(
        id: String,
        accountType: AccountType,
        name: String,
        symbolName: String,
        brandImageName: String? = nil
    ) {
        self.id = id
        self.accountType = accountType
        self.name = name
        self.symbolName = symbolName
        self.brandImageName = brandImageName
    }

    static func banks(for accountType: AccountType) -> [AccountTemplate] {
        let banks: [(code: String, name: String, brandImageName: String?)] = [
            ("icbc", "工商银行", "BrandICBC"),
            ("ccb", "建设银行", "BrandCCB"),
            ("abc", "农业银行", "BrandABC"),
            ("boc", "中国银行", "BrandBOC"),
            ("cmb", "招商银行", "BrandCMB"),
            ("bocom", "交通银行", "BrandBOCOM"),
            ("citic", "中信银行", "BrandCITIC"),
            ("spdb", "浦发银行", "BrandSPDB"),
            ("ceb", "光大银行", "BrandCEB"),
            ("cgb", "广发银行", "BrandCGB"),
            ("other", "其他银行", nil)
        ]

        return banks.map { code, name, brandImageName in
            AccountTemplate(
                id: "\(accountType.rawValue).\(code)",
                accountType: accountType,
                name: name,
                symbolName: "building.columns.fill",
                brandImageName: brandImageName
            )
        }
    }

    static let creditInstitutions: [AccountTemplate] = [
        AccountTemplate(id: "creditCard.huabei", accountType: .creditCard, name: "蚂蚁花呗", symbolName: "a.circle.fill", brandImageName: "BrandHuabei"),
        AccountTemplate(id: "creditCard.baitiao", accountType: .creditCard, name: "京东白条", symbolName: "b.circle.fill", brandImageName: "BrandJDBaitiao"),
        AccountTemplate(id: "creditCard.suning", accountType: .creditCard, name: "苏宁任性付", symbolName: "s.circle.fill", brandImageName: "BrandSuningFinance")
    ] + banks(for: .creditCard)

    static let virtualAccounts: [AccountTemplate] = [
        AccountTemplate(id: "virtualAccount.alipay", accountType: .virtualAccount, name: "支付宝", symbolName: "a.circle.fill", brandImageName: "BrandAlipay"),
        AccountTemplate(id: "virtualAccount.wechat", accountType: .virtualAccount, name: "微信", symbolName: "message.fill", brandImageName: "BrandWeChat"),
        AccountTemplate(id: "virtualAccount.other", accountType: .virtualAccount, name: "其他虚拟账户", symbolName: "wallet.bifold.fill")
    ]

    static let investments: [AccountTemplate] = [
        AccountTemplate(id: "investment.stock", accountType: .investment, name: "股票", symbolName: "chart.xyaxis.line"),
        AccountTemplate(id: "investment.fund", accountType: .investment, name: "基金", symbolName: "chart.pie.fill"),
        AccountTemplate(id: "investment.other", accountType: .investment, name: "其他投资", symbolName: "chart.line.uptrend.xyaxis")
    ]
}

struct AccountDraft: Identifiable, Equatable, Sendable {
    let id: UUID
    let accountType: AccountType
    let template: AccountTemplate?
    var name: String
    var note: String
    var lastFourDigits: String
    var amountText: String

    init(
        id: UUID = UUID(),
        accountType: AccountType,
        template: AccountTemplate? = nil,
        name: String? = nil,
        note: String = "",
        lastFourDigits: String = "",
        amountText: String = ""
    ) {
        self.id = id
        self.accountType = accountType
        self.template = template
        self.name = name ?? template?.name ?? accountType.defaultAccountName
        self.note = note
        self.lastFourDigits = lastFourDigits
        self.amountText = amountText
    }

    var isFormValid: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedName.isEmpty && AccountAmountParser.amount(from: amountText) != nil
    }
}
