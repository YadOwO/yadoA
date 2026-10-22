import Foundation
import SwiftData

/// 账户详情中单条账户流水的展示数据。
struct AccountTransactionHistoryRowPresentation: Identifiable, Equatable {
    /// 流水的稳定标识。
    let id: UUID

    /// 收入与支出可进入统一记账详情；余额调整和转账保持历史快照展示。
    let canOpenBookkeepingDetail: Bool

    /// 是否为转账；转账可以在账户详情里删除并撤回两边余额。
    let isTransfer: Bool

    /// 当前语言环境下的流水类型标题。
    let title: String

    /// 支出、转出使用负向金额，收入、转入带加号，余额调整使用显式带符号差额。
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

/// 账户详情里同一业务日的一组流水。
struct AccountTransactionHistoryDayPresentation: Identifiable, Equatable {
    /// 分组使用的 `YYYYMMDD` 业务日。
    let transactionDay: Int

    /// 当前语言环境下的短日期。
    let formattedDate: String

    /// 当前语言环境下的星期。
    let formattedWeekday: String

    /// 按查询顺序（同日内新的在前）排列的流水行。
    let rows: [AccountTransactionHistoryRowPresentation]

    /// 使用业务日作为 SwiftUI 分组标识。
    var id: Int { transactionDay }
}

/// 账户流水的 SwiftData 查询与展示转换边界。
enum AccountTransactionHistoryPresentation {
    /// 创建只查询目标账户（含转入该账户的转账）、并按业务日和保存时间稳定排序的描述符。
    ///
    /// - Parameter accountID: 当前账户的稳定 UUID。
    /// - Returns: 可供 `@Query` 与真实容器测试共同使用的查询描述符。
    static func descriptor(accountID: UUID) -> FetchDescriptor<AccountTransaction> {
        let targetAccountID = accountID
        return FetchDescriptor(
            predicate: #Predicate<AccountTransaction> { transaction in
                transaction.accountID == targetAccountID
                    || transaction.counterpartAccountID == targetAccountID
            },
            sortBy: AccountTransactionOrdering.sortDescriptors
        )
    }

    /// 将类型化账户流水转换为本地化展示；损坏的字段组合不会伪装成其他类型。
    ///
    /// - Parameters:
    ///   - transaction: 已持久化的类型化账户流水。
    ///   - locale: 标题、金额和日期使用的语言环境。
    ///   - calendar: 提供当前时区的日历，展示时统一使用公历。
    ///   - catalog: 解析分类名称使用的分类目录。
    ///   - accountID: 从哪个账户的角度展示；转账据此区分转出和转入，为空时按转出展示。
    ///   - accountNames: 转账对方账户的展示名称。
    /// - Returns: 可直接渲染到账户详情的流水行；专属字段缺失时返回 `nil`。
    static func row(
        for transaction: AccountTransaction,
        locale: Locale = .current,
        calendar: Calendar = .current,
        catalog: BookkeepingCategoryCatalog = .presets,
        accountID: UUID? = nil,
        accountNames: [UUID: String] = [:]
    ) -> AccountTransactionHistoryRowPresentation? {
        guard let payload = try? transaction.validatedPayload() else { return nil }
        return row(
            for: transaction,
            payload: payload,
            formattedDate: formattedDate(
                transaction.transactionDay,
                locale: locale,
                calendar: calendar
            ),
            locale: locale,
            catalog: catalog,
            accountID: accountID,
            accountNames: accountNames
        )
    }

    /// 把已按业务日倒序排列的流水按日分组，供账户详情逐日展示。
    ///
    /// - Parameters:
    ///   - transactions: `descriptor(accountID:)` 查询出的流水，已按业务日和保存时间排好序。
    ///   - accountID: 当前账户 UUID，决定转账显示为转出还是转入。
    ///   - accountNames: 转账对方账户的展示名称。
    ///   - locale: 标题、金额和日期使用的语言环境。
    ///   - calendar: 提供当前时区的日历，展示时统一使用公历。
    ///   - catalog: 解析分类名称使用的分类目录。
    /// - Returns: 按业务日从新到旧排列的分组；损坏的流水不展示。
    static func days(
        for transactions: [AccountTransaction],
        accountID: UUID,
        accountNames: [UUID: String],
        locale: Locale = .current,
        calendar sourceCalendar: Calendar = .current,
        catalog: BookkeepingCategoryCatalog = .presets
    ) -> [AccountTransactionHistoryDayPresentation] {
        let calendar = TransactionDay.gregorianCalendar(basedOn: sourceCalendar, locale: locale)
        let weekdayFormatter = BookkeepingDateFormatting.formatter(
            template: "EEEE",
            locale: locale,
            calendar: calendar
        )
        var days: [AccountTransactionHistoryDayPresentation] = []
        var currentDay: Int?
        var currentRows: [AccountTransactionHistoryRowPresentation] = []

        func closeCurrentDay() {
            guard let transactionDay = currentDay, !currentRows.isEmpty else { return }
            let date = TransactionDay.date(from: transactionDay, calendar: calendar, locale: locale)
            days.append(
                AccountTransactionHistoryDayPresentation(
                    transactionDay: transactionDay,
                    formattedDate: currentRows[0].formattedDate,
                    formattedWeekday: date.map { weekdayFormatter.string(from: $0) } ?? "",
                    rows: currentRows
                )
            )
        }

        for transaction in transactions {
            guard let presentation = row(
                for: transaction,
                locale: locale,
                calendar: calendar,
                catalog: catalog,
                accountID: accountID,
                accountNames: accountNames
            ) else { continue }
            if transaction.transactionDay != currentDay {
                closeCurrentDay()
                currentDay = transaction.transactionDay
                currentRows = []
            }
            currentRows.append(presentation)
        }
        closeCurrentDay()
        return days
    }

    /// 使用调用方已校验的载荷和已格式化的业务日期生成展示行，供批量投影避免重复校验。
    ///
    /// - Parameters:
    ///   - transaction: 已持久化的类型化账户流水。
    ///   - payload: 由 `validatedPayload()` 解码出的同一笔流水载荷。
    ///   - formattedDate: 该流水业务日的本地化短日期。
    ///   - locale: 标题和金额使用的语言环境。
    ///   - catalog: 解析分类名称使用的分类目录。
    ///   - accountID: 从哪个账户的角度展示；转账据此区分转出和转入，为空时按转出展示。
    ///   - accountNames: 转账对方账户的展示名称。
    /// - Returns: 可直接渲染的流水行。
    static func row(
        for transaction: AccountTransaction,
        payload: AccountTransactionPayload,
        formattedDate: String,
        locale: Locale,
        catalog: BookkeepingCategoryCatalog = .presets,
        accountID: UUID? = nil,
        accountNames: [UUID: String] = [:]
    ) -> AccountTransactionHistoryRowPresentation {
        let title: String
        let formattedAmount: String
        let balanceTransition: String?
        let spokenBalanceTransition: String?
        let canOpenBookkeepingDetail: Bool

        switch payload {
        case let .expense(_, amount):
            canOpenBookkeepingDetail = true
            title = transaction.title
                ?? payload.categoryTitle(locale: locale, catalog: catalog) ?? ""
            formattedAmount = formattedCurrency(-amount, code: transaction.currencyCode, locale: locale)
            balanceTransition = nil
            spokenBalanceTransition = nil

        case let .income(_, amount):
            canOpenBookkeepingDetail = true
            title = transaction.title
                ?? payload.categoryTitle(locale: locale, catalog: catalog) ?? ""
            formattedAmount = formattedSignedCurrency(
                amount,
                code: transaction.currencyCode,
                locale: locale
            )
            balanceTransition = nil
            spokenBalanceTransition = nil

        case let .balanceAdjustment(balanceBefore, balanceAfter, balanceDelta):
            canOpenBookkeepingDetail = false
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

        case let .transfer(toAccountID, amount):
            canOpenBookkeepingDetail = false
            // 同一笔转账在转出、转入两个账户的详情里都出现，按当前账户决定方向。
            let isIncoming = accountID == toAccountID
            let counterpartID = isIncoming ? transaction.accountID : toAccountID
            let counterpartName = accountNames[counterpartID]
                ?? AccountLocalization.string("account.transfer.unknown_account", locale: locale)
            title = AccountLocalization.formatted(
                isIncoming
                    ? "account.detail.history.transfer_in_format"
                    : "account.detail.history.transfer_out_format",
                value: counterpartName,
                locale: locale
            )
            formattedAmount = isIncoming
                ? formattedSignedCurrency(amount, code: transaction.currencyCode, locale: locale)
                : formattedCurrency(-amount, code: transaction.currencyCode, locale: locale)
            balanceTransition = nil
            spokenBalanceTransition = nil
        }

        let spokenParts = [
            title,
            formattedAmount,
            spokenBalanceTransition,
            formattedDate,
            transaction.note
        ].compactMap { $0 }

        let isTransfer: Bool
        if case .transfer = payload {
            isTransfer = true
        } else {
            isTransfer = false
        }

        return AccountTransactionHistoryRowPresentation(
            id: transaction.id,
            canOpenBookkeepingDetail: canOpenBookkeepingDetail,
            isTransfer: isTransfer,
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
    static func formattedDate(
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

        return BookkeepingDateFormatting.shortDate(date, locale: locale, calendar: calendar)
    }
}
