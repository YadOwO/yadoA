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
}
