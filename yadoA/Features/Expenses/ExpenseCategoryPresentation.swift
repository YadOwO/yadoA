import Foundation

/// 记账分类在选择面板中共用的展示契约。
protocol BookkeepingCategoryPresentable: Identifiable, Equatable {
    /// 持久化和无障碍标识使用的稳定值。
    var rawValue: String { get }

    /// iOS 18 可用的系统图标名称。
    var symbolName: String { get }

    /// 返回当前语言环境下的分类名称。
    func localizedTitle(locale: Locale) -> String
}

/// 支出分类的本地化与 SF Symbols 展示配置。
extension ExpenseCategory: BookkeepingCategoryPresentable {
    /// String Catalog 中稳定的分类名称键。
    var localizationKey: String {
        "expense.category.\(rawValue)"
    }

    /// iOS 18 可用的系统图标名称。
    var symbolName: String {
        switch self {
        case .dining: "fork.knife"
        case .shopping: "bag"
        case .dailyNecessities: "cart"
        case .transportation: "bus"
        case .entertainment: "gamecontroller"
        case .communication: "phone"
        case .clothing: "tshirt"
        case .housing: "house"
        case .household: "sofa"
        case .medical: "cross.case"
        case .education: "graduationcap"
        case .pets: "pawprint"
        case .travel: "airplane"
        case .automotive: "car"
        case .socialGifts: "gift"
        case .other: "ellipsis.circle"
        }
    }

    /// 返回当前语言环境下的分类名称。
    ///
    /// - Parameter locale: 用于选择 String Catalog 资源的语言环境。
    /// - Returns: 已本地化的分类标题。
    func localizedTitle(locale: Locale = .current) -> String {
        AccountLocalization.string(localizationKey, locale: locale)
    }
}

/// 收入分类的本地化与 SF Symbols 展示配置。
extension IncomeCategory: BookkeepingCategoryPresentable {
    /// String Catalog 中稳定的分类名称键。
    var localizationKey: String {
        "income.category.\(rawValue)"
    }

    /// iOS 18 可用的系统图标名称。
    var symbolName: String {
        switch self {
        case .salary: "banknote"
        case .bonus: "star.circle"
        case .investment: "chart.line.uptrend.xyaxis"
        case .partTime: "briefcase"
        case .reimbursement: "doc.text"
        case .refund: "arrow.uturn.backward.circle"
        case .gifts: "gift"
        case .other: "ellipsis.circle"
        }
    }

    /// 返回当前语言环境下的分类名称。
    func localizedTitle(locale: Locale = .current) -> String {
        AccountLocalization.string(localizationKey, locale: locale)
    }
}

/// 收支方向的本地化展示配置。
extension BookkeepingEntryType {
    /// String Catalog 中稳定的收支方向键。
    var localizationKey: String {
        "bookkeeping.entry.type.\(rawValue)"
    }

    /// 返回当前语言环境下的收支方向标题。
    func localizedTitle(locale: Locale = .current) -> String {
        AccountLocalization.string(localizationKey, locale: locale)
    }
}
