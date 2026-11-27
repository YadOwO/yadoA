import Foundation
import SwiftData
import Testing
@testable import yadoA

@Suite("本地数据清除服务", .serialized)
@MainActor
struct LocalDataResetServiceTests {
    /// 构造含账户、支出流水和默认偏好的夹具。
    private func makeSeededContainer() throws -> AccountDataContainer {
        let container = try AccountDataContainer.inMemory()
        let accountID = UUID()
        try LocalAccountRepository(container: container.modelContainer, defaults: LedgerTestDefaults.cny).save(
            AccountDraft(id: accountID, accountType: .cash, name: "现金", amountText: "10"),
            locale: Locale(identifier: "en_US")
        )
        try LocalExpenseRepository(container: container.modelContainer).save(
            DiningExpenseDraft(
                id: UUID(),
                accountID: accountID,
                entryType: .expense,
                expenseCategoryKey: ExpenseCategory.dining.rawValue,
                amountText: "1",
                transactionDay: 20260902
            ),
            savedAt: Date(timeIntervalSince1970: 100)
        )
        return container
    }

    /// 统计容器中三类业务记录的数量。
    private func recordCounts(in container: AccountDataContainer) throws -> [Int] {
        let context = container.modelContainer.makeManualSaveContext()
        return [
            try context.fetchCount(FetchDescriptor<Account>()),
            try context.fetchCount(FetchDescriptor<AccountTransaction>()),
            try context.fetchCount(FetchDescriptor<BookkeepingPreference>()),
        ]
    }

    @Test("清除后账户、流水和偏好全部为空，且可以重复执行")
    func eraseAllRemovesEveryBusinessRecord() throws {
        let container = try makeSeededContainer()
        let before = try recordCounts(in: container)
        #expect(before[0] == 1)
        #expect(before[1] == 1)

        let service = LocalDataResetService(container: container.modelContainer)
        try service.eraseAll()
        #expect(try recordCounts(in: container) == [0, 0, 0])

        try service.eraseAll()
        #expect(try recordCounts(in: container) == [0, 0, 0])
    }

    @Test("只有订阅、没有账户和流水时，也算有数据可清除")
    func subscriptionsCountAsData() throws {
        let container = try AccountDataContainer.inMemory()
        let service = LocalDataResetService(container: container.modelContainer)
        #expect(try service.hasData() == false)

        let context = ModelContext(container.modelContainer)
        context.insert(UserSubscription(
            id: UUID(), name: "Netflix", amount: 68, frequencyRawValue: RecurringFrequency.monthly.rawValue,
            anchorDay: 20261028, categoryRawValue: "media", channelRawValue: "appStore", statusRawValue: "active",
            accessEndDay: nil, reminderDaysBefore: nil, note: nil, recurringRuleID: nil, createdAt: .now, updatedAt: .now
        ))
        try context.save()

        #expect(try service.hasData())
    }

    @Test("保存失败时回滚，现有数据保持原样")
    func saveFailureLeavesDataUntouched() throws {
        let container = try makeSeededContainer()
        let before = try recordCounts(in: container)
        struct InjectedFailure: Error {}
        let service = LocalDataResetService(
            container: container.modelContainer,
            beforeSave: { throw InjectedFailure() }
        )

        #expect(throws: LocalDataResetError.resetFailed) {
            try service.eraseAll()
        }
        #expect(try recordCounts(in: container) == before)
    }

    /// 创建只给一个用例使用的独立 UserDefaults 套件。
    private func makeIsolatedDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "backup-reminder-reset-\(UUID())"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }

    @Test("清除成功后，备份提醒的两个记录一起清掉")
    func eraseAllClearsBackupReminderKeys() throws {
        let container = try makeSeededContainer()
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        BackupReminderStore.recordBackup(at: Date(timeIntervalSince1970: 1_000), in: defaults)
        BackupReminderStore.snooze(from: Date(timeIntervalSince1970: 2_000), in: defaults)
        #expect(BackupReminderStore.lastBackupAt(in: defaults) != nil)
        #expect(BackupReminderStore.snoozedUntil(in: defaults) != nil)

        try LocalDataResetService(container: container.modelContainer, defaults: defaults).eraseAll()

        #expect(BackupReminderStore.lastBackupAt(in: defaults) == nil)
        #expect(BackupReminderStore.snoozedUntil(in: defaults) == nil)
    }

    @Test("保存失败时，备份提醒的两个记录保持原值")
    func failedEraseKeepsBackupReminderKeys() throws {
        let container = try makeSeededContainer()
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let backupAt = Date(timeIntervalSince1970: 1_000)
        let snoozeStart = Date(timeIntervalSince1970: 2_000)
        BackupReminderStore.recordBackup(at: backupAt, in: defaults)
        BackupReminderStore.snooze(from: snoozeStart, in: defaults)
        struct InjectedFailure: Error {}
        let service = LocalDataResetService(
            container: container.modelContainer,
            beforeSave: { throw InjectedFailure() },
            defaults: defaults
        )

        #expect(throws: LocalDataResetError.resetFailed) {
            try service.eraseAll()
        }

        #expect(BackupReminderStore.lastBackupAt(in: defaults) == backupAt)
        #expect(
            BackupReminderStore.snoozedUntil(in: defaults)
                == snoozeStart.addingTimeInterval(BackupReminderPolicy.snoozeInterval)
        )
    }
}
