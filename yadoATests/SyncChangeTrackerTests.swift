import Foundation
import SwiftData
import Testing
@testable import yadoA

@Suite("同步台账自动登记", .serialized)
@MainActor
struct SyncChangeTrackerTests {
    @Test("新增账户生成一条待上传台账，同步内容不含余额")
    func insertingAccountCreatesPendingEntry() throws {
        try withSyncState(boundUserID: nil) {
            let container = try AccountDataContainer.inMemory().modelContainer
            let accountID = UUID()
            try saveAccount(id: accountID, in: container)

            let entry = try #require(try ledgerEntry(.account, accountID, in: container))
            #expect(entry.hasPendingChanges)
            #expect(entry.revision == 1)
            #expect(!entry.isTombstone)
            #expect(entry.modifiedAt > .distantPast)

            let account = try #require(try container.makeManualSaveContext().account(id: accountID))
            let record = try #require(try SyncPayloadCoder.record(for: account))
            let payload = try #require(try JSONSerialization.jsonObject(with: record.payload) as? [String: Any])
            #expect(payload["balance"] == nil)
            #expect(payload["openingBalance"] as? String == "100")
            #expect(entry.payloadHash == record.payloadHash)
        }
    }

    @Test("记账只改了账户余额缓存时，不把账户登记为修改")
    func balanceOnlyChangeIsNotRecorded() throws {
        try withSyncState(boundUserID: nil) {
            let container = try AccountDataContainer.inMemory().modelContainer
            let accountID = UUID()
            try saveAccount(id: accountID, in: container)
            let draft = DiningExpenseDraft(accountID: accountID, amountText: "30", transactionDay: 20261020)

            try LocalExpenseRepository(container: container).save(draft)

            let accountEntry = try #require(try ledgerEntry(.account, accountID, in: container))
            #expect(accountEntry.revision == 1)
            let transactionEntry = try #require(try ledgerEntry(.transaction, draft.id, in: container))
            #expect(transactionEntry.revision == 1)
        }
    }

    @Test("修改流水时登记新版本，内容相同的重复保存不登记")
    func updateRecordsOnlyRealChanges() throws {
        try withSyncState(boundUserID: nil) {
            let container = try AccountDataContainer.inMemory().modelContainer
            let accountID = UUID()
            try saveAccount(id: accountID, in: container)
            let repository = LocalExpenseRepository(container: container)
            let draft = DiningExpenseDraft(accountID: accountID, amountText: "30", transactionDay: 20261020)
            try repository.save(draft)
            let edit = DiningExpenseEditDraft(
                id: draft.id, accountID: accountID, title: "午饭", amountText: "45", transactionDay: 20261020
            )

            try repository.update(edit)
            try repository.update(edit)

            let entry = try #require(try ledgerEntry(.transaction, draft.id, in: container))
            #expect(entry.revision == 2)
            #expect(entry.hasPendingChanges)
        }
    }

    @Test("未绑定账号时删除不保留墓碑")
    func deletionWithoutBindingDropsEntry() throws {
        try withSyncState(boundUserID: nil) {
            let container = try AccountDataContainer.inMemory().modelContainer
            let accountID = UUID()
            try saveAccount(id: accountID, in: container)
            let draft = DiningExpenseDraft(accountID: accountID, amountText: "30", transactionDay: 20261020)
            let repository = LocalExpenseRepository(container: container)
            try repository.save(draft)

            try repository.delete(id: draft.id)

            #expect(try ledgerEntry(.transaction, draft.id, in: container) == nil)
        }
    }

    @Test("已绑定账号时删除留下待上传的墓碑")
    func deletionWithBindingKeepsTombstone() throws {
        try withSyncState(boundUserID: "user-1") {
            let container = try AccountDataContainer.inMemory().modelContainer
            let accountID = UUID()
            try saveAccount(id: accountID, in: container)
            let draft = DiningExpenseDraft(accountID: accountID, amountText: "30", transactionDay: 20261020)
            let repository = LocalExpenseRepository(container: container)
            try repository.save(draft)

            try repository.delete(id: draft.id)

            let entry = try #require(try ledgerEntry(.transaction, draft.id, in: container))
            #expect(entry.isTombstone)
            #expect(entry.payloadHash.isEmpty)
            #expect(entry.revision == 2)
            #expect(entry.hasPendingChanges)
        }
    }

    @Test("预置分类的台账修改时间为 distantPast，用户调整后变为当前时间")
    func pristinePresetsUseDistantPast() throws {
        try withSyncState(boundUserID: nil) {
            let container = try AccountDataContainer.inMemory().modelContainer
            let repository = LocalCategoryRepository(container: container)
            try repository.ensurePresets()
            let travelID = BookkeepingCategoryKey.presetID(direction: .expense, key: ExpenseCategory.travel.rawValue)
            let entry = try #require(try ledgerEntry(.category, travelID, in: container))
            #expect(entry.modifiedAt == .distantPast)

            var keys = ExpenseCategory.allCases.map(\.rawValue)
            keys.swapAt(0, keys.firstIndex(of: ExpenseCategory.travel.rawValue)!)
            try repository.reorder(keys, direction: .expense)

            let updated = try #require(try ledgerEntry(.category, travelID, in: container))
            #expect(updated.modifiedAt > .distantPast)
            #expect(updated.revision == 2)
        }
    }

    @Test("自动创建的空默认偏好记为 distantPast，指向账户后变为当前时间")
    func autoCreatedPreferenceUsesDistantPast() throws {
        try withSyncState(boundUserID: nil) {
            let container = try AccountDataContainer.inMemory().modelContainer
            let repository = LocalAccountRepository(container: container)
            let preferenceID = BookkeepingPreference.singletonID
            // 投资账户不能作为默认账户，保存时只会自动创建一个空的偏好单例。
            try repository.save(
                AccountDraft(
                    id: UUID(),
                    accountType: .investment,
                    template: AccountType.investment.requiresTemplateSelection
                        ? AccountType.investment.templates.first
                        : nil,
                    name: "投资",
                    amountText: "100"
                ),
                locale: Locale(identifier: "en_US")
            )

            let entry = try #require(try ledgerEntry(.preference, preferenceID, in: container))
            #expect(entry.modifiedAt == .distantPast)

            try saveAccount(id: UUID(), in: container)

            let updated = try #require(try ledgerEntry(.preference, preferenceID, in: container))
            #expect(updated.modifiedAt > .distantPast)
            #expect(updated.revision == 2)
        }
    }

    @Test("导入备份里明确的「无默认」按当前时间登记，不当作自动创建")
    func importedEmptyPreferenceUsesCurrentTime() throws {
        try withSyncState(boundUserID: nil) {
            let container = try AccountDataContainer.inMemory().modelContainer
            let backup = BackupFile(
                exportedAt: .now,
                appVersion: "1.0",
                appBuild: "1",
                accounts: [],
                transactions: [],
                bookkeepingPreference: BackupBookkeepingPreference(defaultAccountID: nil)
            )

            try BackupImportService(container: container)
                .restore(BackupImportPlan(backup: backup, replacesExistingData: false))

            let entry = try #require(
                try ledgerEntry(.preference, BookkeepingPreference.singletonID, in: container)
            )
            #expect(entry.modifiedAt > .distantPast)
        }
    }

    @Test("导入时补齐的预置分类按当前时间登记，不当作自动创建")
    func importedPresetsUseCurrentTime() throws {
        try withSyncState(boundUserID: nil) {
            let container = try AccountDataContainer.inMemory().modelContainer
            let backup = BackupFile(
                exportedAt: .now,
                appVersion: "1.0",
                appBuild: "1",
                accounts: [],
                transactions: [],
                bookkeepingPreference: nil
            )

            try BackupImportService(container: container)
                .restore(BackupImportPlan(backup: backup, replacesExistingData: false))

            let travelID = BookkeepingCategoryKey.presetID(direction: .expense, key: ExpenseCategory.travel.rawValue)
            let entry = try #require(try ledgerEntry(.category, travelID, in: container))
            #expect(entry.modifiedAt > .distantPast)
        }
    }

    @Test("不登记的保存不产生台账")
    func untrackedSaveSkipsLedger() throws {
        try withSyncState(boundUserID: nil) {
            let container = try AccountDataContainer.inMemory().modelContainer
            let context = container.makeManualSaveContext()
            context.insert(BookkeepingPreference(defaultAccountID: nil))

            try context.saveOrRollback(tracksSyncChanges: false)

            #expect(try ModelContext(container).fetchCount(FetchDescriptor<SyncLedgerEntry>()) == 0)
        }
    }

    @Test("保存失败时台账随业务修改一起回滚")
    func ledgerRollsBackWithFailedSave() throws {
        try withSyncState(boundUserID: nil) {
            struct InjectedFailure: Error {}
            let container = try AccountDataContainer.inMemory().modelContainer
            let accountID = UUID()
            try saveAccount(id: accountID, in: container)
            let draft = DiningExpenseDraft(accountID: accountID, amountText: "30", transactionDay: 20261020)

            #expect(throws: InjectedFailure.self) {
                try LocalExpenseRepository(container: container, beforeSave: { throw InjectedFailure() }).save(draft)
            }

            #expect(try ledgerEntry(.transaction, draft.id, in: container) == nil)
        }
    }

    @Test("清空本地数据时同时清空台账，只剩重新补回的预置分类")
    func eraseAllClearsLedger() throws {
        try withSyncState(boundUserID: "user-1") {
            let container = try AccountDataContainer.inMemory().modelContainer
            let accountID = UUID()
            try saveAccount(id: accountID, in: container)

            try LocalDataResetService(container: container).eraseAll()

            let entries = try ModelContext(container).fetch(FetchDescriptor<SyncLedgerEntry>())
            #expect(!entries.isEmpty)
            #expect(entries.allSatisfy { $0.entityType == .category && !$0.isTombstone })
        }
    }

    @Test("生产代码只通过 saveOrRollback 保存，保证修改都会被同步台账登记")
    func productionCodeSavesOnlyThroughSaveOrRollback() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "yadoA")
        // 这些文件只构造 UI 测试夹具或设计预览数据，不属于用户写入路径。
        let allowedFiles: Set<String> = [
            "ModelContext+Finance.swift",
            "HomeUITestFixture.swift",
            "HomeDesignPreview.swift",
        ]
        let enumerator = try #require(FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard !allowedFiles.contains(url.lastPathComponent) else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            if source.contains(".save()") {
                offenders.append(url.lastPathComponent)
            }
        }

        #expect(offenders.isEmpty, "直接调用 save() 的文件：\(offenders)")
    }

    // MARK: - 工具

    /// 在独立的同步状态存储中执行测试，结束后恢复原存储，避免读写真实的 UserDefaults。
    ///
    /// - Parameters:
    ///   - boundUserID: 测试期间本机绑定的用户；为 `nil` 表示未绑定。
    ///   - body: 测试主体。
    private func withSyncState(boundUserID: String?, _ body: () throws -> Void) throws {
        let suiteName = "SyncChangeTrackerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let originalDefaults = SyncChangeTracker.defaults
        SyncChangeTracker.defaults = defaults
        defer {
            SyncChangeTracker.defaults = originalDefaults
            defaults.removePersistentDomain(forName: suiteName)
        }
        var state = SyncState.load(from: defaults)
        state.boundUserID = boundUserID
        state.save(to: defaults)
        try body()
    }

    /// 通过账户仓库保存一个期初余额为 100 的现金账户。
    private func saveAccount(id: UUID, in container: ModelContainer) throws {
        try LocalAccountRepository(container: container).save(
            AccountDraft(id: id, accountType: .cash, template: nil, name: "现金", amountText: "100"),
            locale: Locale(identifier: "en_US")
        )
    }

    /// 使用独立 context 读取一条台账。
    private func ledgerEntry(
        _ entityType: SyncEntityType,
        _ recordID: UUID,
        in container: ModelContainer
    ) throws -> SyncLedgerEntry? {
        let key = SyncLedgerEntry.key(entityType: entityType, recordID: recordID)
        var descriptor = FetchDescriptor<SyncLedgerEntry>(
            predicate: #Predicate<SyncLedgerEntry> { entry in entry.key == key }
        )
        descriptor.fetchLimit = 1
        return try ModelContext(container).fetch(descriptor).first
    }
}
