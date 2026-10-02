import Foundation
import SwiftData
import Testing
@testable import yadoA

@Suite("余额调整持久化边界", .serialized)
@MainActor
struct BalanceAdjustmentPersistenceTests {
    @Test("直接设置现金目标总余额并保存精确差额")
    func cashTargetBalanceIsAssignedExactly() throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let accountID = UUID()
        let updatedAt = Date(timeIntervalSince1970: 1_786_608_000)
        try saveAccount(
            id: accountID,
            accountType: .cash,
            amountText: "100",
            timestamp: updatedAt,
            in: dataContainer.modelContainer
        )
        let draft = BalanceAdjustmentDraft(
            accountID: accountID,
            amountText: "120"
        )
        let repository = LocalBalanceAdjustmentRepository(
            container: dataContainer.modelContainer
        )

        let result = try repository.save(
            draft,
            now: Date(timeIntervalSince1970: 1_786_651_200)
        )
        let account = try #require(try fetchAccount(id: accountID, in: dataContainer.modelContainer))
        let transaction = try #require(
            try fetchTransaction(id: draft.id, in: dataContainer.modelContainer)
        )

        #expect(account.balance == 120)
        #expect(account.updatedAt == updatedAt)
        #expect(result == .saved(currentBalance: 120))
        #expect(transaction.balanceBefore == 100)
        #expect(transaction.balanceAfter == 120)
        #expect(transaction.balanceDelta == 20)
        #expect(transaction.transactionDay == 20260814)
    }

    @Test("负数和信用卡都直接采用目标总余额")
    func negativeAndDebtTargetsDoNotUseExpenseDirection() throws {
        let scenarios: [(AccountType, String, BalanceAdjustmentSign, Decimal, Decimal)] = [
            (.cash, "40", .negative, -10, -50),
            (.creditCard, "100", .positive, 80, -20)
        ]

        for (accountType, openingText, sign, target, expectedDelta) in scenarios {
            let dataContainer = try AccountDataContainer.inMemory()
            let accountID = UUID()
            try saveAccount(
                id: accountID,
                accountType: accountType,
                amountText: openingText,
                in: dataContainer.modelContainer
            )
            let repository = LocalBalanceAdjustmentRepository(
                container: dataContainer.modelContainer
            )
            let draft = BalanceAdjustmentDraft(
                accountID: accountID,
                amountText: String(describing: abs(target)),
                sign: sign
            )
            let result = try repository.save(draft)
            let transaction = try #require(
                try fetchTransaction(id: draft.id, in: dataContainer.modelContainer)
            )

            #expect(try fetchAccount(id: accountID, in: dataContainer.modelContainer)?.balance == target)
            #expect(result == .saved(currentBalance: target))
            #expect(transaction.balanceDelta == expectedDelta)
        }
    }

    @Test("实际余额已同值时不写入也不报错")
    func unchangedTargetCreatesNothing() throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let accountID = UUID()
        try saveAccount(id: accountID, amountText: "100", in: dataContainer.modelContainer)
        var beforeSaveCalls = 0
        let repository = LocalBalanceAdjustmentRepository(
            container: dataContainer.modelContainer,
            beforeSave: { beforeSaveCalls += 1 }
        )

        let result = try repository.save(
            BalanceAdjustmentDraft(accountID: accountID, amountText: "100")
        )

        #expect(result == .unchanged(currentBalance: 100))
        #expect(beforeSaveCalls == 0)
        #expect(try transactionCount(in: dataContainer.modelContainer) == 0)
    }

    @Test("保存失败同时回滚余额和流水并允许原草稿重试")
    func failedSaveRollsBackAndRetrySucceeds() throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let accountID = UUID()
        try saveAccount(id: accountID, amountText: "40", in: dataContainer.modelContainer)
        var shouldFail = true
        let repository = LocalBalanceAdjustmentRepository(
            container: dataContainer.modelContainer,
            beforeSave: {
                if shouldFail { throw InjectedBalancePersistenceFailure() }
            }
        )
        let draft = BalanceAdjustmentDraft(
            accountID: accountID,
            amountText: "10",
            sign: .negative,
            note: "校准"
        )

        #expect(throws: InjectedBalancePersistenceFailure.self) {
            try repository.save(draft)
        }
        #expect(try fetchAccount(id: accountID, in: dataContainer.modelContainer)?.balance == 40)
        #expect(try transactionCount(in: dataContainer.modelContainer) == 0)

        shouldFail = false
        _ = try repository.save(draft)

        #expect(try fetchAccount(id: accountID, in: dataContainer.modelContainer)?.balance == -10)
        #expect(try transactionCount(in: dataContainer.modelContainer) == 1)
    }

    @Test("保存差额以重新读取的实际余额为准")
    func staleOpeningSnapshotUsesActualStoredBalance() throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let accountID = UUID()
        try saveAccount(id: accountID, amountText: "100", in: dataContainer.modelContainer)
        let repository = LocalBalanceAdjustmentRepository(
            container: dataContainer.modelContainer
        )
        let draft = BalanceAdjustmentDraft(accountID: accountID, amountText: "120")
        try LocalExpenseRepository(container: dataContainer.modelContainer).save(
            DiningExpenseDraft(
                accountID: accountID,
                amountText: "10",
                transactionDay: 20260813
            )
        )

        let result = try repository.save(draft)
        let transaction = try #require(
            try fetchTransaction(id: draft.id, in: dataContainer.modelContainer)
        )

        #expect(result == .saved(currentBalance: 120))
        #expect(transaction.balanceBefore == 90)
        #expect(transaction.balanceAfter == 120)
        #expect(transaction.balanceDelta == 30)
        #expect(try fetchAccount(id: accountID, in: dataContainer.modelContainer)?.balance == 120)
    }

    @Test("账户缺失和跨类型重复 UUID 不产生副作用")
    func missingAccountAndDuplicateTransactionCreateNoChanges() throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let missingDraft = BalanceAdjustmentDraft(
            id: UUID(),
            accountID: UUID(),
            amountText: "10"
        )
        let repository = LocalBalanceAdjustmentRepository(
            container: dataContainer.modelContainer
        )

        #expect(throws: BalanceAdjustmentRepositoryError.accountNotFound(missingDraft.accountID)) {
            try repository.save(missingDraft)
        }
        #expect(try transactionCount(in: dataContainer.modelContainer) == 0)

        let accountID = UUID()
        let duplicateID = UUID()
        try saveAccount(id: accountID, amountText: "100", in: dataContainer.modelContainer)
        try LocalExpenseRepository(container: dataContainer.modelContainer).save(
            DiningExpenseDraft(
                id: duplicateID,
                accountID: accountID,
                amountText: "10",
                transactionDay: 20260813
            )
        )

        #expect(throws: BalanceAdjustmentRepositoryError.duplicateID(duplicateID)) {
            try repository.save(
                BalanceAdjustmentDraft(
                    id: duplicateID,
                    accountID: accountID,
                    amountText: "120"
                )
            )
        }
        #expect(try fetchAccount(id: accountID, in: dataContainer.modelContainer)?.balance == 90)
        #expect(try transactionCount(in: dataContainer.modelContainer) == 1)
    }

    @Test("非 CNY 账户被拒绝且余额和流水不变")
    func unsupportedCurrencyCreatesNoChanges() throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let accountID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_786_608_000)
        let context = ModelContext(dataContainer.modelContainer)
        context.autosaveEnabled = false
        context.insert(
            Account(
                id: accountID,
                typeRawValue: AccountType.cash.rawValue,
                templateID: nil,
                name: "USD",
                note: nil,
                lastFourDigits: nil,
                balance: 100,
                currencyCode: "USD",
                createdAt: timestamp,
                updatedAt: timestamp
            )
        )
        try context.save()

        #expect(throws: BalanceAdjustmentRepositoryError.unsupportedCurrency("USD")) {
            try LocalBalanceAdjustmentRepository(
                container: dataContainer.modelContainer
            ).save(
                BalanceAdjustmentDraft(accountID: accountID, amountText: "120")
            )
        }
        let savedAccount = try #require(
            try fetchAccount(id: accountID, in: dataContainer.modelContainer)
        )
        #expect(savedAccount.balance == 100)
        #expect(savedAccount.updatedAt == timestamp)
        #expect(try transactionCount(in: dataContainer.modelContainer) == 0)
    }

    @Test("余额调整在文件存储重开后仍然存在")
    func adjustmentPersistsAfterStoreReopen() throws {
        let storeURL = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
        let accountID = UUID()
        let transactionID = UUID()

        do {
            let dataContainer = try AccountDataContainer.fileBacked(storeURL: storeURL)
            try saveAccount(id: accountID, amountText: "100", in: dataContainer.modelContainer)
            _ = try LocalBalanceAdjustmentRepository(
                container: dataContainer.modelContainer
            ).save(
                BalanceAdjustmentDraft(
                    id: transactionID,
                    accountID: accountID,
                    amountText: "120",
                    note: "校准"
                )
            )
        }

        let reopened = try AccountDataContainer.fileBacked(storeURL: storeURL)
        let account = try #require(try fetchAccount(id: accountID, in: reopened.modelContainer))
        let transaction = try #require(
            try fetchTransaction(id: transactionID, in: reopened.modelContainer)
        )

        #expect(account.balance == 120)
        #expect(transaction.balanceBefore == 100)
        #expect(transaction.balanceAfter == 120)
        #expect(transaction.balanceDelta == 20)
        #expect(transaction.note == "校准")
    }

    /// 通过既有账户仓库保存符合当前类型约束的账户。
    private func saveAccount(
        id: UUID,
        accountType: AccountType = .cash,
        amountText: String,
        timestamp: Date = Date(timeIntervalSince1970: 1_786_608_000),
        in container: ModelContainer
    ) throws {
        try LocalAccountRepository(container: container).save(
            AccountDraft(
                id: id,
                accountType: accountType,
                template: accountType.requiresTemplateSelection ? accountType.templates.first : nil,
                name: accountType.rawValue,
                amountText: amountText
            ),
            locale: Locale(identifier: "en_US"),
            now: timestamp
        )
    }

    /// 使用独立 context 获取已提交账户。
    private func fetchAccount(id: UUID, in container: ModelContainer) throws -> Account? {
        let accountID = id
        var descriptor = FetchDescriptor<Account>(
            predicate: #Predicate<Account> { account in account.id == accountID }
        )
        descriptor.fetchLimit = 1
        return try ModelContext(container).fetch(descriptor).first
    }

    /// 使用独立 context 获取已提交账户流水。
    private func fetchTransaction(
        id: UUID,
        in container: ModelContainer
    ) throws -> AccountTransaction? {
        let transactionID = id
        var descriptor = FetchDescriptor<AccountTransaction>(
            predicate: #Predicate<AccountTransaction> { transaction in
                transaction.id == transactionID
            }
        )
        descriptor.fetchLimit = 1
        return try ModelContext(container).fetch(descriptor).first
    }

    /// 使用独立 context 统计全部账户流水。
    private func transactionCount(in container: ModelContainer) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<AccountTransaction>())
    }

    /// 为文件容器测试创建隔离的临时存储位置。
    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "accounts.store")
    }
}

private struct InjectedBalancePersistenceFailure: Error {}
