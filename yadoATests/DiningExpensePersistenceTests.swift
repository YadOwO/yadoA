import Foundation
import SwiftData
import Testing
@testable import yadoA

@Suite("餐饮支出持久化边界", .serialized)
@MainActor
struct DiningExpensePersistenceTests {
    @Test("资产与价值类账户允许由支出扣减为负数")
    func assetAndValueAccountsDecrease() throws {
        let accountTypes: [AccountType] = [
            .cash,
            .debitCard,
            .virtualAccount,
            .investment,
            .receivable,
            .customAsset
        ]

        for accountType in accountTypes {
            let dataContainer = try AccountDataContainer.inMemory()
            let accountID = UUID()
            try saveAccount(
                id: accountID,
                accountType: accountType,
                amountText: "40",
                in: dataContainer.modelContainer
            )
            let repository = LocalExpenseRepository(container: dataContainer.modelContainer)

            try repository.save(
                DiningExpenseDraft(
                    accountID: accountID,
                    amountText: "50.00",
                    transactionDay: 20260813
                )
            )

            #expect(
                try account(id: accountID, in: dataContainer.modelContainer)?.balance
                    == Decimal(-10)
            )
            #expect(try transactionCount(in: dataContainer.modelContainer) == 1)
        }
    }

    @Test("信用卡与负债账户按正数债务增加")
    func debtAccountsIncrease() throws {
        for accountType in [AccountType.creditCard, .liability] {
            let dataContainer = try AccountDataContainer.inMemory()
            let accountID = UUID()
            try saveAccount(
                id: accountID,
                accountType: accountType,
                amountText: "100",
                in: dataContainer.modelContainer
            )
            let repository = LocalExpenseRepository(container: dataContainer.modelContainer)

            try repository.save(
                DiningExpenseDraft(
                    accountID: accountID,
                    amountText: "20.00",
                    transactionDay: 20260813
                )
            )

            #expect(
                try account(id: accountID, in: dataContainer.modelContainer)?.balance
                    == Decimal(120)
            )
        }
    }

    @Test("未来记账日会在保存时立即联动账户金额")
    func futureTransactionDayAffectsBalanceImmediately() throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let accountID = UUID()
        try saveAccount(id: accountID, amountText: "100", in: dataContainer.modelContainer)
        let repository = LocalExpenseRepository(container: dataContainer.modelContainer)
        let draft = DiningExpenseDraft(
            accountID: accountID,
            amountText: "10",
            transactionDay: 20991231
        )

        try repository.save(draft)

        #expect(
            try account(id: accountID, in: dataContainer.modelContainer)?.balance
                == Decimal(90)
        )
        #expect(
            try transaction(id: draft.id, in: dataContainer.modelContainer)?.transactionDay
                == 20991231
        )
    }

    @Test("缺失账户与无效金额会在任何模型变化前被拒绝")
    func invalidDraftIsRejectedBeforeMutation() throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let accountID = UUID()
        try saveAccount(id: accountID, amountText: "40", in: dataContainer.modelContainer)
        let repository = LocalExpenseRepository(container: dataContainer.modelContainer)

        #expect(throws: DiningExpenseDraftValidationError.accountRequired) {
            try repository.save(
                DiningExpenseDraft(amountText: "10", transactionDay: 20260813)
            )
        }
        #expect(throws: ExpenseTransactionValidationError.invalidAmount) {
            try repository.save(
                DiningExpenseDraft(
                    accountID: accountID,
                    amountText: "1.001",
                    transactionDay: 20260813
                )
            )
        }
        let missingID = UUID()
        #expect(throws: ExpenseRepositoryError.accountNotFound(missingID)) {
            try repository.save(
                DiningExpenseDraft(
                    accountID: missingID,
                    amountText: "10",
                    transactionDay: 20260813
                )
            )
        }

        #expect(try transactionCount(in: dataContainer.modelContainer) == 0)
        #expect(
            try account(id: accountID, in: dataContainer.modelContainer)?.balance
                == Decimal(40)
        )
    }

    @Test("未知账户类型与非 CNY 账户不会被猜测处理")
    func unsupportedAccountMetadataIsRejected() throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let context = ModelContext(dataContainer.modelContainer)
        context.autosaveEnabled = false
        let unknownTypeAccount = makePersistedAccount(
            id: UUID(),
            typeRawValue: "futureAccountType"
        )
        let foreignCurrencyAccount = makePersistedAccount(
            id: UUID(),
            typeRawValue: AccountType.cash.rawValue,
            currencyCode: "USD"
        )
        context.insert(unknownTypeAccount)
        context.insert(foreignCurrencyAccount)
        try context.save()
        let repository = LocalExpenseRepository(container: dataContainer.modelContainer)

        #expect(
            throws: ExpenseRepositoryError.unsupportedAccountType("futureAccountType")
        ) {
            try repository.save(
                DiningExpenseDraft(
                    accountID: unknownTypeAccount.id,
                    amountText: "10",
                    transactionDay: 20260813
                )
            )
        }
        #expect(throws: ExpenseRepositoryError.unsupportedCurrency("USD")) {
            try repository.save(
                DiningExpenseDraft(
                    accountID: foreignCurrencyAccount.id,
                    amountText: "10",
                    transactionDay: 20260813
                )
            )
        }

        #expect(try transactionCount(in: dataContainer.modelContainer) == 0)
        #expect(
            try account(id: unknownTypeAccount.id, in: dataContainer.modelContainer)?.balance
                == Decimal(40)
        )
        #expect(
            try account(id: foreignCurrencyAccount.id, in: dataContainer.modelContainer)?.balance
                == Decimal(40)
        )
    }

    @Test("保存失败同时回滚流水和账户金额并允许原草稿重试")
    func failedSaveRollsBackBothChangesAndAllowsRetry() throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let accountID = UUID()
        try saveAccount(id: accountID, amountText: "40", in: dataContainer.modelContainer)
        var shouldFail = true
        let repository = LocalExpenseRepository(
            container: dataContainer.modelContainer,
            beforeSave: {
                if shouldFail { throw InjectedExpenseSaveFailure() }
            }
        )
        let draft = DiningExpenseDraft(
            accountID: accountID,
            amountText: "50",
            transactionDay: 20260813
        )

        #expect(throws: InjectedExpenseSaveFailure.self) {
            try repository.save(draft)
        }
        #expect(try transactionCount(in: dataContainer.modelContainer) == 0)
        #expect(
            try account(id: accountID, in: dataContainer.modelContainer)?.balance
                == Decimal(40)
        )
        try expectPersistedState(
            container: dataContainer.modelContainer,
            accountID: accountID,
            balance: 40,
            transactionCount: 0
        )

        shouldFail = false
        try repository.save(draft)

        #expect(try transaction(id: draft.id, in: dataContainer.modelContainer)?.id == draft.id)
        #expect(try transactionCount(in: dataContainer.modelContainer) == 1)
        #expect(
            try account(id: accountID, in: dataContainer.modelContainer)?.balance
                == Decimal(-10)
        )
    }

    @Test("重复 UUID 不会覆盖原流水或再次联动任一账户")
    func duplicateIDDoesNotUpsertOrChangeBalances() throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let firstAccountID = UUID()
        let secondAccountID = UUID()
        try saveAccount(
            id: firstAccountID,
            amountText: "40",
            in: dataContainer.modelContainer
        )
        try saveAccount(
            id: secondAccountID,
            amountText: "100",
            in: dataContainer.modelContainer
        )
        let repository = LocalExpenseRepository(container: dataContainer.modelContainer)
        let transactionID = UUID()
        let savedAt = Date(timeIntervalSince1970: 1_786_608_000)
        let original = DiningExpenseDraft(
            id: transactionID,
            accountID: firstAccountID,
            amountText: "10",
            transactionDay: 20260813,
            note: "午餐"
        )
        try repository.save(original, savedAt: savedAt)
        let conflicting = DiningExpenseDraft(
            id: transactionID,
            accountID: secondAccountID,
            amountText: "90",
            transactionDay: 20260814,
            note: "不应覆盖"
        )

        #expect(throws: ExpenseRepositoryError.duplicateID(transactionID)) {
            try repository.save(conflicting)
        }

        let transaction = try #require(
            try transaction(id: transactionID, in: dataContainer.modelContainer)
        )
        #expect(try transactionCount(in: dataContainer.modelContainer) == 1)
        #expect(transaction.accountID == firstAccountID)
        #expect(transaction.amount == Decimal(10))
        #expect(transaction.transactionDay == 20260813)
        #expect(transaction.note == "午餐")
        #expect(transaction.savedAt == savedAt)
        #expect(
            try account(id: firstAccountID, in: dataContainer.modelContainer)?.balance
                == Decimal(30)
        )
        #expect(
            try account(id: secondAccountID, in: dataContainer.modelContainer)?.balance
                == Decimal(100)
        )
    }

    @Test("文件容器重开后保留流水与更新后的账户金额")
    func fileContainerPersistsTransactionAndBalanceAfterReopen() throws {
        let storeURL = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
        let accountID = UUID()
        let transactionID = UUID()

        do {
            let dataContainer = try AccountDataContainer.fileBacked(storeURL: storeURL)
            try saveAccount(
                id: accountID,
                amountText: "100",
                in: dataContainer.modelContainer
            )
            let repository = LocalExpenseRepository(container: dataContainer.modelContainer)
            try repository.save(
                DiningExpenseDraft(
                    id: transactionID,
                    accountID: accountID,
                    amountText: "12.34",
                    transactionDay: 20260813,
                    note: "午餐"
                )
            )
        }

        let reopened = try AccountDataContainer.fileBacked(storeURL: storeURL)
        let repository = LocalExpenseRepository(container: reopened.modelContainer)
        let transaction = try #require(
            try transaction(id: transactionID, in: reopened.modelContainer)
        )

        #expect(
            try account(id: accountID, in: reopened.modelContainer)?.balance
                == Decimal(string: "87.66")
        )
        #expect(transaction.amount == Decimal(string: "12.34"))
        #expect(transaction.note == "午餐")
    }

    /// 通过既有账户仓库保存符合当前类型约束的账户。
    private func saveAccount(
        id: UUID,
        accountType: AccountType = .cash,
        amountText: String,
        timestamp: Date = Date(timeIntervalSince1970: 1_786_608_000),
        in container: ModelContainer
    ) throws {
        let repository = LocalAccountRepository(container: container)
        try repository.save(
            AccountDraft(
                id: id,
                accountType: accountType,
                template: template(for: accountType),
                name: accountType.rawValue,
                amountText: amountText
            ),
            locale: Locale(identifier: "en_US"),
            now: timestamp
        )
    }

    /// 返回需要模板的账户类型所使用的稳定测试模板。
    private func template(for accountType: AccountType) -> AccountTemplate? {
        accountType.requiresTemplateSelection ? accountType.templates.first : nil
    }

    /// 构造损坏或未来元数据形态的持久账户。
    private func makePersistedAccount(
        id: UUID,
        typeRawValue: String,
        currencyCode: String = "CNY"
    ) -> Account {
        Account(
            id: id,
            typeRawValue: typeRawValue,
            templateID: nil,
            name: "测试账户",
            note: nil,
            lastFourDigits: nil,
            balance: 40,
            currencyCode: currencyCode,
            createdAt: Date(timeIntervalSince1970: 1_786_608_000),
            updatedAt: Date(timeIntervalSince1970: 1_786_608_000)
        )
    }

    /// 使用全新 context 验证已提交存储中的账户与流水状态。
    private func expectPersistedState(
        container: ModelContainer,
        accountID: UUID,
        balance: Decimal,
        transactionCount: Int
    ) throws {
        let context = ModelContext(container)
        let targetAccountID = accountID
        let accountDescriptor = FetchDescriptor<Account>(
            predicate: #Predicate<Account> { account in
                account.id == targetAccountID
            }
        )
        let account = try #require(try context.fetch(accountDescriptor).first)
        let transactions = try context.fetchCount(FetchDescriptor<ExpenseTransaction>())

        #expect(account.balance == balance)
        #expect(transactions == transactionCount)
    }

    /// 使用独立 context 统计当前已提交的流水数量。
    private func transactionCount(in container: ModelContainer) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<ExpenseTransaction>())
    }

    /// 使用独立 context 获取指定 UUID 的已提交账户。
    private func account(
        id: UUID,
        in container: ModelContainer
    ) throws -> Account? {
        let accountID = id
        var descriptor = FetchDescriptor<Account>(
            predicate: #Predicate<Account> { account in
                account.id == accountID
            }
        )
        descriptor.fetchLimit = 1
        return try ModelContext(container).fetch(descriptor).first
    }

    /// 使用独立 context 获取指定 UUID 的已提交流水。
    private func transaction(
        id: UUID,
        in container: ModelContainer
    ) throws -> ExpenseTransaction? {
        let transactionID = id
        var descriptor = FetchDescriptor<ExpenseTransaction>(
            predicate: #Predicate<ExpenseTransaction> { transaction in
                transaction.id == transactionID
            }
        )
        descriptor.fetchLimit = 1
        return try ModelContext(container).fetch(descriptor).first
    }

    /// 为文件重开测试创建隔离存储 URL。
    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "accounts.store")
    }
}

private struct InjectedExpenseSaveFailure: Error {}
