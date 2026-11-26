import Foundation

/// 资产负债率配哪一句大白话；只陈述事实，不评价好坏。
enum DebtRatioLevel: Equatable {
    /// 没有负债（含信用卡多还了、欠款为负）。
    case noDebt

    /// 有负债，但不到资产的 1%。
    case negligible

    /// 每 100 元资产里有多少元是负债，取整后在 1...100 之间。
    case partial(perHundred: Int)

    /// 负债超过了资产，或者没有资产却有负债。
    case exceedsAssets
}

/// 资产或负债排行里的一行：一个账户和它占这一侧的比例。
struct AssetRankingRow: Identifiable, Equatable {
    /// 与账户列表相同的行展示数据：名称、类型与尾号、图标、金额和上色语义。
    let row: AccountRowPresentation

    /// 账户当前余额；负债一侧是欠款，正数表示欠了多少。
    let amount: Decimal

    /// 占这一侧正数合计的比例，0...1；金额不为正（透支、多还）时为 `nil`，不画比例线。
    let share: Double?

    /// 点这一行打开的页面：账户是它的详情，芽豆有物的物品估值是估值详情。
    let destination: AccountsRoute

    /// 账户 UUID（物品估值是它固定的标识），用作列表标识。
    var id: UUID { row.id }
}

/// 资产分析页的展示数据：资产负债率、按账户类型的构成和按账户的排行。
///
/// 与账户页汇总卡片同一口径：只算启用中的账户；信用卡、负债的余额是欠款，算负债；未知类型按资产算。
/// 计入净资产的芽豆有物物品估值作为一项额外的资产，进资产合计、构成和排行。
/// 走势部分不在这里，仍由 `AccountBalanceHistory` 按日推算，不含估值。
struct AssetAnalysisPresentation: Equatable {
    /// 构成环形图单独画出的最多类型数，与 `ChartPalette` 的颜色位数一致，更多的合并成「其他」。
    static let maxCompositionSegments = ChartPalette.slotCount

    /// 未知类型账户在构成里的标识。
    static let unknownTypeID = "unknown"

    /// 芽豆有物物品估值在构成里的标识。
    static let itemValuationID = "yadoi.itemValuation"

    /// 资产合计：非负债类账户的余额之和。
    let assets: Decimal

    /// 负债合计：信用卡和负债类账户的欠款之和。
    let liabilities: Decimal

    /// 资产按账户类型的构成。
    let assetComposition: CategoryBreakdownPresentation

    /// 负债按账户类型的构成。
    let liabilityComposition: CategoryBreakdownPresentation

    /// 资产按账户从多到少的排行，余额为零的不列。
    let assetRanking: [AssetRankingRow]

    /// 负债按账户从多到少的排行，欠款为零的不列。
    let liabilityRanking: [AssetRankingRow]

    /// 净资产：资产减负债。
    var netAssets: Decimal { assets - liabilities }

    /// 资产负债率：负债 ÷ 资产；资产不为正时没有意义，为 `nil`；没有负债时为零。
    var debtRatio: Decimal? {
        guard assets > 0 else { return nil }
        return max(liabilities, 0) / assets
    }

    /// 资产负债率对应的说明分档。
    var debtRatioLevel: DebtRatioLevel {
        guard liabilities > 0 else { return .noDebt }
        guard let ratio = debtRatio, ratio <= 1 else { return .exceedsAssets }
        let perHundred = Int((ratio * 100).doubleValue.rounded())
        return perHundred < 1 ? .negligible : .partial(perHundred: min(perHundred, 100))
    }

    /// 由账户生成分析数据。
    ///
    /// - Parameters:
    ///   - accounts: 账户；停用的和「不关联账户」会被排除。
    ///   - itemValuation: 计入净资产的芽豆有物物品估值；为 nil 或不大于 0 时没有这一项，结果与不传完全一致。
    ///   - locale: 名称、金额和合并项使用的语言环境。
    init(accounts: [Account], itemValuation: Decimal? = nil, locale: Locale = .current) {
        let valuation = itemValuation.flatMap { $0 > 0 ? $0 : nil }
        let active = accounts.filter { $0.isActive && !$0.isUnlinked }
        var assetAccounts: [Account] = []
        var liabilityAccounts: [Account] = []
        for account in active {
            if account.accountType?.expenseBalanceEffect == .increaseDebt {
                liabilityAccounts.append(account)
            } else {
                assetAccounts.append(account)
            }
        }

        assets = assetAccounts.reduce(valuation ?? .zero) { $0 + $1.balance }
        liabilities = liabilityAccounts.reduce(Decimal.zero) { $0 + $1.balance }
        assetComposition = Self.composition(of: assetAccounts, itemValuation: valuation, locale: locale)
        liabilityComposition = Self.composition(of: liabilityAccounts, locale: locale)
        assetRanking = Self.ranking(of: assetAccounts, itemValuation: valuation, locale: locale)
        liabilityRanking = Self.ranking(of: liabilityAccounts, locale: locale)
    }

    /// 某个 tab 的构成；净资产没有构成，返回资产的构成。
    ///
    /// - Parameter metric: 资产或负债。
    func composition(for metric: NetWorthTrendMetric) -> CategoryBreakdownPresentation {
        metric == .liabilities ? liabilityComposition : assetComposition
    }

    /// 某个 tab 的排行；净资产没有排行，返回资产的排行。
    ///
    /// - Parameter metric: 资产或负债。
    func ranking(for metric: NetWorthTrendMetric) -> [AssetRankingRow] {
        metric == .liabilities ? liabilityRanking : assetRanking
    }

    /// 同一侧账户按类型合计；合计不为正的类型不画，超过 `maxCompositionSegments` 类时把较小的合并成「其他」。
    ///
    /// - Parameters:
    ///   - accounts: 同一侧（资产或负债）的启用账户。
    ///   - itemValuation: 资产一侧额外的芽豆有物物品估值，作为单独一项；为 nil 或不大于 0 时没有这一项。
    ///   - locale: 类型名称使用的语言环境。
    static func composition(
        of accounts: [Account],
        itemValuation: Decimal? = nil,
        locale: Locale
    ) -> CategoryBreakdownPresentation {
        var totals: [String: Decimal] = [:]
        var types: [String: AccountType?] = [:]
        for account in accounts {
            let id = account.accountType?.rawValue ?? unknownTypeID
            totals[id, default: .zero] += account.balance
            types[id] = account.accountType
        }
        var items = totals.map { id, amount in
            let type = types[id] ?? nil
            return CategoryRankingItem(
                id: id,
                title: type?.title(locale: locale)
                    ?? AccountLocalization.string("account.type.unknown.title", locale: locale),
                symbolName: type?.symbolName ?? "questionmark.circle.fill",
                amount: amount
            )
        }
        if let itemValuation, itemValuation > 0 {
            items.append(CategoryRankingItem(
                id: itemValuationID,
                title: AccountLocalization.string("itemValuation.title", locale: locale),
                symbolName: "shippingbox",
                amount: itemValuation
            ))
        }
        return CategoryBreakdownPresentation(
            items: items,
            locale: locale,
            maxSegments: maxCompositionSegments,
            remainingTitleKey: "account.analysis.composition.remaining"
        )
    }

    /// 同一侧账户按余额从多到少排；金额相同时按名称，余额为零的不列。
    ///
    /// 账户和芽豆有物物品估值先统一成「行、金额、点进去的页面」，再一起排序、一起算占比，占比的分母包含估值。
    ///
    /// - Parameters:
    ///   - accounts: 同一侧（资产或负债）的启用账户。
    ///   - itemValuation: 资产一侧额外的芽豆有物物品估值，作为单独一行；为 nil 或不大于 0 时没有这一行。
    ///   - locale: 名称和金额使用的语言环境。
    static func ranking(
        of accounts: [Account],
        itemValuation: Decimal? = nil,
        locale: Locale
    ) -> [AssetRankingRow] {
        var entries: [(row: AccountRowPresentation, amount: Decimal, destination: AccountsRoute)] = accounts.map { account in
            (AccountListPresentation.row(for: account, locale: locale), account.balance, AccountsRoute.detail(account.id))
        }
        if let itemValuation, itemValuation > 0 {
            entries.append((
                ItemValuationPresentation.row(amount: itemValuation, locale: locale),
                itemValuation,
                AccountsRoute.itemValuation
            ))
        }

        let positiveTotal = entries.reduce(Decimal.zero) { $0 + max($1.amount, 0) }
        return entries
            .filter { $0.amount != 0 }
            .map { entry in
                let share: Double? = entry.amount > 0 && positiveTotal > 0
                    ? (entry.amount / positiveTotal).doubleValue
                    : nil
                return AssetRankingRow(
                    row: entry.row,
                    amount: entry.amount,
                    share: share,
                    destination: entry.destination
                )
            }
            .sorted { lhs, rhs in
                lhs.amount == rhs.amount
                    ? lhs.row.name.localizedStandardCompare(rhs.row.name) == .orderedAscending
                    : lhs.amount > rhs.amount
            }
    }
}
