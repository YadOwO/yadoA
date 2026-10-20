import Foundation
import Testing
@testable import yadoA

@Suite("分类 key 规则与分类目录")
@MainActor
struct BookkeepingCategoryCatalogTests {
    private let english = Locale(identifier: "en")

    @Test("自定义 key 使用 custom.<小写 uuid>，预置 key 只在所属方向合法")
    func keyFormatRules() {
        let id = UUID()
        let customKey = BookkeepingCategoryKey.customKey(for: id)

        #expect(customKey == "custom.\(id.uuidString.lowercased())")
        #expect(BookkeepingCategoryKey.isCustom(customKey))
        #expect(BookkeepingCategoryKey.isValid(customKey, direction: .expense))
        #expect(BookkeepingCategoryKey.isValid(customKey, direction: .income))
        #expect(!BookkeepingCategoryKey.isCustom("custom.\(id.uuidString)"))
        #expect(!BookkeepingCategoryKey.isCustom("custom.not-a-uuid"))
        #expect(BookkeepingCategoryKey.isValid("dining", direction: .expense))
        #expect(!BookkeepingCategoryKey.isValid("dining", direction: .income))
        #expect(BookkeepingCategoryKey.isValid("salary", direction: .income))
        #expect(!BookkeepingCategoryKey.isValid("salary", direction: .expense))
    }

    @Test("预置分类的行标识由方向和 key 确定，跨方向的「其他」不冲突")
    func presetIDsAreDeterministicAndUnique() {
        let first = BookkeepingCategoryKey.presetID(direction: .expense, key: "dining")
        let second = BookkeepingCategoryKey.presetID(direction: .expense, key: "dining")
        #expect(first == second)
        #expect(
            BookkeepingCategoryKey.presetID(direction: .expense, key: "other")
                != BookkeepingCategoryKey.presetID(direction: .income, key: "other")
        )
        let ids = BookkeepingCategoryKey.allPresets.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.count == ExpenseCategory.allCases.count + IncomeCategory.allCases.count)
    }

    @Test("没有存储行时目录按枚举顺序提供全部预置分类")
    func presetsCatalogFallsBackToDefaults() {
        let catalog = BookkeepingCategoryCatalog.presets

        #expect(catalog.items(for: .expense).map(\.key) == ExpenseCategory.allCases.map(\.rawValue))
        #expect(catalog.items(for: .income).map(\.key) == IncomeCategory.allCases.map(\.rawValue))
        #expect(catalog.defaultKey(for: .expense) == "dining")
        #expect(catalog.defaultKey(for: .income) == "salary")
    }

    @Test("存储的排序、隐藏、图标覆盖和自定义分类生效，墓碑不出现在列表中")
    func storedSettingsOverrideDefaults() {
        let customKey = BookkeepingCategoryKey.customKey(for: UUID())
        let deletedKey = BookkeepingCategoryKey.customKey(for: UUID())
        let catalog = BookkeepingCategoryCatalog(items: [
            item(.expense, "dining", sortIndex: 5, isHidden: true),
            item(.expense, "shopping", symbol: "handbag", sortIndex: -1),
            item(.expense, customKey, name: "咖啡", symbol: "cup.and.saucer", sortIndex: 0),
            item(.expense, deletedKey, name: "旧分类", sortIndex: 1, isDeleted: true, replacementKey: "other")
        ])

        let keys = catalog.items(for: .expense).map(\.key)
        #expect(keys.first == "shopping")
        #expect(keys.dropFirst().first == customKey)
        #expect(!keys.contains(deletedKey))
        #expect(catalog.visibleItems(for: .expense).allSatisfy { !$0.isHidden })
        #expect(catalog.hiddenItems(for: .expense).map(\.key) == ["dining"])
        #expect(catalog.item(direction: .expense, key: "shopping")?.symbolName == "handbag")
        #expect(catalog.item(direction: .expense, key: customKey)?.title(locale: english) == "咖啡")
        #expect(catalog.defaultKey(for: .expense) == "shopping")

        // 墓碑仍可按 key 解析，用于提示迁移目标。
        let tombstone = catalog.item(direction: .expense, key: deletedKey)
        #expect(tombstone?.isDeleted == true)
        #expect(tombstone?.replacementKey == "other")
    }

    @Test("记账面板补上当前已选但已隐藏的分类，已删除的不补")
    func pickerKeepsHiddenSelection() {
        let deletedKey = BookkeepingCategoryKey.customKey(for: UUID())
        let catalog = BookkeepingCategoryCatalog(items: [
            item(.expense, "pets", sortIndex: 11, isHidden: true),
            item(.expense, deletedKey, name: "旧", sortIndex: 0, isDeleted: true)
        ])

        #expect(!catalog.pickerItems(for: .expense, including: nil).contains { $0.key == "pets" })
        #expect(catalog.pickerItems(for: .expense, including: "pets").last?.key == "pets")
        #expect(!catalog.pickerItems(for: .expense, including: deletedKey).contains { $0.key == deletedKey })
    }

    @Test("未知 key 按同方向「其他」降级展示")
    func unknownKeyResolvesToOther() {
        let unknown = BookkeepingCategoryKey.customKey(for: UUID())
        let resolved = BookkeepingCategoryCatalog.presets.resolvedItem(direction: .income, key: unknown)

        #expect(resolved.key == "other")
        #expect(resolved.direction == .income)
    }

    @Test("「其他」不能隐藏，预置分类不能改名或删除")
    func capabilityFlags() {
        let catalog = BookkeepingCategoryCatalog.presets
        let other = catalog.item(direction: .expense, key: "other")
        let dining = catalog.item(direction: .expense, key: "dining")
        let custom = item(.expense, BookkeepingCategoryKey.customKey(for: UUID()), name: "咖啡")

        #expect(other?.canHide == false)
        #expect(dining?.canHide == true)
        #expect(dining?.canRename == false)
        #expect(dining?.canDelete == false)
        #expect(custom.canRename)
        #expect(custom.canDelete)
        #expect(custom.canHide)
    }

    @Test("收支载荷接受自定义 key，拒绝格式错误或方向不符的 key")
    func payloadValidatesKeyFormat() throws {
        let customKey = BookkeepingCategoryKey.customKey(for: UUID())
        let custom = try AccountTransaction.validatingExpense(
            id: UUID(),
            accountID: UUID(),
            categoryKey: customKey,
            amount: 10,
            transactionDay: 20261020
        )
        #expect(try custom.validatedPayload() == .expense(categoryKey: customKey, amount: 10))
        #expect(custom.category == nil)

        #expect(throws: AccountTransactionValidationError.invalidPayload) {
            try AccountTransaction.validatingExpense(
                id: UUID(), accountID: UUID(), categoryKey: "custom.oops",
                amount: 10, transactionDay: 20261020
            )
        }
        #expect(throws: AccountTransactionValidationError.invalidPayload) {
            try AccountTransaction.validatingIncome(
                id: UUID(), accountID: UUID(), categoryKey: "dining",
                amount: 10, transactionDay: 20261020
            )
        }
    }

    @Test("载荷通过目录解析自定义名称和图标")
    func payloadResolvesThroughCatalog() {
        let customKey = BookkeepingCategoryKey.customKey(for: UUID())
        let catalog = BookkeepingCategoryCatalog(items: [
            item(.expense, customKey, name: "咖啡", symbol: "cup.and.saucer", sortIndex: 20)
        ])
        let payload = AccountTransactionPayload.expense(categoryKey: customKey, amount: 5)

        #expect(payload.categoryTitle(locale: english, catalog: catalog) == "咖啡")
        #expect(payload.categorySymbolName(in: catalog) == "cup.and.saucer")
        #expect(payload.categoryID == "expense.\(customKey)")
        #expect(payload.categoryTitle(locale: english) == "Other")
    }

    /// 构造分类快照。
    private func item(
        _ direction: BookkeepingEntryType,
        _ key: String,
        name: String? = nil,
        symbol: String = "tag",
        sortIndex: Int = 0,
        isHidden: Bool = false,
        isDeleted: Bool = false,
        replacementKey: String? = nil
    ) -> BookkeepingCategoryItem {
        BookkeepingCategoryItem(
            direction: direction,
            key: key,
            customName: name,
            symbolName: symbol,
            sortIndex: sortIndex,
            isHidden: isHidden,
            isDeleted: isDeleted,
            replacementKey: replacementKey
        )
    }
}
