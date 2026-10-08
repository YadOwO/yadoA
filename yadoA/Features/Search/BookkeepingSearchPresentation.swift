import Foundation
import SwiftData

/// 搜索页使用的闭区间业务日筛选。
struct BookkeepingSearchDateRange: Equatable, Sendable {
    /// 包含在范围内的起始 `YYYYMMDD`。
    let startDay: Int

    /// 包含在范围内的结束 `YYYYMMDD`。
    let endDay: Int

    /// 创建只接受有效公历业务日且起止有序的日期范围。
    init?(startDay: Int, endDay: Int) {
        guard TransactionDay.isValid(startDay),
              TransactionDay.isValid(endDay),
              startDay <= endDay
        else {
            return nil
        }
        self.startDay = startDay
        self.endDay = endDay
    }

    /// 判断一个业务日是否落在包含起止日的范围内。
    func contains(_ transactionDay: Int) -> Bool {
        (startDay...endDay).contains(transactionDay)
    }
}

/// 搜索页已提交的时间条件；日期草稿不应直接进入该值。
enum BookkeepingSearchTimeFilter: Equatable, Sendable {
    /// 不限制业务日。
    case all

    /// 使用包含起止当天的业务日闭区间。
    case custom(BookkeepingSearchDateRange)

    /// 当前条件是否不限制时间。
    var isUnbounded: Bool {
        if case .all = self { return true }
        return false
    }

    /// 当前条件的业务日范围；不限时间时为空。
    var dateRange: BookkeepingSearchDateRange? {
        if case let .custom(range) = self { return range }
        return nil
    }
}

/// 搜索结果关联账户的只读生命周期状态。
enum BookkeepingTransactionAccountState: Equatable, Sendable {
    /// 账户存在且仍可用，详情允许显示未来编辑入口。
    case active

    /// 账户存在但已停用，只能查看历史流水。
    case deactivated

    /// 流水保存时的账户已不存在，只能以降级状态查看。
    case unavailable

    /// 根据流水关联账户的当前快照推导生命周期状态；账户缺失时为不可用。
    init(account: Account?) {
        self = switch account?.isActive {
        case true: .active
        case false: .deactivated
        case nil: .unavailable
        }
    }

    /// 输出当前语言环境下的账户生命周期状态标题。
    func localizedTitle(locale: Locale) -> String {
        switch self {
        case .active:
            AccountLocalization.string("bookkeeping.search.account.active", locale: locale)
        case .deactivated:
            AccountLocalization.string("bookkeeping.search.account.deactivated", locale: locale)
        case .unavailable:
            AccountLocalization.string("bookkeeping.search.account.unavailable", locale: locale)
        }
    }
}

/// 记账搜索结果的单行本地化展示数据。
struct BookkeepingSearchRowPresentation: Identifiable, Equatable {
    /// 流水稳定标识。
    let id: UUID

    /// 当前语言环境下的真实分类名称。
    let categoryTitle: String

    /// 使用负向金额表示支出的本地化金额。
    let formattedAmount: String

    /// 该行对应的 `YYYYMMDD` 业务日。
    let transactionDay: Int

    /// 当前语言环境下的业务日期。
    let formattedDate: String

    /// 关联账户名称；账户不可用时为空。
    let accountName: String?

    /// 关联账户的当前生命周期状态。
    let accountState: BookkeepingTransactionAccountState

    /// 已清理的可选备注。
    let note: String?

    /// 包含分类、金额、日期、账户状态和备注的播报文本。
    let accessibilityLabel: String
}

/// 记账搜索结果按业务日分组后的展示数据。
struct BookkeepingSearchDayPresentation: Identifiable, Equatable {
    /// 分组使用的 `YYYYMMDD` 业务日。
    let transactionDay: Int

    /// 当前语言环境下的业务日期。
    let formattedDate: String

    /// 当前语言环境下的星期标题。
    let formattedWeekday: String

    /// 同日内按保存时间和 UUID 排序的结果行。
    let rows: [BookkeepingSearchRowPresentation]

    /// 使用业务日作为稳定分组标识。
    var id: Int { transactionDay }
}

/// 搜索页由已提交条件派生出的三种页面状态。
enum BookkeepingSearchState: Equatable, Sendable {
    /// 没有关键词且没有时间条件，等待用户开始搜索。
    case initial

    /// 已执行条件但没有匹配流水。
    case noResults

    /// 至少有一条匹配流水。
    case results
}

/// 记账搜索与只读详情共用的纯展示投影。
struct BookkeepingSearchPresentation {
    /// 已清理的用户关键词。
    let normalizedQuery: String

    /// 已提交的时间条件。
    let timeFilter: BookkeepingSearchTimeFilter

    /// 当前条件派生出的页面状态。
    let state: BookkeepingSearchState

    /// 按业务日倒序排列的结果分组。
    let dayGroups: [BookkeepingSearchDayPresentation]

    /// 初始页中最近有效记账的类别建议，按本地化名称去重且最多展示五项。
    let suggestedCategories: [String]

    /// 复用首页的跨账户稳定排序描述符，避免查询层出现不同顺序。
    static func descriptor() -> FetchDescriptor<AccountTransaction> {
        HomeOverviewPresentation.descriptor()
    }

    /// 创建按稳定 UUID 定向读取单笔流水的描述符。
    static func descriptor(transactionID: UUID) -> FetchDescriptor<AccountTransaction> {
        let targetTransactionID = transactionID
        return FetchDescriptor(
            predicate: #Predicate<AccountTransaction> { transaction in
                transaction.id == targetTransactionID
            },
            sortBy: AccountTransactionOrdering.sortDescriptors
        )
    }

    /// 查询全部账户快照，包含停用账户以保留历史记账的可见性。
    static func accountDescriptor() -> FetchDescriptor<Account> {
        FetchDescriptor(
            sortBy: [
                SortDescriptor(\Account.name, order: .forward),
                SortDescriptor(\Account.id, order: .forward)
            ]
        )
    }

    /// 将流水与账户快照转换为可搜索的本地化结果。
    ///
    /// 该投影先校验业务日和支出载荷，再执行关键词与时间条件，最后才创建
    /// 格式化结果行；余额调整、未知类型、损坏载荷和标题均不会进入搜索语义。
    ///
    /// - Parameters:
    ///   - transactions: SwiftData 提供的跨账户流水快照。
    ///   - accounts: SwiftData 提供的启用与停用账户快照。
    ///   - query: 用户当前输入的原始关键词。
    ///   - timeFilter: 已提交的业务日条件。
    ///   - calendar: 提供业务日时区的日历。
    ///   - locale: 提供分类、金额和日期本地化的语言环境。
    init(
        transactions: [AccountTransaction],
        accounts: [Account],
        query: String,
        timeFilter: BookkeepingSearchTimeFilter = .all,
        calendar sourceCalendar: Calendar = .current,
        locale: Locale = .current
    ) {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let calendar = TransactionDay.gregorianCalendar(
            basedOn: sourceCalendar,
            locale: locale
        )
        self.normalizedQuery = normalizedQuery
        self.timeFilter = timeFilter

        guard !normalizedQuery.isEmpty || !timeFilter.isUnbounded else {
            self.state = .initial
            self.dayGroups = []
            self.suggestedCategories = Self.categorySuggestions(from: transactions, locale: locale)
            return
        }
        self.suggestedCategories = []

        var accountsByID: [UUID: Account] = [:]
        accountsByID.reserveCapacity(accounts.count)
        for account in accounts where accountsByID[account.id] == nil {
            accountsByID[account.id] = account
        }

        let parsedAmount = normalizedQuery.isEmpty
            ? nil
            : AccountAmountParser.amount(from: normalizedQuery, locale: locale)
        // 业务日与分类的种类远少于流水数量，日期解析和分类本地化各自只做一次。
        var dayCache = TransactionDay.DateCache(calendar: calendar, locale: locale)
        var categoryTitles: [String: String] = [:]
        let filteredTransactions = transactions
            .compactMap { transaction -> ValidatedTransaction? in
                // 先用整数业务日排除范围外的流水，避免为其校验载荷。
                let matchesDate = timeFilter.dateRange?.contains(transaction.transactionDay) ?? true
                guard matchesDate,
                      let payload = try? transaction.validatedPayload(),
                      let searchablePayload = Self.searchablePayload(
                          from: payload,
                          locale: locale,
                          categoryTitles: &categoryTitles
                      )
                else {
                    return nil
                }
                let amount = searchablePayload.amount
                let categoryTitle = searchablePayload.categoryTitle

                let note = Self.sanitizedOptionalText(transaction.note)
                let matchesQuery = normalizedQuery.isEmpty
                    || Self.matches(
                        normalizedQuery,
                        categoryTitle: categoryTitle,
                        note: note,
                        amount: amount,
                        parsedAmount: parsedAmount,
                        locale: locale
                    )
                guard matchesQuery,
                      dayCache.date(for: transaction.transactionDay) != nil
                else {
                    return nil
                }

                let account = accountsByID[transaction.accountID]
                return ValidatedTransaction(
                    transaction: transaction,
                    amount: amount,
                    entryType: searchablePayload.entryType,
                    categoryTitle: categoryTitle,
                    accountName: account?.name,
                    accountState: BookkeepingTransactionAccountState(account: account),
                    note: note
                )
            }
        let validTransactions = AccountTransactionOrdering.sorted(filteredTransactions, by: \.transaction)

        let groupedTransactions = Dictionary(
            grouping: validTransactions,
            by: \ValidatedTransaction.transaction.transactionDay
        )
        let weekdayFormatter = BookkeepingDateFormatting.formatter(
            template: "EEEE",
            locale: locale,
            calendar: calendar
        )
        let dayGroups: [BookkeepingSearchDayPresentation] = groupedTransactions.keys.sorted(by: >).compactMap {
            transactionDay in
            guard let date = dayCache.date(for: transactionDay) else {
                return nil
            }
            let formattedDate = BookkeepingDateFormatting.shortDate(
                date,
                locale: locale,
                calendar: calendar
            )
            let rows = groupedTransactions[transactionDay, default: []].map {
                Self.row(for: $0, formattedDate: formattedDate, locale: locale)
            }
            return BookkeepingSearchDayPresentation(
                transactionDay: transactionDay,
                formattedDate: formattedDate,
                formattedWeekday: weekdayFormatter.string(from: date),
                rows: rows
            )
        }
        self.dayGroups = dayGroups
        self.state = dayGroups.isEmpty ? .noResults : .results
    }

    /// 按稳定流水 UUID 定向解析详情，不会缺失时降级到其他流水。
    static func detail(
        transactionID: UUID,
        transactions: [AccountTransaction],
        accounts: [Account],
        calendar sourceCalendar: Calendar = .current,
        locale: Locale = .current
    ) -> BookkeepingTransactionDetailPresentation? {
        guard let transaction = transactions.first(where: { $0.id == transactionID }) else {
            return nil
        }
        let account = accounts.first(where: { $0.id == transaction.accountID })
        return detail(
            for: transaction,
            account: account,
            calendar: sourceCalendar,
            locale: locale
        )
    }

    /// 将一笔合法收支流水和当前账户快照转换为只读详情。
    static func detail(
        for transaction: AccountTransaction,
        account: Account?,
        calendar sourceCalendar: Calendar = .current,
        locale: Locale = .current
    ) -> BookkeepingTransactionDetailPresentation? {
        let calendar = TransactionDay.gregorianCalendar(
            basedOn: sourceCalendar,
            locale: locale
        )
        guard let date = TransactionDay.date(
            from: transaction.transactionDay,
            calendar: calendar,
            locale: locale
        ),
        let payload = try? transaction.validatedPayload()
        else {
            return nil
        }

        var categoryTitles: [String: String] = [:]
        // 图标只在打开详情时解析，不增加批量搜索的展示计算。
        guard let searchablePayload = searchablePayload(
            from: payload,
            locale: locale,
            categoryTitles: &categoryTitles
        ),
        let categorySymbolName = payload.categorySymbolName
        else {
            return nil
        }
        let amount = searchablePayload.amount
        let categoryTitle = searchablePayload.categoryTitle

        let accountState = BookkeepingTransactionAccountState(account: account)
        let accountName = account?.name
        let displayAmount = searchablePayload.entryType == .income ? amount : -amount
        let formattedAmount = displayAmount.formatted(
            .currency(code: transaction.currencyCode).locale(locale)
        )
        let formattedDate = BookkeepingDateFormatting.shortDate(date, locale: locale, calendar: calendar)
        let note = sanitizedOptionalText(transaction.note)
        let accountStatus = accountState.localizedTitle(locale: locale)
        let title = sanitizedOptionalText(transaction.title) ?? categoryTitle
        let spokenParts = [
            title,
            categoryTitle,
            formattedAmount,
            formattedDate,
            accountName,
            accountStatus,
            note
        ].compactMap { $0 }

        return BookkeepingTransactionDetailPresentation(
            id: transaction.id,
            title: title,
            entryType: searchablePayload.entryType,
            categoryTitle: categoryTitle,
            categorySymbolName: categorySymbolName,
            formattedAmount: formattedAmount,
            transactionDay: transaction.transactionDay,
            formattedDate: formattedDate,
            accountName: accountName,
            accountState: accountState,
            note: note,
            accessibilityLabel: spokenParts.joined(separator: ", "),
            canEdit: accountState == .active
                && account?.supportsBookkeeping == true
                && account?.currencyCode == "CNY"
                && transaction.currencyCode == "CNY"
        )
    }

    /// 已完成业务日、载荷和匹配条件校验的中间流水。
    private struct ValidatedTransaction {
        /// 原始流水，用于稳定标识和最终金额展示。
        let transaction: AccountTransaction

        /// 已校验的精确记账金额。
        let amount: Decimal

        /// 当前流水的收支方向。
        let entryType: BookkeepingEntryType
        /// 当前语言环境下的分类名称。
        let categoryTitle: String

        /// 关联账户名称；孤立流水为空。
        let accountName: String?

        /// 账户当前生命周期状态。
        let accountState: BookkeepingTransactionAccountState

        /// 清理后的可选备注。
        let note: String?
    }

    /// 搜索列表与详情共用的收支载荷投影。
    private struct SearchablePayload {
        /// 已校验的正数金额。
        let amount: Decimal

        /// 当前语言环境下的分类名称。
        let categoryTitle: String

        /// 流水的收支方向。
        let entryType: BookkeepingEntryType
    }

    /// 从最近的有效收支记录提取类别，保证每个建议都能通过现有关键词搜索找到结果。
    private static func categorySuggestions(
        from transactions: [AccountTransaction],
        locale: Locale
    ) -> [String] {
        var titles: [String] = []
        var seenTitles: Set<String> = []
        var categoryTitles: [String: String] = [:]
        let orderedTransactions = AccountTransactionOrdering.sorted(transactions) { $0 }
        for transaction in orderedTransactions {
            guard TransactionDay.isValid(transaction.transactionDay),
                  let payload = try? transaction.validatedPayload(),
                  let searchable = searchablePayload(
                      from: payload,
                      locale: locale,
                      categoryTitles: &categoryTitles
                  ),
                  seenTitles.insert(searchable.categoryTitle).inserted
            else { continue }
            titles.append(searchable.categoryTitle)
            if titles.count == 5 { break }
        }
        return titles
    }

    /// 将有效收支载荷转换为搜索语义，排除余额调整。
    ///
    /// - Parameters:
    ///   - payload: 已校验的流水载荷。
    ///   - locale: 分类名称使用的语言环境。
    ///   - categoryTitles: 按分类标识缓存的本地化名称，批量搜索时每个分类只解析一次。
    private static func searchablePayload(
        from payload: AccountTransactionPayload,
        locale: Locale,
        categoryTitles: inout [String: String]
    ) -> SearchablePayload? {
        guard let entry = payload.bookkeepingAmount,
              let categoryID = payload.categoryID
        else {
            return nil
        }
        let categoryTitle: String
        if let cachedTitle = categoryTitles[categoryID] {
            categoryTitle = cachedTitle
        } else if let title = payload.categoryTitle(locale: locale) {
            categoryTitles[categoryID] = title
            categoryTitle = title
        } else {
            return nil
        }
        return SearchablePayload(
            amount: entry.amount,
            categoryTitle: categoryTitle,
            entryType: entry.entryType
        )
    }

    /// 将已过滤的中间结果格式化为结果行。
    private static func row(
        for transaction: ValidatedTransaction,
        formattedDate: String,
        locale: Locale
    ) -> BookkeepingSearchRowPresentation {
        let displayAmount = transaction.entryType == .income
            ? transaction.amount
            : -transaction.amount
        let formattedAmount = displayAmount.formatted(
            .currency(code: transaction.transaction.currencyCode).locale(locale)
        )
        let spokenParts = [
            transaction.categoryTitle,
            formattedAmount,
            formattedDate,
            transaction.accountName,
            transaction.accountState.localizedTitle(locale: locale),
            transaction.note
        ].compactMap { $0 }

        return BookkeepingSearchRowPresentation(
            id: transaction.transaction.id,
            categoryTitle: transaction.categoryTitle,
            formattedAmount: formattedAmount,
            transactionDay: transaction.transaction.transactionDay,
            formattedDate: formattedDate,
            accountName: transaction.accountName,
            accountState: transaction.accountState,
            note: transaction.note,
            accessibilityLabel: spokenParts.joined(separator: ", ")
        )
    }

    /// 执行类别、备注包含匹配与精确金额匹配的 OR 组合。
    private static func matches(
        _ query: String,
        categoryTitle: String,
        note: String?,
        amount: Decimal,
        parsedAmount: Decimal?,
        locale: Locale
    ) -> Bool {
        let textMatches = contains(query, in: categoryTitle, locale: locale)
            || (note.map { contains(query, in: $0, locale: locale) } ?? false)
        let amountMatches = parsedAmount.map { $0 == amount } ?? false
        return textMatches || amountMatches
    }

    /// 使用注入语言环境进行不区分大小写和变音符的包含匹配。
    private static func contains(_ query: String, in value: String, locale: Locale) -> Bool {
        value.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: locale
        ) != nil
    }

    /// 将空白可选文本归一为 `nil`，避免脏数据影响匹配和展示。
    private static func sanitizedOptionalText(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

/// 搜索结果进入详情页后的只读本地化展示数据。
struct BookkeepingTransactionDetailPresentation: Equatable {
    /// 流水稳定标识。
    let id: UUID

    /// 用户标题，旧流水回退到分类名。
    let title: String

    /// 收入与支出方向，供详情明确展示。
    let entryType: BookkeepingEntryType

    /// 当前语言环境下的真实分类名称。
    let categoryTitle: String

    /// 从合法收支载荷解析的分类图标，不通过本地化名称反推类别。
    let categorySymbolName: String

    /// 使用负向金额表示支出的本地化金额。
    let formattedAmount: String

    /// 该流水的 `YYYYMMDD` 业务日。
    let transactionDay: Int

    /// 当前语言环境下的业务日期。
    let formattedDate: String

    /// 账户名称；账户不可用时为空。
    let accountName: String?

    /// 账户当前生命周期状态。
    let accountState: BookkeepingTransactionAccountState

    /// 已清理的可选备注。
    let note: String?

    /// 包含详情字段和账户状态的播报文本。
    let accessibilityLabel: String

    /// 当前账户是否允许编辑与删除流水。
    let canEdit: Bool
}
