import Foundation
import SwiftData
import Testing
@testable import yadoA

@Suite("Account 持久化边界", .serialized)
@MainActor
struct AccountPersistenceTests {
    @Test("内存存储显式保存并拒绝重复 UUID")
    func savesAndRejectsDuplicateID() throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let repository = LocalAccountRepository(container: dataContainer.modelContainer)
        let id = UUID()
        let draft = AccountDraft(
            id: id,
            accountType: .cash,
            name: "现金",
            amountText: "40"
        )

        try repository.save(draft, locale: Locale(identifier: "en_US"))
        #expect(try repository.accounts().map(\.id) == [id])
        #expect(throws: AccountRepositoryError.duplicateID(id)) {
            try repository.save(draft, locale: Locale(identifier: "en_US"))
        }
        #expect(try repository.accounts().map(\.id) == [id])
    }

    @Test("编辑账户仅更新资料并保留余额、类型和创建时间")
    func updatesProfileWithoutChangingFinancialIdentity() throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let repository = LocalAccountRepository(container: dataContainer.modelContainer)
        let id = UUID()
        let createdAt = Date(timeIntervalSince1970: 100)
        let updatedAt = Date(timeIntervalSince1970: 200)
        try repository.save(
            AccountDraft(
                id: id,
                accountType: .cash,
                name: "现金",
                note: "旧备注",
                amountText: "40"
            ),
            now: createdAt
        )

        let original = try #require(try repository.account(id: id))
        var edit = AccountEditDraft(account: original)
        edit.name = "  旅行现金  "
        edit.note = "  备用  "
        edit.lastFourDigits = " 8x765 "

        try repository.update(edit, now: updatedAt)

        let account = try #require(try repository.account(id: id))
        #expect(account.name == "旅行现金")
        #expect(account.note == "备用")
        #expect(account.lastFourDigits == "8765")
        #expect(account.balance == 40)
        #expect(account.typeRawValue == AccountType.cash.rawValue)
        #expect(account.createdAt == createdAt)
        #expect(account.updatedAt == updatedAt)
    }

    @Test("编辑保存失败会回滚资料并支持同一草稿重试")
    func failedUpdateRollsBackAndRetrySucceeds() throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let seedRepository = LocalAccountRepository(container: dataContainer.modelContainer)
        let id = UUID()
        try seedRepository.save(
            AccountDraft(
                id: id,
                accountType: .cash,
                name: "现金",
                amountText: "40"
            )
        )

        var shouldFail = true
        let repository = LocalAccountRepository(
            container: dataContainer.modelContainer,
            beforeSave: {
                if shouldFail { throw InjectedSaveFailure() }
            }
        )
        var edit = AccountEditDraft(account: try #require(try repository.account(id: id)))
        edit.name = "旅行现金"

        #expect(throws: InjectedSaveFailure.self) {
            try repository.update(edit)
        }
        #expect(try repository.account(id: id)?.name == "现金")

        shouldFail = false
        try repository.update(edit)
        #expect(try repository.account(id: id)?.name == "旅行现金")
    }

    @Test("保存失败会回滚，使用同一草稿重试只生成一条记录")
    func failedSaveRollsBackAndRetryDoesNotDuplicate() throws {
        let dataContainer = try AccountDataContainer.inMemory()
        var shouldFail = true
        let repository = LocalAccountRepository(
            container: dataContainer.modelContainer,
            beforeSave: {
                if shouldFail { throw InjectedSaveFailure() }
            }
        )
        let draft = AccountDraft(
            id: UUID(),
            accountType: .creditCard,
            template: AccountTemplate.creditInstitutions[0],
            name: "信用账户",
            amountText: "2800"
        )

        #expect(throws: InjectedSaveFailure.self) {
            try repository.save(draft, locale: Locale(identifier: "en_US"))
        }
        #expect(try repository.accounts().isEmpty)

        shouldFail = false
        try repository.save(draft, locale: Locale(identifier: "en_US"))

        #expect(try repository.accounts().map(\.id) == [draft.id])
    }

    @Test("失败插入不会被自动保存机会变成幽灵记录")
    func failedInsertCannotAutosave() throws {
        let storeURL = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
        let dataContainer = try AccountDataContainer.fileBacked(storeURL: storeURL)
        let repository = LocalAccountRepository(
            container: dataContainer.modelContainer,
            beforeSave: { throw InjectedSaveFailure() }
        )
        let draft = AccountDraft(
            accountType: .cash,
            name: "不应保存",
            amountText: "10"
        )

        #expect(repository.modelContext.autosaveEnabled == false)
        #expect(throws: InjectedSaveFailure.self) {
            try repository.save(draft, locale: Locale(identifier: "en_US"))
        }
        #expect(try repository.accounts().isEmpty)

        let reopened = try AccountDataContainer.fileBacked(storeURL: storeURL)
        let reopenedRepository = LocalAccountRepository(container: reopened.modelContainer)
        #expect(try reopenedRepository.accounts().isEmpty)
    }

    @Test("文件容器重建后保留全部字段")
    func fileContainerPersistsAfterReopen() throws {
        let storeURL = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
        let id = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_786_435_400)
        let draft = AccountDraft(
            id: id,
            accountType: .debitCard,
            template: AccountTemplate.banks(for: .debitCard)[1],
            name: "  日常卡  ",
            note: "  生活费  ",
            lastFourDigits: " 8x765 ",
            amountText: "1234.56"
        )

        do {
            let dataContainer = try AccountDataContainer.fileBacked(storeURL: storeURL)
            let repository = LocalAccountRepository(container: dataContainer.modelContainer)
            try repository.save(
                draft,
                locale: Locale(identifier: "en_US"),
                now: timestamp
            )
        }

        let reopened = try AccountDataContainer.fileBacked(storeURL: storeURL)
        let repository = LocalAccountRepository(container: reopened.modelContainer)
        let account = try #require(try repository.account(id: id))

        #expect(account.typeRawValue == AccountType.debitCard.rawValue)
        #expect(account.templateID == draft.template?.id)
        #expect(account.name == "日常卡")
        #expect(account.note == "生活费")
        #expect(account.lastFourDigits == "8765")
        #expect(account.balance == Decimal(string: "1234.56"))
        #expect(account.currencyCode == "CNY")
        #expect(account.createdAt == timestamp)
        #expect(account.updatedAt == timestamp)
    }

    @Test("生产存储与内存存储必须显式区分")
    func storageKindsAreExplicit() throws {
        let storeURL = temporaryStoreURL()
        let fileContainer = try AccountDataContainer.fileBacked(storeURL: storeURL)
        let memoryContainer = try AccountDataContainer.inMemory()

        #expect(fileContainer.storage == .file(storeURL))
        #expect(memoryContainer.storage == .inMemory)
    }

    @Test("重复初始化失败保留已有文件并维持阻断状态")
    func repeatedBootstrapFailurePreservesStore() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appending(path: "accounts.store")
        let sentinel = Data("existing-store".utf8)
        try sentinel.write(to: storeURL)
        var attempts = 0
        let bootstrap = LocalDataBootstrap {
            attempts += 1
            throw InjectedSaveFailure()
        }

        await bootstrap.activate()
        await bootstrap.retry()

        #expect(attempts == 2)
        #expect(bootstrap.phase == .failed(attempts: 2))
        #expect(bootstrap.failureKind == .dataPreserved)
        #expect(bootstrap.dataContainer == nil)
        #expect(try Data(contentsOf: storeURL) == sentinel)
    }

    @Test("就绪后重复激活不会重建容器")
    func readyBootstrapDoesNotActivateTwice() async throws {
        var attempts = 0
        let storeURL = temporaryStoreURL()
        let bootstrap = LocalDataBootstrap {
            attempts += 1
            return try AccountDataContainer.fileBacked(storeURL: storeURL)
        }

        await bootstrap.activate()
        await bootstrap.activate()

        #expect(attempts == 1)
        #expect(bootstrap.phase == .ready)
        #expect(bootstrap.dataContainer?.storage == .file(storeURL))
    }

    @Test("生产引导拒绝临时存储")
    func bootstrapRejectsEphemeralStore() async throws {
        let bootstrap = LocalDataBootstrap {
            try AccountDataContainer.inMemory()
        }

        await bootstrap.activate()

        #expect(bootstrap.phase == .failed(attempts: 1))
        #expect(bootstrap.failureKind == .retryable)
        #expect(bootstrap.dataContainer == nil)
    }

    @Test("阻断状态文案支持中英文")
    func bootstrapCopyIsLocalized() {
        #expect(
            AccountLocalization.string(
                "local_data.error.retry_message",
                locale: Locale(identifier: "en")
            ).contains("Retry")
        )
        #expect(
            AccountLocalization.string(
                "local_data.error.title",
                locale: Locale(identifier: "en")
            ) == "Local Data Unavailable"
        )
        #expect(
            AccountLocalization.string(
                "local_data.error.title",
                locale: Locale(identifier: "zh-Hans")
            ) == "本地数据暂不可用"
        )
        #expect(
            AccountLocalization.string(
                "local_data.error.protection_message",
                locale: Locale(identifier: "en")
            ).contains("preserved")
        )
        #expect(
            AccountLocalization.string(
                "local_data.error.protection_message",
                locale: Locale(identifier: "zh-Hans")
            ).contains("保留")
        )
    }

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "accounts.store")
    }
}

private struct InjectedSaveFailure: Error {}
