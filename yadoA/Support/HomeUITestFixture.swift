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

        let context = ModelContext(container)
        context.autosaveEnabled = false
        let accountID = UUID()
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

    /// 把夹具月份和日转换为现有 `YYYYMMDD` 业务日整数。
    private static func transactionDay(for month: HomeMonth, day: Int) -> Int {
        month.year * 10_000 + month.month * 100 + day
    }
}
