import Foundation
import SwiftData
import Testing
@testable import yadoA

@Suite("分类仓库")
@MainActor
struct LocalCategoryRepositoryTests {
    private let chinese = Locale(identifier: "zh-Hans")

    @Test("补齐预置分类是幂等的，且不覆盖用户设置")
    func ensurePresetsIsIdempotent() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let repository = LocalCategoryRepository(container: container)

        try repository.ensurePresets()
        try repository.setHidden(true, key: "pets", direction: .expense)
        try repository.ensurePresets()

        let rows = try categories(in: container)
        #expect(rows.count == BookkeepingCategoryKey.allPresets.count)
        #expect(rows.first { $0.key == "pets" }?.isHidden == true)
    }

    @Test("新增自定义分类排在末尾，并出现在记账面板中")
    func createAppendsToEnd() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let repository = LocalCategoryRepository(container: container)

        let key = try repository.create(
            name: "  咖啡  ", symbolName: "cup.and.saucer", direction: .expense, locale: chinese
        )

        let current = try catalog(in: container)
        #expect(BookkeepingCategoryKey.isCustom(key))
        #expect(current.visibleItems(for: .expense).last?.key == key)
        #expect(current.item(direction: .expense, key: key)?.customName == "咖啡")
        #expect(current.items(for: .income).allSatisfy { $0.key != key })
    }

    @Test("名称规则：不能为空、不超过 10 个字、同方向不能与预置或自定义分类重名")
    func nameRules() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let repository = LocalCategoryRepository(container: container)

        #expect(throws: CategoryRepositoryError.invalidName(.empty)) {
            try repository.create(name: "   ", symbolName: "tag", direction: .expense, locale: chinese)
        }
        #expect(throws: CategoryRepositoryError.invalidName(.tooLong)) {
            try repository.create(name: "一二三四五六七八九十一", symbolName: "tag", direction: .expense, locale: chinese)
        }
        #expect(throws: CategoryRepositoryError.invalidName(.duplicate("交通"))) {
            try repository.create(name: "交通", symbolName: "bus", direction: .expense, locale: chinese)
        }
        // 收入方向没有「交通」，可以创建。
        try repository.create(name: "交通", symbolName: "bus", direction: .income, locale: chinese)
        // 正好 10 个字可以保存。
        try repository.create(name: "一二三四五六七八九十", symbolName: "tag", direction: .expense, locale: chinese)
        try repository.create(name: "Coffee", symbolName: "mug", direction: .expense, locale: chinese)
        #expect(throws: CategoryRepositoryError.invalidName(.duplicate("Coffee"))) {
            try repository.create(name: "coffee", symbolName: "mug", direction: .expense, locale: chinese)
        }
        #expect(throws: CategoryRepositoryError.invalidSymbol) {
            try repository.create(name: "茶", symbolName: "", direction: .expense, locale: chinese)
        }
    }

    @Test("编辑时不与自己比较重名，改名后历史流水显示新名称")
    func renameCustomCategory() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let repository = LocalCategoryRepository(container: container)
        let key = try repository.create(name: "咖啡", symbolName: "mug", direction: .expense, locale: chinese)
        let transaction = try insertExpense(categoryKey: key, in: container)

        try repository.update(key: key, direction: .expense, name: "咖啡", symbolName: "cup.and.saucer", locale: chinese)
        try repository.update(key: key, direction: .expense, name: "下午茶", symbolName: "cup.and.saucer", locale: chinese)

        let row = try #require(HomeOverviewPresentation.row(
            for: transaction, locale: chinese, catalog: try catalog(in: container)
        ))
        #expect(row.title == "下午茶")
        #expect(row.symbolName == "cup.and.saucer")
    }

    @Test("预置分类只能换图标，不能改名或删除；「其他」不能隐藏")
    func presetRestrictions() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let repository = LocalCategoryRepository(container: container)

        try repository.update(key: "dining", direction: .expense, name: nil, symbolName: "takeoutbag.and.cup.and.straw")
        #expect(try catalog(in: container).item(direction: .expense, key: "dining")?.symbolName
            == "takeoutbag.and.cup.and.straw")

        #expect(throws: CategoryRepositoryError.presetNotEditable("dining")) {
            try repository.update(key: "dining", direction: .expense, name: "吃饭", symbolName: "fork.knife")
        }
        #expect(throws: CategoryRepositoryError.presetNotEditable("dining")) {
            try repository.delete(key: "dining", direction: .expense, migratingTo: "other")
        }
        #expect(throws: CategoryRepositoryError.otherNotHideable) {
            try repository.setHidden(true, key: "other", direction: .expense)
        }
    }

    @Test("隐藏后不出现在记账面板，历史流水照常展示；恢复后回到面板")
    func hideAndRestore() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let repository = LocalCategoryRepository(container: container)
        let transaction = try insertExpense(categoryKey: "pets", in: container)

        try repository.setHidden(true, key: "pets", direction: .expense)
        var current = try catalog(in: container)
        #expect(!current.visibleItems(for: .expense).contains { $0.key == "pets" })
        #expect(current.hiddenItems(for: .expense).map(\.key) == ["pets"])
        #expect(HomeOverviewPresentation.row(for: transaction, catalog: current) != nil)

        try repository.setHidden(false, key: "pets", direction: .expense)
        current = try catalog(in: container)
        #expect(current.visibleItems(for: .expense).contains { $0.key == "pets" })
    }

    @Test("排序后 sortIndex 连续，未传入的分类按原顺序排在后面")
    func reorderAssignsContiguousIndexes() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let repository = LocalCategoryRepository(container: container)

        try repository.reorder(["other", "travel"], direction: .expense)

        let items = try catalog(in: container).items(for: .expense)
        #expect(items.map(\.sortIndex) == Array(0..<items.count))
        #expect(items.prefix(3).map(\.key) == ["other", "travel", "dining"])
        #expect(items.count == ExpenseCategory.allCases.count)
    }

    @Test("删除自定义分类把流水迁到目标分类，并保留墓碑")
    func deleteMigratesTransactions() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let repository = LocalCategoryRepository(container: container)
        let key = try repository.create(name: "咖啡", symbolName: "mug", direction: .expense, locale: chinese)
        let first = try insertExpense(categoryKey: key, in: container)
        let second = try insertExpense(categoryKey: key, in: container)
        _ = try insertExpense(categoryKey: "travel", in: container)

        #expect(try repository.transactionCount(key: key, direction: .expense) == 2)
        try repository.delete(key: key, direction: .expense, migratingTo: "dining")

        let transactions = try ModelContext(container).fetch(FetchDescriptor<AccountTransaction>())
        #expect(transactions.first { $0.id == first.id }?.categoryRawValue == "dining")
        #expect(transactions.first { $0.id == second.id }?.categoryRawValue == "dining")
        #expect(transactions.filter { $0.categoryRawValue == "travel" }.count == 1)
        #expect(try repository.transactionCount(key: key, direction: .expense) == 0)

        let tombstone = try #require(try categories(in: container).first { $0.key == key })
        #expect(tombstone.isTombstoned)
        #expect(tombstone.replacementKey == "dining")
        #expect(!(try catalog(in: container)).items(for: .expense).contains { $0.key == key })
    }

    @Test("删除迁移的目标必须是同方向、未隐藏且不是自己")
    func deleteRejectsInvalidTargets() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let repository = LocalCategoryRepository(container: container)
        let key = try repository.create(name: "咖啡", symbolName: "mug", direction: .expense, locale: chinese)
        try repository.setHidden(true, key: "pets", direction: .expense)

        for target in [key, "pets", "salary", "missing"] {
            #expect(throws: CategoryRepositoryError.invalidMigrationTarget(target)) {
                try repository.delete(key: key, direction: .expense, migratingTo: target)
            }
        }
    }

    @Test("保存失败时流水和分类都保持原样")
    func deleteIsAtomic() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let key = try LocalCategoryRepository(container: container)
            .create(name: "咖啡", symbolName: "mug", direction: .expense, locale: chinese)
        let transaction = try insertExpense(categoryKey: key, in: container)
        let failing = LocalCategoryRepository(container: container, beforeSave: { throw CategorySaveFailure() })

        #expect(throws: CategorySaveFailure.self) {
            try failing.delete(key: key, direction: .expense, migratingTo: "other")
        }

        let stored = try ModelContext(container).fetch(FetchDescriptor<AccountTransaction>())
        #expect(stored.first { $0.id == transaction.id }?.categoryRawValue == key)
        #expect(try categories(in: container).first { $0.key == key }?.isTombstoned == false)
    }

    @Test("记账时拒绝引用已删除的自定义分类，预置分类无需存储行也可记账")
    func expenseRepositoryRequiresAvailableCategory() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let accountID = try insertAccount(in: container)
        let categoryRepository = LocalCategoryRepository(container: container)
        let expenseRepository = LocalExpenseRepository(container: container)

        try expenseRepository.save(DiningExpenseDraft(
            accountID: accountID, amountText: "10", transactionDay: 20261020
        ))

        let key = try categoryRepository.create(name: "咖啡", symbolName: "mug", direction: .expense, locale: chinese)
        try expenseRepository.save(DiningExpenseDraft(
            accountID: accountID, expenseCategoryKey: key, amountText: "10", transactionDay: 20261020
        ))
        try categoryRepository.delete(key: key, direction: .expense, migratingTo: "other")

        #expect(throws: ExpenseRepositoryError.categoryUnavailable(key)) {
            try expenseRepository.save(DiningExpenseDraft(
                accountID: accountID, expenseCategoryKey: key, amountText: "10", transactionDay: 20261020
            ))
        }
        let unknown = BookkeepingCategoryKey.customKey(for: UUID())
        #expect(throws: ExpenseRepositoryError.categoryUnavailable(unknown)) {
            try expenseRepository.save(DiningExpenseDraft(
                accountID: accountID, expenseCategoryKey: unknown, amountText: "10", transactionDay: 20261020
            ))
        }
    }

    @Test("清除全部数据后分类恢复为预置默认值")
    func resetRestoresPresetDefaults() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let repository = LocalCategoryRepository(container: container)
        try repository.create(name: "咖啡", symbolName: "mug", direction: .expense, locale: chinese)
        try repository.setHidden(true, key: "pets", direction: .expense)

        try LocalDataResetService(container: container).eraseAll()

        let rows = try categories(in: container)
        #expect(rows.count == BookkeepingCategoryKey.allPresets.count)
        #expect(rows.allSatisfy { $0.isPreset && !$0.isHidden })
    }

    // MARK: - 夹具

    /// 读取全部分类行。
    private func categories(in container: ModelContainer) throws -> [BookkeepingCategory] {
        try ModelContext(container).fetch(FetchDescriptor<BookkeepingCategory>())
    }

    /// 读取当前分类目录。
    private func catalog(in container: ModelContainer) throws -> BookkeepingCategoryCatalog {
        BookkeepingCategoryCatalog(categories: try categories(in: container))
    }

    /// 直接插入一笔指定分类的支出，不经过账户余额联动。
    @discardableResult
    private func insertExpense(categoryKey: String, in container: ModelContainer) throws -> AccountTransaction {
        let transaction = try AccountTransaction.validatingExpense(
            id: UUID(), accountID: UUID(), categoryKey: categoryKey,
            amount: 10, transactionDay: 20261020
        )
        let context = ModelContext(container)
        context.insert(transaction)
        try context.save()
        return transaction
    }

    /// 插入一个可记账的现金账户。
    private func insertAccount(in container: ModelContainer) throws -> UUID {
        let account = Account(
            id: UUID(), typeRawValue: AccountType.cash.rawValue, templateID: nil, name: "现金",
            note: nil, lastFourDigits: nil, balance: 100, currencyCode: "CNY",
            createdAt: .now, updatedAt: .now
        )
        let context = ModelContext(container)
        context.insert(account)
        try context.save()
        return account.id
    }
}

private struct CategorySaveFailure: Error {}
