import Foundation
import SwiftData
import Testing
@testable import yadoA

@Suite("备份导入服务", .serialized)
@MainActor
struct BackupImportServiceTests {
    /// 每个用例独享的导出目录，避免并行用例互相清扫文件。
    private func makeExportDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "backup-import-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// 构造覆盖启用/停用账户、三类流水与默认偏好的完整夹具。
    private func makeSeededContainer() throws -> AccountDataContainer {
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
                expenseCategoryKey: ExpenseCategory.dining.rawValue,
                amountText: "1.5",
                transactionDay: 20260902
            ),
            savedAt: Date(timeIntervalSince1970: 100)
        )
        try LocalExpenseRepository(container: container.modelContainer).save(
            DiningExpenseDraft(
                id: UUID(),
                accountID: activeID,
                entryType: .income,
                incomeCategoryKey: IncomeCategory.salary.rawValue,
                amountText: "100",
                transactionDay: 20260901
            ),
            savedAt: Date(timeIntervalSince1970: 200)
        )
        _ = try LocalBalanceAdjustmentRepository(container: container.modelContainer).save(
            BalanceAdjustmentDraft(id: UUID(), accountID: activeID, amountText: "200"),
            now: Date(timeIntervalSince1970: 300)
        )
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
        return container
    }

    /// 导出容器当前内容并解码为备份信封，作为比较基准。
    private func snapshot(of container: AccountDataContainer) throws -> BackupFile {
        let service = BackupExportService(
            container: container.modelContainer,
            exportDirectory: makeExportDirectory(),
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        return try BackupFileEncoding.decode(Data(contentsOf: service.export()))
    }

    /// 生成只含一个现金账户的最小合法备份，供逐项破坏。
    private func makeBackup(
        formatVersion: Int = BackupFormatVersion.current,
        accounts: [BackupAccount]? = nil,
        transactions: [BackupTransaction] = [],
        preference: BackupBookkeepingPreference? = nil,
        categories: [BackupCategory] = []
    ) -> BackupFile {
        BackupFile(
            formatVersion: formatVersion,
            exportedAt: Date(timeIntervalSince1970: 1_000),
            appVersion: "1.0",
            appBuild: "1",
            accounts: accounts ?? [makeAccount(id: Self.accountID)],
            transactions: transactions,
            bookkeepingPreference: preference,
            categories: categories
        )
    }

    private nonisolated static let accountID = UUID()

    private func makeAccount(id: UUID, name: String = "现金", balance: String = "10") -> BackupAccount {
        BackupAccount(
            id: id,
            type: AccountType.cash.rawValue,
            templateID: nil,
            name: name,
            note: nil,
            lastFourDigits: nil,
            balance: balance,
            currencyCode: "CNY",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            deactivatedAt: nil
        )
    }

    private func makeExpense(
        id: UUID = UUID(),
        accountID: UUID = BackupImportServiceTests.accountID,
        amount: String? = "12.5",
        currencyCode: String = "CNY",
        transactionDay: Int = 20260902
    ) -> BackupTransaction {
        BackupTransaction(
            id: id,
            accountID: accountID,
            type: AccountTransactionType.expense.rawValue,
            category: ExpenseCategory.dining.rawValue,
            amount: amount,
            title: nil,
            balanceBefore: nil,
            balanceAfter: nil,
            balanceDelta: nil,
            currencyCode: currencyCode,
            transactionDay: transactionDay,
            note: nil,
            savedAt: Date(timeIntervalSince1970: 30)
        )
    }

    private func encode(_ backup: BackupFile) throws -> Data {
        try BackupFileEncoding.makeEncoder().encode(backup)
    }

    @Test("导出后恢复到空设备：账户、流水与偏好完全一致")
    func roundTripIntoEmptyStoreReproducesEverything() throws {
        let source = try makeSeededContainer()
        let original = try snapshot(of: source)
        let fileURL = makeExportDirectory().appending(path: "source.yadoabackup")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encode(original).write(to: fileURL)

        let target = try AccountDataContainer.inMemory()
        let service = BackupImportService(container: target.modelContainer)
        let plan = try service.prepare(from: fileURL)

        #expect(plan.replacesExistingData == false)
        #expect(plan.accountCount == 2)
        #expect(plan.transactionCount == 3)

        try service.restore(plan)
        let restored = try snapshot(of: target)

        #expect(restored.accounts == original.accounts)
        #expect(restored.transactions == original.transactions)
        #expect(restored.bookkeepingPreference == original.bookkeepingPreference)
    }

    @Test("恢复整体替换现有数据：同 UUID 覆盖，备份之外的记录删除")
    func restoreReplacesExistingData() throws {
        let container = try makeSeededContainer()
        let original = try snapshot(of: container)
        let activeID = try #require(original.bookkeepingPreference?.defaultAccountID)

        // 备份之后继续记账并新建账户，制造与备份的差异。
        try LocalExpenseRepository(container: container.modelContainer).save(
            DiningExpenseDraft(
                id: UUID(),
                accountID: activeID,
                entryType: .expense,
                expenseCategoryKey: ExpenseCategory.shopping.rawValue,
                amountText: "50",
                transactionDay: 20260903
            ),
            savedAt: Date(timeIntervalSince1970: 500)
        )
        try LocalAccountRepository(container: container.modelContainer).save(
            AccountDraft(id: UUID(), accountType: .cash, name: "备份后新建", amountText: "5"),
            locale: Locale(identifier: "en_US")
        )

        let service = BackupImportService(container: container.modelContainer)
        let plan = try service.prepare(from: try encode(original))
        #expect(plan.replacesExistingData)

        try service.restore(plan)
        let restored = try snapshot(of: container)

        #expect(restored.accounts == original.accounts)
        #expect(restored.transactions == original.transactions)
        #expect(restored.bookkeepingPreference == original.bookkeepingPreference)
    }

    @Test("备份没有偏好记录时，恢复会移除现有偏好")
    func restoreRemovesPreferenceWhenBackupHasNone() throws {
        let container = try makeSeededContainer()
        let service = BackupImportService(container: container.modelContainer)

        try service.restore(try service.prepare(from: try encode(makeBackup())))

        let context = container.modelContainer.makeManualSaveContext()
        #expect(try context.fetchCount(FetchDescriptor<BookkeepingPreference>()) == 0)
        #expect(try context.fetch(FetchDescriptor<Account>()).map(\.id) == [Self.accountID])
        #expect(try context.fetchCount(FetchDescriptor<AccountTransaction>()) == 0)
    }

    @Test("保存失败时回滚，现有数据保持原样")
    func saveFailureLeavesExistingDataUntouched() throws {
        let container = try makeSeededContainer()
        let original = try snapshot(of: container)
        struct InjectedFailure: Error {}
        let service = BackupImportService(
            container: container.modelContainer,
            beforeSave: { throw InjectedFailure() }
        )
        let plan = try service.prepare(from: try encode(makeBackup()))

        #expect(throws: BackupImportError.restoreFailed) {
            try service.restore(plan)
        }

        let current = try snapshot(of: container)
        #expect(current.accounts == original.accounts)
        #expect(current.transactions == original.transactions)
        #expect(current.bookkeepingPreference == original.bookkeepingPreference)
    }

    @Test("非备份 JSON 与缺失文件分别报格式错误和读取错误")
    func rejectsUnreadableAndMalformedFiles() throws {
        let container = try AccountDataContainer.inMemory()
        let service = BackupImportService(container: container.modelContainer)

        #expect(throws: BackupImportError.invalidFormat) {
            try service.prepare(from: Data("{\"hello\":1}".utf8))
        }
        #expect(throws: BackupImportError.invalidFormat) {
            try service.prepare(from: Data("not json".utf8))
        }
        #expect(throws: BackupImportError.fileUnreadable) {
            try service.prepare(from: makeExportDirectory().appending(path: "missing.yadoabackup"))
        }
    }

    @Test("拒绝更新版本或非法版本号的备份")
    func rejectsUnsupportedFormatVersions() throws {
        let container = try AccountDataContainer.inMemory()
        let service = BackupImportService(container: container.modelContainer)
        let newer = BackupFormatVersion.current + 1

        #expect(throws: BackupImportError.unsupportedVersion(newer)) {
            try service.prepare(from: try encode(makeBackup(formatVersion: newer)))
        }
        #expect(throws: BackupImportError.unsupportedVersion(0)) {
            try service.prepare(from: try encode(makeBackup(formatVersion: 0)))
        }
    }

    @Test("任一记录不合法时整份备份被拒绝，且不写入任何数据")
    func rejectsInvalidContentWithoutWriting() throws {
        let container = try AccountDataContainer.inMemory()
        let service = BackupImportService(container: container.modelContainer)
        let duplicateTransactionID = UUID()

        let invalidBackups: [BackupFile] = [
            // 重复账户 UUID。
            makeBackup(accounts: [makeAccount(id: Self.accountID), makeAccount(id: Self.accountID)]),
            // 空账户名称。
            makeBackup(accounts: [makeAccount(id: Self.accountID, name: "  ")]),
            // 非法余额字符串。
            makeBackup(accounts: [makeAccount(id: Self.accountID, balance: "12abc")]),
            // 流水指向备份中不存在的账户。
            makeBackup(transactions: [makeExpense(accountID: UUID())]),
            // 重复流水 UUID。
            makeBackup(transactions: [
                makeExpense(id: duplicateTransactionID),
                makeExpense(id: duplicateTransactionID),
            ]),
            // 支出缺少金额。
            makeBackup(transactions: [makeExpense(amount: nil)]),
            // 金额超过两位小数。
            makeBackup(transactions: [makeExpense(amount: "1.234")]),
            // 金额不是纯十进制字符串。
            makeBackup(transactions: [makeExpense(amount: "1e2")]),
            // 当前版本不支持的流水币种。
            makeBackup(transactions: [makeExpense(currencyCode: "USD")]),
            // 非法记账日。
            makeBackup(transactions: [makeExpense(transactionDay: 20261340)]),
        ]

        for backup in invalidBackups {
            #expect(throws: BackupImportError.invalidContent) {
                try service.prepare(from: try encode(backup))
            }
            // 绕过 prepare 直接恢复也必须被恢复边界的重新校验拦下。
            #expect(throws: BackupImportError.invalidContent) {
                try service.restore(BackupImportPlan(backup: backup, replacesExistingData: false))
            }
        }

        let context = container.modelContainer.makeManualSaveContext()
        #expect(try context.fetchCount(FetchDescriptor<Account>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<AccountTransaction>()) == 0)
    }

    // MARK: - 分类

    @Test("自定义分类、隐藏、排序和删除墓碑（含预置分类）随备份完整往返")
    func categoriesRoundTrip() throws {
        let source = try makeSeededContainer()
        let categories = LocalCategoryRepository(container: source.modelContainer)
        let coffee = try categories.create(name: "咖啡", symbolName: "mug", direction: .expense)
        let removed = try categories.create(name: "旧分类", symbolName: "tag", direction: .expense)
        try categories.delete(key: removed, direction: .expense, migratingTo: "other")
        try categories.setHidden(true, key: "pets", direction: .expense)
        try categories.delete(key: "partTime", direction: .income, migratingTo: "other")
        try categories.reorder([coffee, "travel"], direction: .expense)
        let activeID = try #require(try snapshot(of: source).bookkeepingPreference?.defaultAccountID)
        try LocalExpenseRepository(container: source.modelContainer).save(
            DiningExpenseDraft(
                accountID: activeID,
                expenseCategoryKey: coffee,
                amountText: "18",
                transactionDay: 20260905
            ),
            savedAt: Date(timeIntervalSince1970: 600)
        )
        let original = try snapshot(of: source)
        #expect(original.categories.contains { $0.key == removed && $0.deletedAt != nil })

        let target = try AccountDataContainer.inMemory()
        let service = BackupImportService(container: target.modelContainer)
        try service.restore(try service.prepare(from: try encode(original)))
        let restored = try snapshot(of: target)

        #expect(restored.categories == original.categories)
        #expect(restored.transactions == original.transactions)
        let catalog = BookkeepingCategoryCatalog(
            categories: try target.modelContainer.makeManualSaveContext()
                .fetch(FetchDescriptor<BookkeepingCategory>())
        )
        #expect(catalog.items(for: .expense).first?.key == coffee)
        #expect(catalog.hiddenItems(for: .expense).map(\.key) == ["pets"])
        #expect(catalog.item(direction: .income, key: "partTime")?.isDeleted == true)
        #expect(!catalog.items(for: .income).contains { $0.key == "partTime" })
    }

    @Test("备份没有分类数据时，分类恢复为预置默认值")
    func missingCategoriesRestorePresetDefaults() throws {
        let container = try makeSeededContainer()
        let categories = LocalCategoryRepository(container: container.modelContainer)
        try categories.create(name: "咖啡", symbolName: "mug", direction: .expense)
        try categories.setHidden(true, key: "pets", direction: .expense)
        let service = BackupImportService(container: container.modelContainer)

        try service.restore(try service.prepare(from: try encode(makeBackup())))

        let rows = try container.modelContainer.makeManualSaveContext()
            .fetch(FetchDescriptor<BookkeepingCategory>())
        #expect(rows.count == BookkeepingCategoryKey.allPresets.count)
        #expect(rows.allSatisfy { $0.isPreset && !$0.isHidden })
    }

    @Test("流水引用备份中不存在或已删除的分类（含预置分类）时整份拒绝")
    func rejectsTransactionsWithUnknownCustomCategory() throws {
        let service = BackupImportService(container: try AccountDataContainer.inMemory().modelContainer)
        let deletedID = UUID()
        let deletedKey = BookkeepingCategoryKey.customKey(for: deletedID)
        let tombstone = BackupCategory(
            id: deletedID, direction: BookkeepingEntryType.expense.rawValue, key: deletedKey,
            customName: "旧分类", symbolName: "tag", sortIndex: 20, isHidden: false,
            updatedAt: Date(timeIntervalSince1970: 40), deletedAt: Date(timeIntervalSince1970: 50),
            replacementKey: "other"
        )
        let deletedPreset = BackupCategory(
            id: BookkeepingCategoryKey.presetID(direction: .expense, key: "pets"),
            direction: BookkeepingEntryType.expense.rawValue, key: "pets",
            customName: nil, symbolName: ExpenseCategory.pets.symbolName, sortIndex: 11, isHidden: false,
            updatedAt: Date(timeIntervalSince1970: 40), deletedAt: Date(timeIntervalSince1970: 50),
            replacementKey: "other"
        )
        for key in [BookkeepingCategoryKey.customKey(for: UUID()), deletedKey, "pets"] {
            let transaction = BackupTransaction(
                id: UUID(), accountID: Self.accountID, type: AccountTransactionType.expense.rawValue,
                category: key, amount: "1", title: nil, balanceBefore: nil, balanceAfter: nil,
                balanceDelta: nil, currencyCode: "CNY", transactionDay: 20260902, note: nil,
                savedAt: Date(timeIntervalSince1970: 30)
            )
            #expect(throws: BackupImportError.invalidContent) {
                try service.prepare(from: try encode(
                    makeBackup(transactions: [transaction], categories: [tombstone, deletedPreset])
                ))
            }
        }
    }

    @Test("分类记录不合法时整份拒绝")
    func rejectsInvalidCategories() throws {
        let service = BackupImportService(container: try AccountDataContainer.inMemory().modelContainer)
        let customID = UUID()
        let valid = BackupCategory(
            id: customID, direction: BookkeepingEntryType.expense.rawValue,
            key: BookkeepingCategoryKey.customKey(for: customID), customName: "咖啡",
            symbolName: "mug", sortIndex: 20, isHidden: false,
            updatedAt: Date(timeIntervalSince1970: 40), deletedAt: nil, replacementKey: nil
        )
        let invalidCategories: [BackupCategory] = [
            // 自定义分类没有名称。
            BackupCategory(
                id: valid.id, direction: valid.direction, key: valid.key, customName: "  ",
                symbolName: valid.symbolName, sortIndex: valid.sortIndex, isHidden: false,
                updatedAt: valid.updatedAt, deletedAt: nil, replacementKey: nil
            ),
            // 未知方向。
            BackupCategory(
                id: valid.id, direction: "transfer", key: valid.key, customName: valid.customName,
                symbolName: valid.symbolName, sortIndex: valid.sortIndex, isHidden: false,
                updatedAt: valid.updatedAt, deletedAt: nil, replacementKey: nil
            ),
            // 预置分类的标识与「方向 + key」不符。
            BackupCategory(
                id: UUID(), direction: BookkeepingEntryType.expense.rawValue, key: "dining", customName: nil,
                symbolName: "fork.knife", sortIndex: 0, isHidden: false,
                updatedAt: valid.updatedAt, deletedAt: nil, replacementKey: nil
            ),
            // 「其他」是删除迁移的兜底分类，不能被标记删除。
            BackupCategory(
                id: BookkeepingCategoryKey.presetID(direction: .expense, key: "other"),
                direction: BookkeepingEntryType.expense.rawValue, key: "other", customName: nil,
                symbolName: "ellipsis.circle", sortIndex: 15, isHidden: false,
                updatedAt: valid.updatedAt, deletedAt: valid.updatedAt, replacementKey: "dining"
            )
        ]
        for category in invalidCategories {
            #expect(throws: BackupImportError.invalidContent) {
                try service.prepare(from: try encode(makeBackup(categories: [category])))
            }
        }
        #expect(throws: BackupImportError.invalidContent) {
            try service.prepare(from: try encode(makeBackup(categories: [valid, valid])))
        }
        _ = try service.prepare(from: try encode(makeBackup(categories: [valid])))
    }
}
