import Foundation

/// 全 App 统一的账户展示顺序：先按账户分类顺序，同一分类内按创建时间先后。
///
/// 账户页、选账户页、转账、停用时选接替账户，以及语音和 AI 对话拿到的账户列表都从这里取顺序，保证各处一致。
/// 分类顺序由用户在「账户分类排序」中调整，默认与添加账户页的分类顺序一致。
struct AccountDisplayOrder: Equatable, Sendable {
    /// 完整的分类顺序，包含全部已知分类且不重复。
    let accountTypes: [AccountType]

    /// 默认顺序，与添加账户页的分类顺序一致。
    static let `default` = AccountDisplayOrder(accountTypes: AccountType.allCases)

    /// 用排好的分类创建顺序；重复的只保留第一次，缺少的分类按默认顺序补在末尾。
    ///
    /// - Parameter accountTypes: 用户排好的分类，可以不完整。
    init(accountTypes: [AccountType]) {
        var seen = Set<AccountType>()
        let ordered = accountTypes.filter { seen.insert($0).inserted }
        self.accountTypes = ordered + AccountType.allCases.filter { !seen.contains($0) }
    }

    /// 由偏好中存储的原始值还原；旧版本不认识的值直接忽略。
    ///
    /// - Parameter storedRawValues: `BookkeepingPreference.accountTypeOrder`。
    init(storedRawValues: [String]?) {
        self.init(accountTypes: (storedRawValues ?? []).compactMap(AccountType.init(rawValue:)))
    }

    /// 读取偏好中的分类顺序；没有偏好时使用默认顺序。
    ///
    /// - Parameter preference: canonical 记账偏好。
    init(preference: BookkeepingPreference?) {
        self.init(storedRawValues: preference?.accountTypeOrder)
    }

    /// 从视图 `@Query` 到的偏好记录中读取分类顺序。
    ///
    /// - Parameter preferences: 查询到的全部偏好记录，只取 canonical 单例。
    init(preferences: [BookkeepingPreference]) {
        self.init(preference: BookkeepingPreference.canonical(in: preferences))
    }

    /// 写回偏好时使用的原始值；与默认顺序相同时为 `nil`，以后默认顺序调整时自动跟随。
    var storedRawValues: [String]? {
        self == .default ? nil : accountTypes.map(\.rawValue)
    }

    /// 按统一顺序排列账户，不做筛选；未知类型的账户排在最后。
    ///
    /// - Parameter accounts: 任意顺序的账户。
    /// - Returns: 先按分类、再按创建时间排好的账户。
    func sorted(_ accounts: [Account]) -> [Account] {
        let ranks = Dictionary(uniqueKeysWithValues: accountTypes.enumerated().map { ($0.element, $0.offset) })
        let unknownRank = ranks.count
        return accounts.sorted { lhs, rhs in
            let lhsRank = lhs.accountType.flatMap { ranks[$0] } ?? unknownRank
            let rhsRank = rhs.accountType.flatMap { ranks[$0] } ?? unknownRank
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return Self.creationOrder(lhs, rhs)
        }
    }

    /// 按分类分组；没有账户的分类不出现，未知类型的账户合成一组放在最后。
    ///
    /// - Parameter accounts: 任意顺序的账户，不做筛选。
    /// - Returns: 按统一顺序排好的分组。
    func sections(_ accounts: [Account]) -> [AccountTypeSection] {
        var sections: [AccountTypeSection] = []
        for account in sorted(accounts) {
            if let last = sections.last, last.accountType == account.accountType {
                sections[sections.count - 1].accounts.append(account)
            } else {
                sections.append(AccountTypeSection(accountType: account.accountType, accounts: [account]))
            }
        }
        return sections
    }

    /// 同一分类内的顺序：先创建的在前；创建时间相同时按 UUID 字符串升序，保证顺序确定。
    nonisolated static func creationOrder(_ lhs: Account, _ rhs: Account) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

/// 按账户分类分出的一组账户。
struct AccountTypeSection: Identifiable {
    /// 这一组的账户类型；旧版本不认识的类型为 `nil`，合成一组。
    let accountType: AccountType?

    /// 组内按统一顺序排好的账户。
    var accounts: [Account]

    /// 列表分组的稳定标识。
    var id: String { accountType?.rawValue ?? "unknown" }

    /// 分组标题：账户类型名称，未知类型显示「未知账户」。
    ///
    /// - Parameter locale: 文案使用的语言环境。
    /// - Returns: 已本地化的分组标题。
    func title(locale: Locale) -> String {
        accountType?.title(locale: locale)
            ?? AccountLocalization.string("account.type.unknown.title", locale: locale)
    }
}
