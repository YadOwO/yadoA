import Foundation
import SwiftData
import Testing
@testable import yadoA

@Suite("备份导出服务", .serialized)
@MainActor
struct BackupExportServiceTests {
    /// 每个用例独享的输出目录，避免并行断言“目录为空”互相污染。
    private func makeExportDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "backup-export-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// 构造覆盖启用/停用账户、三类流水与默认偏好的完整夹具。
    private func makeSeededContainer() throws -> (AccountDataContainer, UUID) {
        let container = try AccountDataContainer.inMemory()
        let accountRepository = LocalAccountRepository(container: container.modelContainer)
        let activeID = UUID()
        let deactivatedID = UUID()

        try accountRepository.save(
            AccountDraft(id: activeID, accountType: .cash, name: "现金", amountText: "10"),
            locale: Locale(identifier: "en_US")
        )
        try accountRepository.save(
            AccountDraft(
                id: deactivatedID,
                accountType: .creditCard,
                template: AccountTemplate.creditInstitutions[0],
                name: "信用卡",
                amountText: "0"
            ),
            locale: Locale(identifier: "en_US")
        )

        try LocalExpenseRepository(container: container.modelContainer).save(
            DiningExpenseDraft(
                id: UUID(),
                accountID: activeID,
                entryType: .expense,
                category: .dining,
                amountText: "1",
                transactionDay: 20260902
            ),
            savedAt: Date(timeIntervalSince1970: 100)
        )
        try LocalExpenseRepository(container: container.modelContainer).save(
            DiningExpenseDraft(
                id: UUID(),
                accountID: activeID,
                entryType: .income,
                incomeCategory: .salary,
                amountText: "100",
                transactionDay: 20260901
            ),
            savedAt: Date(timeIntervalSince1970: 200)
        )
        _ = try LocalBalanceAdjustmentRepository(container: container.modelContainer).save(
            BalanceAdjustmentDraft(id: UUID(), accountID: activeID, amountText: "200"),
            now: Date(timeIntervalSince1970: 300)
        )

        // 停用零余额信用卡账户，保留其 UUID 与生命周期状态。
        try accountRepository.dispose(
            AccountDisposalExpectation(
                accountID: deactivatedID,
                action: .deactivate,
                expectedDefaultAccountID: activeID,
                replacementAccountID: nil,
                allowsNoDefault: false
            ),
            now: Date(timeIntervalSince1970: 400)
        )
        return (container, activeID)
    }

    @Test("完整导出：停用账户、三类流水、UUID 与偏好全部保留")
    func fullExportPreservesEverything() throws {
        let (container, defaultAccountID) = try makeSeededContainer()
        let service = BackupExportService(container: container.modelContainer)

        let fileURL = try service.export()
        let backup = try BackupFileEncoding.decode(Data(contentsOf: fileURL))

        #expect(backup.accounts.count == 2)
        #expect(backup.transactions.count == 3)
        #expect(backup.appVersion.isEmpty == false)
        #expect(backup.appBuild.isEmpty == false)
        #expect(backup.bookkeepingPreference?.defaultAccountID == defaultAccountID)

        let deactivated = try #require(
            backup.accounts.first { $0.type == "creditCard" }
        )
        #expect(deactivated.deactivatedAt == Date(timeIntervalSince1970: 400))

        let types = Set(backup.transactions.map(\.type))
        #expect(types == ["diningExpense", "income", "balanceAdjustment"])
        let income = try #require(backup.transactions.first { $0.type == "income" })
        #expect(income.category == "salary")
        #expect(income.amount == "100")
        #expect(backup.transactions.allSatisfy { transaction in
            backup.accounts.contains { $0.id == transaction.accountID }
        })

        let adjustment = try #require(
            backup.transactions.first { $0.type == "balanceAdjustment" }
        )
        #expect(adjustment.balanceBefore == "109")
        #expect(adjustment.balanceAfter == "200")
        #expect(adjustment.balanceDelta == "91")
    }

    @Test("导出文件结构只含业务字段，不含派生数据")
    func exportContainsOnlyBusinessFields() throws {
        let (container, _) = try makeSeededContainer()
        let service = BackupExportService(container: container.modelContainer)

        let fileURL = try service.export()
        let jsonObject = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fileURL)
        ) as! [String: Any]

        let accountKeys = Set(
            (jsonObject["accounts"] as! [[String: Any]])[0].keys
        )
        #expect(
            accountKeys == [
                "id", "type", "templateID", "name", "note", "lastFourDigits",
                "balance", "currencyCode", "createdAt", "updatedAt", "deactivatedAt",
            ]
        )
        let transactionKeys = Set(
            (jsonObject["transactions"] as! [[String: Any]])[0].keys
        )
        #expect(
            transactionKeys == [
                "id", "accountID", "type", "category", "amount", "title",
                "balanceBefore", "balanceAfter", "balanceDelta", "currencyCode",
                "transactionDay", "note", "savedAt",
            ]
        )
    }

    @Test("损坏流水使整次导出失败，且不留下任何文件")
    func corruptRecordFailsEntireExport() throws {
        let (container, _) = try makeSeededContainer()
        let exportDirectory = makeExportDirectory()
        let service = BackupExportService(
            container: container.modelContainer,
            exportDirectory: exportDirectory
        )

        // 指定初始化器私有，插入后改写持久化字段是注入损坏的唯一路径。
        let context = ModelContext(container.modelContainer)
        context.autosaveEnabled = false
        let transactions = try context.fetch(FetchDescriptor<AccountTransaction>())
        let victim = try #require(transactions.first)
        victim.typeRawValue = "corruptedType"
        try context.save()

        #expect(throws: BackupExportError.recordUnreadable(victim.id)) {
            try service.export()
        }

        let residue = (try? FileManager.default.contentsOfDirectory(
            at: exportDirectory, includingPropertiesForKeys: nil
        )) ?? []
        #expect(residue.isEmpty)
    }

    @Test("空库导出成功：空数组且偏好记为无记录")
    func emptyStoreExportsValidBackup() throws {
        let container = try AccountDataContainer.inMemory()
        let exportDirectory = makeExportDirectory()
        let service = BackupExportService(
            container: container.modelContainer,
            exportDirectory: exportDirectory
        )

        let fileURL = try service.export()
        let backup = try BackupFileEncoding.decode(Data(contentsOf: fileURL))

        #expect(backup.accounts.isEmpty)
        #expect(backup.transactions.isEmpty)
        #expect(backup.bookkeepingPreference == nil)
    }

    @Test("失效默认指针按原值导出且导出成功")
    func danglingDefaultPointerExportsRaw() throws {
        let container = try AccountDataContainer.inMemory()
        let danglingID = UUID()
        let context = ModelContext(container.modelContainer)
        context.autosaveEnabled = false
        context.insert(BookkeepingPreference(defaultAccountID: danglingID))
        try context.save()

        let service = BackupExportService(container: container.modelContainer)
        let fileURL = try service.export()
        let backup = try BackupFileEncoding.decode(Data(contentsOf: fileURL))

        #expect(backup.bookkeepingPreference?.defaultAccountID == danglingID)
    }

    @Test("非 canonical 偏好行被忽略，不进入备份")
    func nonCanonicalPreferenceIgnored() throws {
        let container = try AccountDataContainer.inMemory()
        let context = ModelContext(container.modelContainer)
        context.autosaveEnabled = false
        context.insert(BookkeepingPreference(id: UUID(), defaultAccountID: UUID()))
        try context.save()

        let service = BackupExportService(container: container.modelContainer)
        let fileURL = try service.export()
        let backup = try BackupFileEncoding.decode(Data(contentsOf: fileURL))

        #expect(backup.bookkeepingPreference == nil)
    }

    @Test("固定时间源生成精确文件名；同日不同时刻文件名可区分")
    func deterministicDistinctFilenames() throws {
        let container = try AccountDataContainer.inMemory()
        let exportDirectory = makeExportDirectory()
        let morningService = BackupExportService(
            container: container.modelContainer,
            exportDirectory: exportDirectory,
            now: { Date(timeIntervalSince1970: 0) }
        )

        let morningURL = try morningService.export()
        #expect(morningURL.lastPathComponent == "yadoA-backup-1970-01-01-0000.yadoabackup")

        let laterService = BackupExportService(
            container: container.modelContainer,
            exportDirectory: exportDirectory,
            now: { Date(timeIntervalSince1970: 300) }
        )
        let laterURL = try laterService.export()
        #expect(laterURL.lastPathComponent == "yadoA-backup-1970-01-01-0005.yadoabackup")
    }

    @Test("写入前故障点抛错时导出失败且无文件残留")
    func beforeWriteFailureLeavesNoFile() throws {
        let container = try AccountDataContainer.inMemory()
        let exportDirectory = makeExportDirectory()
        struct InjectedFailure: Error {}
        let service = BackupExportService(
            container: container.modelContainer,
            exportDirectory: exportDirectory,
            beforeWrite: { throw InjectedFailure() }
        )

        #expect(throws: BackupExportError.writeFailed) {
            try service.export()
        }

        let residue = (try? FileManager.default.contentsOfDirectory(
            at: exportDirectory, includingPropertiesForKeys: nil
        )) ?? []
        #expect(residue.isEmpty)
    }

    @Test("导出开始与启动清扫都会删除残留文件")
    func sweepRemovesStaleFiles() throws {
        let container = try AccountDataContainer.inMemory()
        let exportDirectory = makeExportDirectory()
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        let staleURL = exportDirectory.appending(path: "yadoA-backup-stale.yadoabackup")
        try Data("stale".utf8).write(to: staleURL)

        let service = BackupExportService(
            container: container.modelContainer,
            exportDirectory: exportDirectory
        )
        service.sweepStaleExports()
        #expect(FileManager.default.fileExists(atPath: staleURL.path) == false)

        try Data("stale".utf8).write(to: staleURL)
        _ = try service.export()
        #expect(FileManager.default.fileExists(atPath: staleURL.path) == false)
    }

    @Test("关闭分享后删除导出文件")
    func removeExportedFileDeletes() throws {
        let container = try AccountDataContainer.inMemory()
        let service = BackupExportService(container: container.modelContainer)

        let fileURL = try service.export()
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        service.removeExportedFile(at: fileURL)
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
    }
}
