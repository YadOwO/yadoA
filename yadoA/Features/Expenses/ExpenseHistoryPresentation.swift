import Foundation
import SwiftData

/// 账户详情中单条餐饮支出的展示数据。
struct ExpenseHistoryRowPresentation: Identifiable, Equatable {
    /// 流水的稳定标识。
    let id: UUID

    /// 当前语言环境下的固定餐饮分类。
    let categoryTitle: String

    /// 以负向 CNY 金额表达的支出值。
    let formattedAmount: String

    /// 当前语言环境下的公历记账日期。
    let formattedDate: String

    /// 已清理的可选流水备注。
    let note: String?
}

/// 账户流水的 SwiftData 查询与展示转换边界。
enum ExpenseHistoryPresentation {
    /// 创建只查询目标账户、并按记账日和保存时间稳定排序的描述符。
    ///
    /// - Parameter accountID: 当前账户的稳定 UUID。
    /// - Returns: 可供 `@Query` 与真实容器测试共同使用的查询描述符。
    static func descriptor(accountID: UUID) -> FetchDescriptor<ExpenseTransaction> {
        let targetAccountID = accountID
        return FetchDescriptor(
            predicate: #Predicate<ExpenseTransaction> { transaction in
                transaction.accountID == targetAccountID
            },
            sortBy: [
                SortDescriptor(\ExpenseTransaction.transactionDay, order: .reverse),
                SortDescriptor(\ExpenseTransaction.savedAt, order: .reverse),
                SortDescriptor(\ExpenseTransaction.id, order: .forward)
            ]
        )
    }

    /// 将持久化餐饮流水转换为本地化的负向支出展示。
    ///
    /// - Parameters:
    ///   - transaction: 已持久化的餐饮支出流水。
    ///   - locale: 分类、金额和日期使用的语言环境。
    ///   - calendar: 提供当前时区的日历，展示时统一使用公历。
    /// - Returns: 可直接渲染到账户详情的流水行。
    static func row(
        for transaction: ExpenseTransaction,
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> ExpenseHistoryRowPresentation {
        ExpenseHistoryRowPresentation(
            id: transaction.id,
            categoryTitle: AccountLocalization.string(
                "expense.category.dining",
                locale: locale
            ),
            formattedAmount: (-transaction.amount).formatted(
                .currency(code: transaction.currencyCode)
                    .locale(locale)
            ),
            formattedDate: formattedDate(
                transaction.transactionDay,
                locale: locale,
                calendar: calendar
            ),
            note: transaction.note
        )
    }

    /// 把 `YYYYMMDD` 整数转换为当前语言环境下的短日期。
    private static func formattedDate(
        _ transactionDay: Int,
        locale: Locale,
        calendar sourceCalendar: Calendar
    ) -> String {
        let year = transactionDay / 10_000
        let month = transactionDay / 100 % 100
        let day = transactionDay % 100
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = sourceCalendar.timeZone
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day
        )
        guard let date = calendar.date(from: components) else {
            return String(transactionDay)
        }

        return date.formatted(
            Date.FormatStyle(
                date: .numeric,
                time: .omitted,
                locale: locale,
                calendar: calendar,
                timeZone: calendar.timeZone
            )
        )
    }
}
