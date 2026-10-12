#if DEBUG
import Foundation

/// 仅在隔离 UI 测试参数下使用的备份夹具，替代系统文件选择器的选择结果。
enum BackupImportUITestFixture {
    /// 是否由 UI 自动化显式启用备份恢复夹具。
    static var isEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-testing-in-memory")
            && arguments.contains("--ui-testing-import-fixture")
    }

    /// 写出一份含单个账户和单笔支出的备份文件并返回其地址；未启用夹具时返回 `nil`。
    static func backupFileURL() -> URL? {
        guard isEnabled else { return nil }

        let accountID = UUID()
        let savedAt = Date(timeIntervalSince1970: 1_790_000_000)
        let backup = BackupFile(
            exportedAt: savedAt,
            appVersion: "1.0",
            appBuild: "1",
            accounts: [
                BackupAccount(
                    id: accountID,
                    type: AccountType.cash.rawValue,
                    templateID: nil,
                    name: "Restored account",
                    note: nil,
                    lastFourDigits: nil,
                    balance: "66",
                    currencyCode: "CNY",
                    createdAt: savedAt,
                    updatedAt: savedAt,
                    deactivatedAt: nil
                )
            ],
            transactions: [
                BackupTransaction(
                    id: UUID(),
                    accountID: accountID,
                    type: AccountTransactionType.expense.rawValue,
                    category: ExpenseCategory.dining.rawValue,
                    amount: "34",
                    title: "Restored expense",
                    balanceBefore: nil,
                    balanceAfter: nil,
                    balanceDelta: nil,
                    currencyCode: "CNY",
                    transactionDay: 20260926,
                    note: nil,
                    savedAt: savedAt
                )
            ],
            bookkeepingPreference: BackupBookkeepingPreference(defaultAccountID: accountID)
        )

        let url = FileManager.default.temporaryDirectory
            .appending(path: "ui-testing-import.\(BackupFileType.fileExtension)")
        guard let data = try? BackupFileEncoding.makeEncoder().encode(backup),
              (try? data.write(to: url, options: .atomic)) != nil
        else { return nil }
        return url
    }
}
#endif
