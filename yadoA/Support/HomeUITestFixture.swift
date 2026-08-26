import Foundation
import SwiftData

/// 仅供 UI 自动化使用的首页跨月份数据夹具。
enum HomeUITestFixture {
    /// 在隔离容器中创建当前月、连续空月、未来数据月和余额调整独占月。
    ///
    /// - Parameter container: UI 自动化专用的内存容器。
    /// - Throws: 夹具流水无法通过现有模型校验或容器保存失败时抛出错误。
    static func seed(in container: ModelContainer) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = Date()
        guard let currentMonth = HomeMonth.from(date: now, calendar: calendar) else {
            return
        }

        let accountID = UUID()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        context.insert(
            Account(
                id: accountID,
                typeRawValue: AccountType.cash.rawValue,
                templateID: nil,
                name: "Home fixture account",
                note: nil,
                lastFourDigits: nil,
                balance: 0,
                currencyCode: "CNY",
                createdAt: now,
                updatedAt: now
            )
        )
        let monthOffsetsAndAmounts: [(Int, String)] = [
            (-4, "18.50"),
            (-2, "32.10"),
            (0, "48.71"),
            (3, "20.00"),
            (6, "75.25")
        ]

        for (index, item) in monthOffsetsAndAmounts.enumerated() {
            guard let month = currentMonth.adding(months: item.0, calendar: calendar) else {
                continue
            }
            let transaction = try AccountTransaction.validatingDiningExpense(
                id: UUID(),
                accountID: accountID,
                amount: Decimal(string: item.1) ?? 0,
                transactionDay: transactionDay(for: month, day: index.isMultiple(of: 2) ? 8 : 13),
                title: index == 2 ? "Home fixture entry" : nil,
                note: index == 2 ? "Home fixture" : ""
            )
            context.insert(transaction)
        }

        if let adjustmentMonth = currentMonth.adding(months: -1, calendar: calendar) {
            context.insert(
                try AccountTransaction.validatingBalanceAdjustment(
                    id: UUID(),
                    accountID: accountID,
                    balanceBefore: 100,
                    balanceAfter: 120,
                    transactionDay: transactionDay(for: adjustmentMonth, day: 6)
                )
            )
        }

        try context.save()
    }

    /// 为记账搜索 UI 流程创建启用、停用、孤立和余额调整边界数据。
    ///
    /// - Parameter container: UI 自动化专用的内存容器。
    /// - Throws: 搜索夹具流水无法通过现有模型校验或容器保存失败时抛出错误。
    static func seedBookkeepingSearch(in container: ModelContainer) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = Date()
        guard let currentMonth = HomeMonth.from(date: now, calendar: calendar) else {
            return
        }

        let activeAccountID = UUID()
        let inactiveAccountID = UUID()
        let orphanAccountID = UUID()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        context.insert(
            Account(
                id: activeAccountID,
                typeRawValue: AccountType.cash.rawValue,
                templateID: nil,
                name: "Search active account",
                note: nil,
                lastFourDigits: nil,
                balance: 100,
                currencyCode: "CNY",
                createdAt: now,
                updatedAt: now
            )
        )
        context.insert(
            Account(
                id: inactiveAccountID,
                typeRawValue: AccountType.cash.rawValue,
                templateID: nil,
                name: "Search inactive account",
                note: nil,
                lastFourDigits: nil,
                balance: 100,
                currencyCode: "CNY",
                createdAt: now,
                updatedAt: now,
                deactivatedAt: now
            )
        )

        let day = { (value: Int) in
            currentMonth.year * 10_000 + currentMonth.month * 100 + value
        }
        context.insert(
            try AccountTransaction.validatingDiningExpense(
                id: UUID(),
                accountID: activeAccountID,
                amount: 30,
                transactionDay: day(8),
                title: "Search legacy title",
                note: "和朋友吃火锅",
                savedAt: now.addingTimeInterval(-3)
            )
        )
        context.insert(
            try AccountTransaction.validatingDiningExpense(
                id: UUID(),
                accountID: inactiveAccountID,
                amount: 30.50,
                transactionDay: day(10),
                note: "Archived meal",
                savedAt: now.addingTimeInterval(-2)
            )
        )
        context.insert(
            try AccountTransaction.validatingDiningExpense(
                id: UUID(),
                accountID: orphanAccountID,
                amount: 40,
                transactionDay: day(12),
                note: "Orphan meal",
                savedAt: now.addingTimeInterval(-1)
            )
        )
        context.insert(
            try AccountTransaction.validatingBalanceAdjustment(
                id: UUID(),
                accountID: activeAccountID,
                balanceBefore: 100,
                balanceAfter: 120,
                transactionDay: day(13),
                note: "和朋友吃火锅",
                savedAt: now
            )
        )

        try context.save()
    }

    /// 把夹具月份和日转换为现有 `YYYYMMDD` 业务日整数。
    private static func transactionDay(for month: HomeMonth, day: Int) -> Int {
        month.year * 10_000 + month.month * 100 + day
    }
}
