import Foundation
import SwiftData

/// 首页使用的自然年月值，独立于具体流水日期和保存时间。
struct HomeMonth: Comparable, Hashable, Sendable {
    /// 自然年的四位数值。
    let year: Int

    /// 自然月，取值范围为 1 到 12。
    let month: Int

    /// 创建有效的自然年月值。
    ///
    /// - Parameters:
    ///   - year: 大于零的公历年份。
    ///   - month: 1 到 12 之间的公历月份。
    init?(year: Int, month: Int) {
        guard year > 0, (1...12).contains(month) else { return nil }
        self.year = year
        self.month = month
    }

    /// 从 `YYYYMM` 整数创建自然年月值。
    ///
    /// - Parameter value: 使用公历年月编码的整数。
    init?(value: Int) {
        self.init(year: value / 100, month: value % 100)
    }

    /// 适合持久化或测试断言的 `YYYYMM` 整数。
    var value: Int { year * 100 + month }

    /// 比较两个自然年月的先后顺序。
    static func < (lhs: HomeMonth, rhs: HomeMonth) -> Bool {
        lhs.year == rhs.year ? lhs.month < rhs.month : lhs.year < rhs.year
    }

    /// 从注入的日期和日历提取自然年月。
    ///
    /// - Parameters:
    ///   - date: 需要转换的日期。
    ///   - calendar: 提供时区的日历。
    ///   - locale: 仅用于保持日期转换的本地化语义。
    /// - Returns: 日期所在的自然年月；无法取得年月时返回 `nil`。
    static func from(
        date: Date,
        calendar sourceCalendar: Calendar,
        locale: Locale = .current
    ) -> HomeMonth? {
        let calendar = TransactionDay.gregorianCalendar(
            basedOn: sourceCalendar,
            locale: locale
        )
        let components = calendar.dateComponents([.year, .month], from: date)
        guard let year = components.year, let month = components.month else { return nil }
        return HomeMonth(year: year, month: month)
    }

    /// 返回该月份在注入日历中的第一天。
    ///
    /// - Parameter calendar: 提供时区和公历规则的日历。
    /// - Returns: 月初日期；年月无法构造时返回 `nil`。
    func firstDate(calendar sourceCalendar: Calendar) -> Date? {
        let calendar = TransactionDay.gregorianCalendar(basedOn: sourceCalendar)
        return calendar.date(from: DateComponents(year: year, month: month, day: 1))
    }

    /// 按自然月移动当前年月，不从业务日或保存时间推断月份。
    ///
    /// - Parameters:
    ///   - count: 要移动的月份数，可为负数。
    ///   - calendar: 提供时区和公历规则的日历。
    /// - Returns: 移动后的年月；无法构造日期时返回 `nil`。
    func adding(months count: Int, calendar: Calendar) -> HomeMonth? {
        guard let date = firstDate(calendar: calendar),
              let shiftedDate = calendar.date(byAdding: .month, value: count, to: date)
        else {
            return nil
        }
        return HomeMonth.from(date: shiftedDate, calendar: calendar)
    }

    /// 使用当前语言环境展示年月标题。
    ///
    /// - Parameters:
    ///   - locale: 月份标题使用的语言环境。
    ///   - calendar: 月份标题使用的公历及时区。
    /// - Returns: 本地化的年月标题；日期格式化失败时返回安全的数字形式。
    func formatted(locale: Locale, calendar sourceCalendar: Calendar) -> String {
        guard let date = firstDate(calendar: sourceCalendar) else {
            return String(format: "%04d-%02d", year, month)
        }

        return BookkeepingDateFormatting.formatter(
            template: "MMMM yyyy",
            locale: locale,
            calendar: TransactionDay.gregorianCalendar(basedOn: sourceCalendar, locale: locale)
        ).string(from: date)
    }
}

/// 首页单条真实收支流水的本地化展示数据。
struct HomeOverviewRowPresentation: Identifiable, Equatable {
    /// 流水稳定标识。
    let id: UUID

    /// 当前语言环境下的流水分类标题。
    let title: String

    /// 流水分类使用的 SF Symbol 名称。
    let symbolName: String

    /// 使用负向金额表示支出的本地化金额。
    let formattedAmount: String

    /// 已清理的可选备注。
    let note: String?

    /// 包含分类、金额、日期和备注的完整播报文本。
    let accessibilityLabel: String
}

/// 一笔流水修改前后在首页行上可见字段的差异，决定修改提示动画里哪些地方要"划掉旧值、写上新值"。
struct HomeOverviewRowRevision: Equatable {
    /// 修改前的首页行快照。
    let previous: HomeOverviewRowPresentation

    /// 修改后的首页行。
    let current: HomeOverviewRowPresentation

    /// 分类图标是否变化。
    var isSymbolChanged: Bool { previous.symbolName != current.symbolName }

    /// 标题（自定义标题或分类名）是否变化。
    var isTitleChanged: Bool { previous.title != current.title }

    /// 备注是否变化，包括新增或清空备注。
    var isNoteChanged: Bool { previous.note != current.note }

    /// 带收支方向的金额是否变化；收支类型切换时符号变化也算。
    var isAmountChanged: Bool { previous.formattedAmount != current.formattedAmount }

    /// 行上是否有任何可见变化；只改了账户或同月日期时为 `false`。
    var hasVisibleChanges: Bool {
        isSymbolChanged || isTitleChanged || isNoteChanged || isAmountChanged
    }
}

/// 刚被删除的流水在首页的行快照，用于在原位置短暂画出被划掉的残影。
///
/// 删除后流水对象已失效，因此在删除前把展示内容和排序键一并拷贝下来。
struct HomeOverviewDeletedRow: Equatable {
    /// 删除前的首页行展示数据。
    let row: HomeOverviewRowPresentation

    /// 被删除流水的 `YYYYMMDD` 业务日，决定残影所在的日期分组。
    let transactionDay: Int

    /// 被删除流水的保存时间，用于在同日流水中还原原来的位置。
    let savedAt: Date

    /// 当前快照是否应排在指定流水之前，与 `AccountTransactionOrdering.newestFirst` 的同日规则一致。
    ///
    /// - Parameter transaction: 同一业务日内仍然存在的流水。
    /// - Returns: 残影应排在该流水之前时返回 `true`。
    func precedes(_ transaction: AccountTransaction) -> Bool {
        if savedAt != transaction.savedAt {
            return savedAt > transaction.savedAt
        }
        return row.id.uuidString < transaction.id.uuidString
    }
}

/// 首页按业务日分组的明细展示数据。
struct HomeOverviewDayPresentation: Identifiable, Equatable {
    /// 分组使用的 `YYYYMMDD` 业务日。
    let transactionDay: Int

    /// 当前语言环境下的短日期。
    let formattedDate: String

    /// 当前语言环境下的星期标题。
    let formattedWeekday: String

    /// 当前分组的真实收入总额。
    let incomeTotal: Decimal

    /// 当前分组的真实支出总额。
    let expenseTotal: Decimal

    /// 按稳定流水顺序排列的明细行。
    let rows: [HomeOverviewRowPresentation]

    /// 使用业务日作为 SwiftUI 分组标识。
    var id: Int { transactionDay }
}

/// 首页单个月份的收入、支出和按日明细展示数据。
struct HomeOverviewMonthPresentation: Equatable {
    /// 当前投影对应的自然年月。
    let month: HomeMonth

    /// 当前语言环境下的月份标题。
    let formattedMonth: String

    /// 当前月份的真实收入总额。
    let incomeTotal: Decimal

    /// 当前月份的真实支出总额。
    let expenseTotal: Decimal

    /// 按业务日倒序排列的日期分组。
    let dayGroups: [HomeOverviewDayPresentation]

    /// 当前月份是否没有可展示的真实流水。
    var isEmpty: Bool { dayGroups.isEmpty }
}

/// 在可用真实数据月份中进行双向最近月份查找的纯导航器。
struct HomeMonthNavigator: Equatable {
    /// 去重后按自然年月升序排列的真实数据月份。
    let availableMonths: [HomeMonth]

    /// 创建一个只依赖真实数据月份集合的导航器。
    ///
    /// - Parameter availableMonths: 有真实收入或支出的月份集合。
    init(availableMonths: some Sequence<HomeMonth>) {
        self.availableMonths = Array(Set(availableMonths)).sorted()
    }

    /// 查找当前月份之前最近的有数据月份。
    ///
    /// - Parameter month: 当前选中的自然月。
    /// - Returns: 更早方向最近的有数据月份；没有匹配项时返回 `nil`。
    func earlierMonth(from month: HomeMonth) -> HomeMonth? {
        availableMonths.last(where: { $0 < month })
    }

    /// 查找当前月份之后最近的有数据月份。
    ///
    /// - Parameter month: 当前选中的自然月。
    /// - Returns: 更晚方向最近的有数据月份；没有匹配项时返回 `nil`。
    func laterMonth(from month: HomeMonth) -> HomeMonth? {
        availableMonths.first(where: { $0 > month })
    }

}

/// 首页跨账户流水的纯展示投影与月份浏览边界。
struct HomeOverviewPresentation {
    /// 跨账户查询所有流水，并保持首页所需的稳定排序。
    ///
    /// - Returns: 可直接提供给 SwiftData `@Query` 或查询上下文的描述符。
    static func descriptor() -> FetchDescriptor<AccountTransaction> {
        FetchDescriptor(sortBy: AccountTransactionOrdering.sortDescriptors)
    }

    /// 经过校验并按展示顺序保存的首页真实流水。
    private let validTransactions: [ValidatedTransaction]

    /// 所有包含真实收入或支出的自然月份，按年月升序排列。
    let availableMonths: [HomeMonth]

    /// 注入日期所在月份对应的初始展示月份。
    let initialMonth: HomeMonth

    /// 创建跨账户首页投影。
    ///
    /// 只有 `validatedPayload()` 成功解码出的支出才会进入首页；余额调整、
    /// 未知类型、损坏字段和无效业务日都会被安全排除。
    ///
    /// - Parameters:
    ///   - transactions: 跨账户查询得到的原始流水。
    ///   - now: 用于选择初始月份的注入日期。
    ///   - calendar: 提供时区和公历规则的日历。
    ///   - locale: 用于月份、日期、星期和行展示的语言环境。
    ///   - catalog: 解析分类名称与图标使用的分类目录。
    init(
        transactions: [AccountTransaction],
        now: Date = .now,
        calendar sourceCalendar: Calendar = .current,
        locale: Locale = .current,
        catalog: BookkeepingCategoryCatalog = .presets
    ) {
        let calendar = TransactionDay.gregorianCalendar(
            basedOn: sourceCalendar,
            locale: locale
        )
        // 流水数量远多于业务日数量：日期按业务日解析一次，月份直接取自 `YYYYMM`。
        var dayCache = TransactionDay.DateCache(calendar: calendar, locale: locale)
        let sortedTransactions = AccountTransactionOrdering.sorted(transactions) { $0 }
        let validTransactions = sortedTransactions.compactMap { transaction -> ValidatedTransaction? in
            guard dayCache.date(for: transaction.transactionDay) != nil,
                  let month = HomeMonth(value: transaction.transactionDay / 100),
                  let payload = try? transaction.validatedPayload(),
                  let entry = payload.bookkeepingAmount,
                  let symbolName = payload.categorySymbolName(in: catalog)
            else {
                return nil
            }
            return ValidatedTransaction(
                transaction: transaction,
                month: month,
                payload: payload,
                symbolName: symbolName,
                amount: entry.amount,
                entryType: entry.entryType
            )
        }
        self.validTransactions = validTransactions
        self.availableMonths = HomeMonthNavigator(
            availableMonths: validTransactions.map(\.month)
        ).availableMonths
        self.initialMonth = Self.initialMonth(
            now: now,
            calendar: calendar,
            availableMonths: self.availableMonths
        )
        self.locale = locale
        self.calendar = calendar
        self.catalog = catalog
    }

    /// 生成指定月份的完整展示投影；空月份也会返回可渲染的空状态数据。
    ///
    /// - Parameters:
    ///   - month: 要展示的自然年月，可以是任意有效月份。
    ///   - deletedRows: 需要在原位置保留残影的已删除流水；只插入明细行，不计入任何汇总。
    /// - Returns: 月份标题、精确汇总和按日明细。
    func presentation(
        for month: HomeMonth,
        retaining deletedRows: [HomeOverviewDeletedRow] = []
    ) -> HomeOverviewMonthPresentation {
        let monthTransactions = validTransactions.filter { $0.month == month }
        let groupedTransactions = Dictionary(grouping: monthTransactions, by: \.transaction.transactionDay)
        // 查询尚未刷新时被删流水仍在结果里，不再重复插入残影；残影所在日期可能已没有其他流水，此时仍要为它保留日期分组。
        let deletedRows = deletedRows.filter { candidate in
            HomeMonth(value: candidate.transactionDay / 100) == month
                && !monthTransactions.contains { $0.transaction.id == candidate.row.id }
        }
        var transactionDays = Set(groupedTransactions.keys)
        for deletedRow in deletedRows {
            transactionDays.insert(deletedRow.transactionDay)
        }
        let weekdayFormatter = BookkeepingDateFormatting.formatter(
            template: "EEEE",
            locale: locale,
            calendar: calendar
        )
        let dayGroups = transactionDays.sorted(by: >).compactMap {
            transactionDay -> HomeOverviewDayPresentation? in
            guard let date = TransactionDay.date(
                from: transactionDay,
                calendar: calendar,
                locale: locale
            ) else {
                return nil
            }

            let transactions = groupedTransactions[transactionDay, default: []]
            let formattedDate = BookkeepingDateFormatting.shortDate(
                date,
                locale: locale,
                calendar: calendar
            )
            var rows = transactions.map {
                Self.row(for: $0, formattedDate: formattedDate, locale: locale, catalog: catalog)
            }
            // 多条残影按保存时间从新到旧依次插入，每条都插到第一条比它旧的真实流水之前，同日顺序与删除前一致
            let dayDeletedRows = deletedRows
                .filter { $0.transactionDay == transactionDay }
                .sorted { $0.savedAt > $1.savedAt }
            for deletedRow in dayDeletedRows {
                let index = rows.firstIndex { row in
                    transactions.first { $0.transaction.id == row.id }.map { deletedRow.precedes($0.transaction) }
                        ?? false
                } ?? rows.endIndex
                rows.insert(deletedRow.row, at: index)
            }
            let incomeTotal = transactions.reduce(into: Decimal.zero) { total, transaction in
                if transaction.entryType == .income {
                    total += transaction.amount
                }
            }
            let expenseTotal = transactions.reduce(into: Decimal.zero) { total, transaction in
                if transaction.entryType == .expense {
                    total += transaction.amount
                }
            }
            return HomeOverviewDayPresentation(
                transactionDay: transactionDay,
                formattedDate: formattedDate,
                formattedWeekday: weekdayFormatter.string(from: date),
                incomeTotal: incomeTotal,
                expenseTotal: expenseTotal,
                rows: rows
            )
        }

        let expenseTotal = dayGroups.reduce(into: Decimal.zero) { total, day in
            total += day.expenseTotal
        }
        let incomeTotal = dayGroups.reduce(into: Decimal.zero) { total, day in
            total += day.incomeTotal
        }
        return HomeOverviewMonthPresentation(
            month: month,
            formattedMonth: month.formatted(locale: locale, calendar: calendar),
            incomeTotal: incomeTotal,
            expenseTotal: expenseTotal,
            dayGroups: dayGroups
        )
    }

    /// 在删除前为一笔流水生成首页残影快照。
    ///
    /// - Parameters:
    ///   - transaction: 即将删除、仍然有效的原始流水。
    ///   - locale: 标题、金额和日期使用的语言环境。
    ///   - calendar: 日期使用的公历及时区。
    ///   - catalog: 解析分类名称与图标使用的分类目录。
    /// - Returns: 残影快照；流水不会出现在首页时返回 `nil`。
    static func deletedRow(
        for transaction: AccountTransaction,
        locale: Locale = .current,
        calendar: Calendar = .current,
        catalog: BookkeepingCategoryCatalog = .presets
    ) -> HomeOverviewDeletedRow? {
        guard let row = row(for: transaction, locale: locale, calendar: calendar, catalog: catalog)
        else { return nil }
        return HomeOverviewDeletedRow(
            row: row,
            transactionDay: transaction.transactionDay,
            savedAt: transaction.savedAt
        )
    }

    /// 将一笔有效收支流水转换为首页本地化明细行。
    ///
    /// - Parameters:
    ///   - transaction: 需要转换的原始流水。
    ///   - locale: 标题、金额和日期使用的语言环境。
    ///   - calendar: 日期使用的公历及时区。
    ///   - catalog: 解析分类名称与图标使用的分类目录。
    /// - Returns: 可展示的首页行；无效日期、损坏载荷和非真实支出返回 `nil`。
    static func row(
        for transaction: AccountTransaction,
        locale: Locale = .current,
        calendar sourceCalendar: Calendar = .current,
        catalog: BookkeepingCategoryCatalog = .presets
    ) -> HomeOverviewRowPresentation? {
        guard let payload = try? transaction.validatedPayload(),
              let symbolName = payload.categorySymbolName(in: catalog),
              TransactionDay.date(
                  from: transaction.transactionDay,
                  calendar: sourceCalendar,
                  locale: locale
              ) != nil
        else {
            return nil
        }

        return row(
            for: transaction,
            payload: payload,
            symbolName: symbolName,
            formattedDate: AccountTransactionHistoryPresentation.formattedDate(
                transaction.transactionDay,
                locale: locale,
                calendar: sourceCalendar
            ),
            locale: locale,
            catalog: catalog
        )
    }

    /// 把初始化阶段已校验的收支流水转换为首页明细行，不再重复校验载荷。
    private static func row(
        for validated: ValidatedTransaction,
        formattedDate: String,
        locale: Locale,
        catalog: BookkeepingCategoryCatalog
    ) -> HomeOverviewRowPresentation {
        row(
            for: validated.transaction,
            payload: validated.payload,
            symbolName: validated.symbolName,
            formattedDate: formattedDate,
            locale: locale,
            catalog: catalog
        )
    }

    /// 复用账户流水行的标题、金额与播报文本，并补充首页使用的分类图标。
    private static func row(
        for transaction: AccountTransaction,
        payload: AccountTransactionPayload,
        symbolName: String,
        formattedDate: String,
        locale: Locale,
        catalog: BookkeepingCategoryCatalog
    ) -> HomeOverviewRowPresentation {
        let historyRow = AccountTransactionHistoryPresentation.row(
            for: transaction,
            payload: payload,
            formattedDate: formattedDate,
            locale: locale,
            catalog: catalog
        )
        return HomeOverviewRowPresentation(
            id: historyRow.id,
            title: historyRow.title,
            symbolName: symbolName,
            formattedAmount: historyRow.formattedAmount,
            note: historyRow.note,
            accessibilityLabel: historyRow.accessibilityLabel
        )
    }

    /// 根据当前日期和真实数据月份选择首页首次展示月份。
    ///
    /// 当前月有数据时优先当前月；当前月为空时优先最近历史月份，若没有历史数据
    /// 则选择最早未来数据月份；完全没有数据时保留当前月。
    ///
    /// - Parameters:
    ///   - now: 注入的当前日期。
    ///   - calendar: 提供时区和公历规则的日历。
    ///   - availableMonths: 已确认包含真实流水的月份集合。
    /// - Returns: 符合首页初始规则的月份。
    static func initialMonth(
        now: Date,
        calendar sourceCalendar: Calendar,
        availableMonths: some Sequence<HomeMonth>
    ) -> HomeMonth {
        let calendar = TransactionDay.gregorianCalendar(basedOn: sourceCalendar)
        let currentMonth = HomeMonth.from(date: now, calendar: calendar)
            ?? HomeMonth(year: 1970, month: 1)!
        let months = HomeMonthNavigator(availableMonths: availableMonths).availableMonths
        guard !months.contains(currentMonth) else { return currentMonth }
        if let previousMonth = months.last(where: { $0 < currentMonth }) {
            return previousMonth
        }
        return months.first(where: { $0 > currentMonth }) ?? currentMonth
    }

    /// 已完成有效日期、载荷和自然月份解码的收支流水。
    private struct ValidatedTransaction {
        /// 原始流水，供本地化行展示使用。
        let transaction: AccountTransaction

        /// 由业务日解析出的自然月份。
        let month: HomeMonth

        /// 已校验的收支载荷，生成明细行时直接复用。
        let payload: AccountTransactionPayload

        /// 分类使用的系统图标名称。
        let symbolName: String

        /// 经 `validatedPayload()` 确认的精确记账金额。
        let amount: Decimal

        /// 当前流水的收支方向。
        let entryType: BookkeepingEntryType
    }

    /// 首页投影使用的固定语言环境。
    private let locale: Locale

    /// 首页投影使用的固定公历及时区。
    private let calendar: Calendar

    /// 首页投影使用的分类目录。
    private let catalog: BookkeepingCategoryCatalog
}
