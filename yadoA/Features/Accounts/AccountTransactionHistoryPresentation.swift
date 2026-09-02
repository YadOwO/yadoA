import Foundation
import SwiftData

/// 账户详情中单条账户流水的展示数据。
struct AccountTransactionHistoryRowPresentation: Identifiable, Equatable {
    /// 流水的稳定标识。
    let id: UUID

    /// 当前语言环境下的流水类型标题。
    let title: String

    /// 支出使用负向金额，余额调整使用显式带符号差额。
    let formattedAmount: String

    /// 余额调整的“调整前 → 调整后”关系；支出流水为 `nil`。
    let balanceTransition: String?

    /// 当前语言环境下的公历业务日期。
    let formattedDate: String

    /// 已清理的可选流水备注。
    let note: String?

    /// 包含类型、金额、余额关系、日期和备注的完整播报文本。
    let accessibilityLabel: String
}

/// 账户流水的 SwiftData 查询与展示转换边界。
enum AccountTransactionHistoryPresentation {
    /// 创建只查询目标账户、并按业务日和保存时间稳定排序的描述符。
    ///
    /// - Parameter accountID: 当前账户的稳定 UUID。
    /// - Returns: 可供 `@Query` 与真实容器测试共同使用的查询描述符。
    static func descriptor(accountID: UUID) -> FetchDescriptor<AccountTransaction> {
        let targetAccountID = accountID
        return FetchDescriptor(
            predicate: #Predicate<AccountTransaction> { transaction in
                transaction.accountID == targetAccountID
            },
            sortBy: [
                SortDescriptor(\AccountTransaction.transactionDay, order: .reverse),
                SortDescriptor(\AccountTransaction.savedAt, order: .reverse),
                SortDescriptor(\AccountTransaction.id, order: .forward)
            ]
        )
    }

    /// 将类型化账户流水转换为本地化展示；损坏的字段组合不会伪装成其他类型。
    ///
    /// - Parameters:
    ///   - transaction: 已持久化的类型化账户流水。
    ///   - locale: 标题、金额和日期使用的语言环境。
    ///   - calendar: 提供当前时区的日历，展示时统一使用公历。
    /// - Returns: 可直接渲染到账户详情的流水行；专属字段缺失时返回 `nil`。
    static func row(
        for transaction: AccountTransaction,
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> AccountTransactionHistoryRowPresentation? {
        let title: String
        let formattedAmount: String
        let balanceTransition: String?
        let spokenBalanceTransition: String?
        guard let payload = try? transaction.validatedPayload() else { return nil }

        switch payload {
        case let .expense(category, amount):
            title = transaction.title
                ?? category.localizedTitle(locale: locale)
            formattedAmount = formattedCurrency(-amount, code: transaction.currencyCode, locale: locale)
            balanceTransition = nil
            spokenBalanceTransition = nil

        case let .income(category, amount):
            title = transaction.title
                ?? category.localizedTitle(locale: locale)
            formattedAmount = formattedSignedCurrency(
                amount,
                code: transaction.currencyCode,
                locale: locale
            )
            balanceTransition = nil
            spokenBalanceTransition = nil

        case let .balanceAdjustment(balanceBefore, balanceAfter, balanceDelta):
            title = AccountLocalization.string(
                "account.detail.history.balance_adjustment",
                locale: locale
            )
            formattedAmount = formattedSignedCurrency(
                balanceDelta,
                code: transaction.currencyCode,
                locale: locale
            )
            let formattedBalanceBefore = formattedCurrency(
                balanceBefore,
                code: transaction.currencyCode,
                locale: locale
            )
            let formattedBalanceAfter = formattedCurrency(
                balanceAfter,
                code: transaction.currencyCode,
                locale: locale
            )
            balanceTransition = String(
                format: AccountLocalization.string(
                    "account.detail.history.balance_change_format",
                    locale: locale
                ),
                locale: locale,
                formattedBalanceBefore,
                formattedBalanceAfter
            )
            spokenBalanceTransition = String(
                format: AccountLocalization.string(
                    "account.detail.history.balance_change_accessibility_format",
                    locale: locale
                ),
                locale: locale,
                formattedBalanceBefore,
                formattedBalanceAfter
            )

        }

        let formattedDate = formattedDate(
            transaction.transactionDay,
            locale: locale,
            calendar: calendar
        )
        let spokenParts = [
            title,
            formattedAmount,
            spokenBalanceTransition,
            formattedDate,
            transaction.note
        ].compactMap { $0 }

        return AccountTransactionHistoryRowPresentation(
            id: transaction.id,
            title: title,
            formattedAmount: formattedAmount,
            balanceTransition: balanceTransition,
            formattedDate: formattedDate,
            note: transaction.note,
            accessibilityLabel: spokenParts.joined(separator: ", ")
        )
    }

    /// 使用当前语言环境格式化精确货币值。
    private static func formattedCurrency(
        _ amount: Decimal,
        code: String,
        locale: Locale
    ) -> String {
        amount.formatted(.currency(code: code).locale(locale))
    }

    /// 正数差额显式增加加号，负数沿用货币格式自身的负号。
    private static func formattedSignedCurrency(
        _ amount: Decimal,
        code: String,
        locale: Locale
    ) -> String {
        let formatted = formattedCurrency(amount, code: code, locale: locale)
        return amount > 0 ? "+\(formatted)" : formatted
    }

    /// 把 `YYYYMMDD` 整数转换为当前语言环境下的短日期。
    private static func formattedDate(
        _ transactionDay: Int,
        locale: Locale,
        calendar sourceCalendar: Calendar
    ) -> String {
        let calendar = TransactionDay.gregorianCalendar(
            basedOn: sourceCalendar,
            locale: locale
        )
        guard let date = TransactionDay.date(
            from: transactionDay,
            calendar: calendar,
            locale: locale
        ) else {
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
