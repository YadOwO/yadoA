#if DEBUG
import Foundation
import SwiftData

/// 仅供 UI 自动化使用的备份提醒夹具：一个本机账本，流水够多、记录得够久、从没备份过。
enum BackupReminderUITestFixture {
    /// 是否由 UI 自动化显式启用备份提醒夹具。
    static var isEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-testing-in-memory")
            && arguments.contains("--ui-testing-backup-reminder-fixture")
    }

    /// 在隔离容器中创建一个现金账户和 20 笔十天前保存的流水，刚好满足提醒卡片的显示条件。
    ///
    /// - Parameter container: UI 自动化专用的内存容器。
    /// - Throws: 夹具流水无法通过现有模型校验或容器保存失败时抛出错误。
    static func seed(in container: ModelContainer) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = Date()
        let accountID = UUID()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        context.insert(
            Account(
                id: accountID,
                typeRawValue: AccountType.cash.rawValue,
                templateID: nil,
                name: "Backup reminder account",
                note: nil,
                lastFourDigits: nil,
                balance: 0,
                currencyCode: BookkeepingCurrency.code,
                createdAt: now,
                updatedAt: now
            )
        )
        for index in 0..<BackupReminderPolicy.minimumTransactionCount {
            // 保存时间都在十天以前，逐笔错开一秒，保证按保存时间排序稳定
            let savedAt = now.addingTimeInterval(-10 * 86_400 + Double(index))
            let components = calendar.dateComponents([.year, .month, .day], from: savedAt)
            let transactionDay = (components.year ?? 1970) * 10_000
                + (components.month ?? 1) * 100
                + (components.day ?? 1)
            context.insert(
                try AccountTransaction.validatingDiningExpense(
                    id: UUID(),
                    accountID: accountID,
                    amount: 10,
                    transactionDay: transactionDay,
                    note: "Backup reminder fixture \(index)",
                    savedAt: savedAt
                )
            )
        }
        context.insert(BookkeepingPreference(defaultAccountID: accountID))
        try context.alignOpeningBalancesWithBalances()
        try context.save()
    }
}
#endif
