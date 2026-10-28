import Foundation

/// 预置支出分类的本地化与默认 SF Symbols 配置。
extension ExpenseCategory {
    /// String Catalog 中稳定的分类名称键。
    var localizationKey: String {
        "expense.category.\(rawValue)"
    }

    /// 预置分类的默认图标；用户可在分类管理中覆盖。
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

/// 预置收入分类的本地化与默认 SF Symbols 配置。
extension IncomeCategory {
    /// String Catalog 中稳定的分类名称键。
    var localizationKey: String {
        "income.category.\(rawValue)"
    }

    /// 预置分类的默认图标；用户可在分类管理中覆盖。
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

/// 收支载荷的分类展示信息；余额调整和转账没有分类，全部返回 `nil`。
extension AccountTransactionPayload {
    /// 收支方向与分类 key；余额调整和转账返回 `nil`。
    var categoryReference: (direction: BookkeepingEntryType, key: String)? {
        switch self {
        case let .expense(key, _): (.expense, key)
        case let .income(key, _): (.income, key)
        case .balanceAdjustment, .transfer: nil
        }
    }

    /// 含收支方向前缀的分类标识，避免收入与支出的同名分类冲突。
    var categoryID: String? {
        categoryReference.map { "\($0.direction.rawValue).\($0.key)" }
    }

    /// 在分类目录中解析分类；未知 key 按「其他」降级。
    ///
    /// - Parameter catalog: 当前分类目录。
    func categoryItem(in catalog: BookkeepingCategoryCatalog) -> BookkeepingCategoryItem? {
        categoryReference.map { catalog.resolvedItem(direction: $0.direction, key: $0.key) }
    }

    /// 分类使用的系统图标名称。
    ///
    /// - Parameter catalog: 当前分类目录。
    func categorySymbolName(in catalog: BookkeepingCategoryCatalog = .presets) -> String? {
        categoryItem(in: catalog)?.symbolName
    }

    /// 返回当前语言环境下的分类名称。
    ///
    /// - Parameters:
    ///   - locale: 预置分类名称使用的语言环境。
    ///   - catalog: 当前分类目录。
    func categoryTitle(
        locale: Locale,
        catalog: BookkeepingCategoryCatalog = .presets
    ) -> String? {
        categoryItem(in: catalog)?.title(locale: locale)
    }
}

/// 收支流水在列表、详情和语音提示里统一的两行文字。
///
/// 写了备注时主行是备注、副行是分类名称；没写备注（或备注与分类名称相同）时主行直接是分类名称，没有副行。
struct BookkeepingEntryLines: Equatable {
    /// 主行文字。
    let title: String

    /// 副行文字；只在主行是备注时为分类名称。
    let subtitle: String?

    /// 按备注是否有效决定两行文字。
    ///
    /// - Parameters:
    ///   - note: 流水的原始备注，空白视为没写。
    ///   - categoryTitle: 当前语言环境下的分类名称。
    init(note: String?, categoryTitle: String) {
        let cleanedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if cleanedNote.isEmpty || cleanedNote == categoryTitle {
            title = categoryTitle
            subtitle = nil
        } else {
            title = cleanedNote
            subtitle = categoryTitle
        }
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
