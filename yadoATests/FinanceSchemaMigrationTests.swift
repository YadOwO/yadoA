import Foundation
import SwiftData
import Testing
@testable import yadoA

@Suite("本地数据版本化 schema 与迁移", .serialized)
@MainActor
struct FinanceSchemaMigrationTests {
    /// 防止给本地库加上迁移计划后，开发机上不带迁移计划建出来的旧库打不开，或重开后数据丢失、变形。
    ///
    /// 先用 `FinanceSchemaV1.schema` 不带迁移计划建文件库，模拟现有开发机上的库，写入四类记录后关掉；
    /// 再用带迁移计划的 `AccountDataContainer.fileBacked(storeURL:)` 重开，记录数和关键字段必须保持不变。
    @Test("V1 旧库用带迁移计划的文件容器重开后数据不变")
    func reopensV1StoreWithMigrationPlan() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appending(path: "accounts.store")

        let accountID = UUID()
        let transactionID = UUID()
        let ruleID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_794_700_800)
        let balance = try #require(Decimal(string: "1234.56"))
        let expenseAmount = try #require(Decimal(string: "23.45"))

        // 旧库放在独立作用域里，出作用域即关闭，之后才重开。
        do {
            let configuration = ModelConfiguration(
                "FinanceSchemaV9",
                schema: FinanceSchemaV1.schema,
                url: storeURL,
                cloudKitDatabase: .none
            )
            // 故意不带迁移计划，模拟现有开发机上的库。
            let legacy = try ModelContainer(
                for: FinanceSchemaV1.schema,
                configurations: [configuration]
            )
            let context = ModelContext(legacy)
            context.insert(
                Account(
                    id: accountID,
                    typeRawValue: AccountType.debitCard.rawValue,
                    templateID: nil,
                    name: "工资卡",
                    note: "日常",
                    lastFourDigits: "8765",
                    balance: balance,
                    openingBalance: 1000,
                    currencyCode: "CNY",
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            )
            context.insert(
                try AccountTransaction.validatingExpense(
                    id: transactionID,
                    accountID: accountID,
                    category: .dining,
                    amount: expenseAmount,
                    currencyCode: "CNY",
                    transactionDay: 20261115,
                    note: "午饭",
                    savedAt: timestamp
                )
            )
            context.insert(
                RecurringRule(
                    id: ruleID,
                    entryTypeRawValue: BookkeepingEntryType.expense.rawValue,
                    accountID: accountID,
                    categoryKey: ExpenseCategory.housing.rawValue,
                    amount: 3000,
                    note: "房租",
                    frequencyRawValue: RecurringFrequency.monthly.rawValue,
                    anchorDay: 20261101,
                    nextDueDay: 20261201,
                    endDay: nil,
                    pausedAt: nil,
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            )
            context.insert(
                SyncLedgerEntry(
                    entityType: .account,
                    recordID: accountID,
                    modifiedAt: timestamp,
                    payloadHash: "hash-account"
                )
            )
            try context.save()
        }

        let reopened = try AccountDataContainer.fileBacked(storeURL: storeURL)
        #expect(reopened.storage == .file(storeURL))
        let context = ModelContext(reopened.modelContainer)

        #expect(try context.fetchCount(FetchDescriptor<Account>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<AccountTransaction>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<RecurringRule>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<SyncLedgerEntry>()) == 1)

        let account = try #require(try context.fetch(FetchDescriptor<Account>()).first)
        #expect(account.id == accountID)
        #expect(account.name == "工资卡")
        #expect(account.balance == balance)
        #expect(account.openingBalance == 1000)
        #expect(account.lastFourDigits == "8765")
        #expect(account.typeRawValue == AccountType.debitCard.rawValue)
        #expect(account.createdAt == timestamp)

        let transaction = try #require(try context.fetch(FetchDescriptor<AccountTransaction>()).first)
        #expect(transaction.id == transactionID)
        #expect(transaction.accountID == accountID)
        #expect(transaction.amount == expenseAmount)
        #expect(transaction.categoryRawValue == ExpenseCategory.dining.rawValue)
        #expect(transaction.transactionDay == 20261115)
        #expect(transaction.note == "午饭")

        let rule = try #require(try context.fetch(FetchDescriptor<RecurringRule>()).first)
        #expect(rule.id == ruleID)
        #expect(rule.accountID == accountID)
        #expect(rule.amount == 3000)
        #expect(rule.categoryKey == ExpenseCategory.housing.rawValue)
        #expect(rule.frequencyRawValue == RecurringFrequency.monthly.rawValue)
        #expect(rule.nextDueDay == 20261201)
        #expect(rule.endDay == nil)

        let ledger = try #require(try context.fetch(FetchDescriptor<SyncLedgerEntry>()).first)
        #expect(ledger.key == SyncLedgerEntry.key(entityType: .account, recordID: accountID))
        #expect(ledger.recordID == accountID)
        #expect(ledger.payloadHash == "hash-account")
        #expect(ledger.revision == 1)
        #expect(ledger.pushedRevision == 0)
    }

    /// 防止新增版本时忘记同步更新当前 schema，或迁移计划与容器各自指向不同版本。
    ///
    /// 当前 schema 必须取自迁移计划里的最新版本，目前只有 9.0.0 一个版本、没有迁移步骤，
    /// 包含全部 7 个顶层模型；带迁移计划的内存容器也必须能正常创建。
    @Test("当前 schema 指向迁移计划里的最新版本 9.0.0")
    func currentSchemaIsLatestVersionedSchema() throws {
        #expect(FinanceSchemaV1.versionIdentifier == Schema.Version(9, 0, 0))

        let latest = try #require(FinanceMigrationPlan.schemas.last)
        #expect(ObjectIdentifier(latest) == ObjectIdentifier(FinanceSchemaV1.self))
        #expect(FinanceMigrationPlan.stages.isEmpty)
        #expect(
            Set(AccountDataContainer.schema.entities.map(\.name)) == [
                "Account",
                "AccountTransaction",
                "BookkeepingPreference",
                "BookkeepingCategory",
                "RecurringRule",
                "SyncLedgerEntry",
                "AIChatTurnRecord",
            ]
        )

        let container = try AccountDataContainer.inMemory()
        #expect(container.storage == .inMemory)
    }
}
