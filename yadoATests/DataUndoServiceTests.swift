import Foundation
import SwiftData
import Testing
@testable import yadoA

@Suite("数据撤销服务", .serialized)
@MainActor
struct DataUndoServiceTests {
    /// 可在用例中推进的时间源，用于覆盖保留期边界。
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    /// 每个用例独享的快照目录，避免并行用例互相覆盖。
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "data-undo-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// 构造含预置分类、账户、支出流水和默认偏好的夹具。
    ///
    /// 和 App 启动时一样先补齐预置分类：清除后会立即补回预置分类，撤销也会带回完整分类，
    /// 夹具里没有分类时「撤销后与清除前一致」无法成立。
    private func makeSeededContainer() throws -> AccountDataContainer {
        let container = try AccountDataContainer.inMemory()
        try LocalCategoryRepository(container: container.modelContainer).ensurePresets()
        let accountID = UUID()
        try LocalAccountRepository(container: container.modelContainer).save(
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

    /// 读取容器当前的全部业务数据，作为比较基准。
    private func contents(of container: AccountDataContainer) throws -> [String] {
        let backup = try BackupExportService(
            container: container.modelContainer,
            now: { Date(timeIntervalSince1970: 0) }
        ).makeSnapshot()
        let data = try BackupFileEncoding.makeEncoder().encode(backup)
        return [String(decoding: data, as: UTF8.self)]
    }

    /// 清除容器中的全部业务数据。
    private func erase(_ container: AccountDataContainer) throws {
        try LocalDataResetService(container: container.modelContainer).eraseAll()
    }

    @Test("清除后撤销，数据回到清除之前，且快照用完即删")
    func undoRestoresDataErasedByReset() throws {
        let container = try makeSeededContainer()
        let before = try contents(of: container)
        let service = DataUndoService(container: container.modelContainer, directory: makeDirectory())

        try service.perform(.reset) { try erase(container) }
        let snapshot = try #require(service.availableSnapshot())
        #expect(snapshot.operation == .reset)
        #expect(snapshot.accountCount == 1)
        #expect(snapshot.transactionCount == 1)

        try service.undo()
        #expect(try contents(of: container) == before)
        #expect(service.availableSnapshot() == nil)
        #expect(throws: DataUndoError.nothingToUndo) { try service.undo() }
    }

    @Test("超过 7 天后快照失效，不能再撤销")
    func snapshotExpiresAfterRetention() throws {
        let container = try makeSeededContainer()
        let clock = Clock()
        let service = DataUndoService(
            container: container.modelContainer,
            directory: makeDirectory(),
            now: { clock.now }
        )
        try service.perform(.reset) { try erase(container) }

        clock.now += DataUndoPolicy.retention - 1
        #expect(service.availableSnapshot() != nil)

        clock.now += 1
        #expect(service.availableSnapshot() == nil)
        #expect(throws: DataUndoError.nothingToUndo) { try service.undo() }
    }

    @Test("操作失败时不替换上一份快照")
    func failedOperationKeepsPreviousSnapshot() throws {
        let container = try makeSeededContainer()
        let service = DataUndoService(container: container.modelContainer, directory: makeDirectory())
        try service.perform(.reset) { try erase(container) }
        let previous = try #require(service.availableSnapshot())

        struct InjectedFailure: Error {}
        #expect(throws: InjectedFailure.self) {
            try service.perform(.restore) { throw InjectedFailure() }
        }
        #expect(service.availableSnapshot() == previous)
    }

    @Test("账本已空时再次清除，不会把上一份快照换成空快照")
    func resettingEmptyLedgerKeepsPreviousSnapshot() throws {
        let container = try makeSeededContainer()
        let service = DataUndoService(container: container.modelContainer, directory: makeDirectory())
        try service.perform(.reset) { try erase(container) }
        let previous = try #require(service.availableSnapshot())

        try service.perform(.reset) { try erase(container) }
        #expect(service.availableSnapshot() == previous)
    }

    @Test("撤销保存失败时数据不变，快照仍可再次使用")
    func failedUndoKeepsSnapshot() throws {
        let container = try makeSeededContainer()
        let directory = makeDirectory()
        try DataUndoService(container: container.modelContainer, directory: directory)
            .perform(.reset) { try erase(container) }
        let erased = try contents(of: container)

        struct InjectedFailure: Error {}
        let failing = DataUndoService(
            container: container.modelContainer,
            directory: directory,
            beforeSave: { throw InjectedFailure() }
        )
        #expect(throws: DataUndoError.undoFailed) { try failing.undo() }
        #expect(try contents(of: container) == erased)
        #expect(failing.availableSnapshot() != nil)
    }
}
