import Foundation
import SwiftData

/// 分类名称不符合规则的具体原因，编辑页据此实时提示并禁用保存。
enum CategoryNameIssue: Equatable, Sendable {
    /// 去掉首尾空白后为空。
    case empty

    /// 超过字数上限。
    case tooLong

    /// 同一方向下已有同名分类；关联值为已存在分类的当前显示名称。
    case duplicate(String)
}

/// 分类写入边界产生的错误。
enum CategoryRepositoryError: Error, Equatable {
    /// 指定方向下找不到该分类，或分类已删除。
    case categoryNotFound(String)

    /// 预置分类的名称和图标固定，不能修改。
    case presetNotEditable(String)

    /// 「其他」是删除迁移的兜底分类，不能删除。
    case otherNotDeletable

    /// 要一并删除的流水里有属于已停用账户的流水；删除会改动停用账户的余额，只能迁移。
    case transactionsInInactiveAccounts

    /// 名称不符合规则。
    case invalidName(CategoryNameIssue)

    /// 图标名称为空。
    case invalidSymbol

    /// 删除迁移的目标不是同方向、未删除的其他分类。
    case invalidMigrationTarget(String)
}

/// 删除分类时，该分类下流水的处理方式。
enum CategoryTransactionDisposition: Equatable, Sendable {
    /// 把流水迁到同方向的另一个分类。
    case migrate(to: String)

    /// 把流水一并删除，并撤销它们对账户余额的影响。
    case delete
}

/// 删除分类前的影响预估，删除页据此展示笔数并决定能否「一并删除流水」。
struct CategoryDeletionImpact: Hashable, Sendable {
    /// 该分类下的收支流水笔数。
    let transactionCount: Int

    /// 其中属于已停用账户的笔数；这些流水删除会改动停用账户余额，所以只能迁移。
    let inactiveAccountTransactionCount: Int

    /// 是否可以选择「一并删除流水」。
    var canDeleteTransactions: Bool { inactiveAccountTransactionCount == 0 }
}

/// 在主 actor 上管理分类设置的本地仓库。
///
/// 与其他 `Local*Repository` 一致：每个命令使用新鲜 context，内存修改完成后只保存一次，
/// 失败时整体回滚。写操作开始前会在同一 context 中补齐缺失的预置分类行。
@MainActor
final class LocalCategoryRepository {
    /// 分类名称的字数上限（按用户感知的字符计数）。
    static let nameLengthLimit = 10

    /// 应用或测试持有的完整本地财务容器。
    private let container: ModelContainer

    /// 测试可注入的保存前故障点；生产环境默认为空操作。
    private let beforeSave: () throws -> Void

    /// 创建分类仓库。
    ///
    /// - Parameters:
    ///   - container: 应用或测试持有的完整本地财务容器。
    ///   - beforeSave: 内存修改完成后、显式保存前执行的故障注入点。
    init(
        container: ModelContainer,
        beforeSave: @escaping () throws -> Void = {}
    ) {
        self.container = container
        self.beforeSave = beforeSave
    }

    // MARK: - 预置分类

    /// 幂等地补齐缺失的预置分类行；已存在的行保持用户设置不变。
    ///
    /// - Throws: 读取或保存失败时抛出底层错误。
    func ensurePresets() throws {
        let context = container.makeManualSaveContext()
        let inserted = try insertMissingPresets(in: context)
        guard inserted else { return }
        try context.saveOrRollback(beforeSave: beforeSave)
    }

    // MARK: - 新增与修改

    /// 新增一个自定义分类，排在同方向列表末尾。
    ///
    /// - Parameters:
    ///   - name: 用户输入的名称，会去掉首尾空白。
    ///   - symbolName: 选中的图标。
    ///   - direction: 收支方向。
    ///   - locale: 判断是否与预置分类重名时使用的语言环境。
    ///   - now: 注入的修改时间。
    /// - Returns: 新分类的 key。
    /// - Throws: 名称、图标不合法或保存失败时抛出错误。
    @discardableResult
    func create(
        name: String,
        symbolName: String,
        direction: BookkeepingEntryType,
        locale: Locale = .current,
        now: Date = .now
    ) throws -> String {
        let context = container.makeManualSaveContext()
        _ = try insertMissingPresets(in: context)
        let rows = try categories(direction: direction, in: context)
        let cleanedName = Self.cleanedName(name)
        if let issue = Self.nameIssue(
            cleanedName,
            direction: direction,
            excludingKey: nil,
            catalog: catalog(of: rows),
            locale: locale
        ) {
            throw CategoryRepositoryError.invalidName(issue)
        }
        guard !symbolName.isEmpty else { throw CategoryRepositoryError.invalidSymbol }

        let id = UUID()
        let key = BookkeepingCategoryKey.customKey(for: id)
        let nextIndex = (rows.filter { !$0.isTombstoned }.map(\.sortIndex).max() ?? -1) + 1
        context.insert(
            BookkeepingCategory(
                id: id,
                direction: direction,
                key: key,
                customName: cleanedName,
                symbolName: symbolName,
                sortIndex: nextIndex,
                updatedAt: now
            )
        )
        try context.saveOrRollback(beforeSave: beforeSave)
        return key
    }

    /// 修改自定义分类的名称和图标；预置分类的名称和图标固定，不能修改。
    ///
    /// - Parameters:
    ///   - key: 要修改的自定义分类 key。
    ///   - direction: 收支方向。
    ///   - name: 新名称。
    ///   - symbolName: 新图标。
    ///   - locale: 判断重名时使用的语言环境。
    ///   - now: 注入的修改时间。
    /// - Throws: 分类不存在、试图修改预置分类、名称或图标不合法、保存失败时抛出错误。
    func update(
        key: String,
        direction: BookkeepingEntryType,
        name: String,
        symbolName: String,
        locale: Locale = .current,
        now: Date = .now
    ) throws {
        let context = container.makeManualSaveContext()
        _ = try insertMissingPresets(in: context)
        let rows = try categories(direction: direction, in: context)
        guard let row = rows.first(where: { $0.key == key && !$0.isTombstoned }) else {
            throw CategoryRepositoryError.categoryNotFound(key)
        }
        guard !row.isPreset else { throw CategoryRepositoryError.presetNotEditable(key) }
        guard !symbolName.isEmpty else { throw CategoryRepositoryError.invalidSymbol }

        let cleanedName = Self.cleanedName(name)
        if let issue = Self.nameIssue(
            cleanedName,
            direction: direction,
            excludingKey: key,
            catalog: catalog(of: rows),
            locale: locale
        ) {
            throw CategoryRepositoryError.invalidName(issue)
        }
        row.customName = cleanedName
        row.symbolName = symbolName
        row.updatedAt = now
        try context.saveOrRollback(beforeSave: beforeSave)
    }

    /// 按给定顺序重排同方向的分类，`sortIndex` 重新从 0 连续编号。
    ///
    /// 未出现在 `orderedKeys` 中的未删除分类按原顺序排在后面，避免界面只传部分列表时丢失分类。
    ///
    /// - Parameters:
    ///   - orderedKeys: 用户拖拽后的分类 key 顺序。
    ///   - direction: 收支方向。
    ///   - now: 注入的修改时间。
    /// - Throws: 保存失败时抛出错误。
    func reorder(
        _ orderedKeys: [String],
        direction: BookkeepingEntryType,
        now: Date = .now
    ) throws {
        let context = container.makeManualSaveContext()
        _ = try insertMissingPresets(in: context)
        let rows = try categories(direction: direction, in: context)
            .filter { !$0.isTombstoned }
            .sorted { lhs, rhs in
                lhs.sortIndex == rhs.sortIndex ? lhs.key < rhs.key : lhs.sortIndex < rhs.sortIndex
            }
        var rowsByKey = Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var ordered: [BookkeepingCategory] = []
        for key in orderedKeys {
            if let row = rowsByKey.removeValue(forKey: key) {
                ordered.append(row)
            }
        }
        ordered += rows.filter { rowsByKey[$0.key] != nil }

        var changed = false
        for (index, row) in ordered.enumerated() where row.sortIndex != index {
            row.sortIndex = index
            row.updatedAt = now
            changed = true
        }
        guard changed else { return }
        try context.saveOrRollback(beforeSave: beforeSave)
    }

    // MARK: - 删除

    /// 预估删除某分类的影响，供删除页展示。
    ///
    /// - Parameters:
    ///   - key: 分类 key。
    ///   - direction: 收支方向。
    /// - Returns: 该分类下的流水笔数，以及其中属于已停用账户的笔数。
    /// - Throws: 读取失败时抛出底层错误。
    func deletionImpact(key: String, direction: BookkeepingEntryType) throws -> CategoryDeletionImpact {
        let context = container.makeManualSaveContext()
        let transactions = try context.fetch(Self.transactionDescriptor(key: key, direction: direction))
        return CategoryDeletionImpact(
            transactionCount: transactions.count,
            inactiveAccountTransactionCount: try Self.inactiveAccountTransactions(in: transactions, context: context).count
        )
    }

    /// 删除一个分类（预置或自定义，「其他」除外），并按用户选择迁移或删除它的流水；全部修改一次保存。
    ///
    /// 分类行不做物理删除，而是写入删除时间作为墓碑，为以后的同步预留：迁移时记下目标分类，
    /// 一并删除流水时迁移目标为空。预置分类的墓碑也让启动补齐不会把它重新加回来。
    ///
    /// - Parameters:
    ///   - key: 要删除的分类 key。
    ///   - direction: 收支方向。
    ///   - disposition: 流水迁往哪个分类，或一并删除。
    ///   - now: 注入的删除时间。
    /// - Throws: 分类不存在、试图删除「其他」、迁移目标不合法、要删除的流水属于停用账户、
    ///   余额计算或保存失败时抛出错误。
    func delete(
        key: String,
        direction: BookkeepingEntryType,
        transactions disposition: CategoryTransactionDisposition,
        now: Date = .now
    ) throws {
        guard key != BookkeepingCategoryKey.other else { throw CategoryRepositoryError.otherNotDeletable }
        let context = container.makeManualSaveContext()
        _ = try insertMissingPresets(in: context)
        let rows = try categories(direction: direction, in: context)
        guard let row = rows.first(where: { $0.key == key && !$0.isTombstoned }) else {
            throw CategoryRepositoryError.categoryNotFound(key)
        }
        let transactions = try context.fetch(Self.transactionDescriptor(key: key, direction: direction))

        switch disposition {
        case let .migrate(targetKey):
            guard targetKey != key,
                  rows.contains(where: { $0.key == targetKey && !$0.isTombstoned })
            else {
                throw CategoryRepositoryError.invalidMigrationTarget(targetKey)
            }
            for transaction in transactions {
                transaction.categoryRawValue = targetKey
            }
            row.replacementKey = targetKey
        case .delete:
            guard try Self.inactiveAccountTransactions(in: transactions, context: context).isEmpty else {
                throw CategoryRepositoryError.transactionsInInactiveAccounts
            }
            try LocalExpenseRepository.deleteTransactionsReversingBalances(transactions, in: context)
            row.replacementKey = nil
        }
        row.deletedAt = now
        row.updatedAt = now
        try context.saveOrRollback(beforeSave: beforeSave)
    }

    // MARK: - 名称规则

    /// 去掉名称首尾的空白和换行。
    static func cleanedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 检查分类名称；编辑页输入时实时调用，仓库保存时再校验一次。
    ///
    /// - Parameters:
    ///   - name: 待检查的名称，会先去掉首尾空白。
    ///   - direction: 收支方向；只在同方向内判断重名。
    ///   - excludingKey: 正在编辑的分类 key，不与自己比较。
    ///   - catalog: 当前分类目录，预置分类按当前语言的名称参与比较。
    ///   - locale: 预置分类名称和比较规则使用的语言环境。
    /// - Returns: 第一个不满足的规则；名称合法时返回 `nil`。
    static func nameIssue(
        _ name: String,
        direction: BookkeepingEntryType,
        excludingKey: String?,
        catalog: BookkeepingCategoryCatalog,
        locale: Locale
    ) -> CategoryNameIssue? {
        let cleaned = cleanedName(name)
        guard !cleaned.isEmpty else { return .empty }
        guard cleaned.count <= nameLengthLimit else { return .tooLong }
        let duplicate = catalog.items(for: direction).first { item in
            guard item.key != excludingKey else { return false }
            return item.title(locale: locale).compare(
                cleaned,
                options: [.caseInsensitive, .widthInsensitive],
                range: nil,
                locale: locale
            ) == .orderedSame
        }
        return duplicate.map { .duplicate($0.title(locale: locale)) }
    }

    // MARK: - 私有工具

    /// 在给定 context 中插入缺失的预置分类行，不保存。
    ///
    /// - Returns: 是否插入了新行。
    private func insertMissingPresets(in context: ModelContext) throws -> Bool {
        let existingIDs = Set(try context.fetch(FetchDescriptor<BookkeepingCategory>()).map(\.id))
        var inserted = false
        for preset in BookkeepingCategoryKey.allPresets where !existingIDs.contains(preset.id) {
            context.insert(
                BookkeepingCategory(
                    id: preset.id,
                    direction: preset.direction,
                    key: preset.key,
                    symbolName: preset.symbolName,
                    sortIndex: preset.sortIndex
                )
            )
            inserted = true
        }
        return inserted
    }

    /// 读取指定方向的全部分类行（含墓碑），包括本 context 中尚未保存的插入。
    private func categories(
        direction: BookkeepingEntryType,
        in context: ModelContext
    ) throws -> [BookkeepingCategory] {
        let directionRawValue = direction.rawValue
        return try context.fetch(
            FetchDescriptor<BookkeepingCategory>(
                predicate: #Predicate<BookkeepingCategory> { category in
                    category.directionRawValue == directionRawValue
                }
            )
        )
    }

    /// 用分类行构造目录，供名称校验使用。
    private func catalog(of rows: [BookkeepingCategory]) -> BookkeepingCategoryCatalog {
        BookkeepingCategoryCatalog(categories: rows)
    }

    /// 筛出账户已停用或不存在的流水；这些流水不能随分类删除。
    private static func inactiveAccountTransactions(
        in transactions: [AccountTransaction],
        context: ModelContext
    ) throws -> [AccountTransaction] {
        guard !transactions.isEmpty else { return [] }
        let activeAccountIDs = Set(
            try context.fetch(FetchDescriptor<Account>()).filter(\.isActive).map(\.id)
        )
        return transactions.filter { !activeAccountIDs.contains($0.accountID) }
    }

    /// 查询引用指定分类的收支流水。
    private static func transactionDescriptor(
        key: String,
        direction: BookkeepingEntryType
    ) -> FetchDescriptor<AccountTransaction> {
        let typeRawValue = switch direction {
        case .expense: AccountTransactionType.expense.rawValue
        case .income: AccountTransactionType.income.rawValue
        }
        let categoryKey: String? = key
        return FetchDescriptor<AccountTransaction>(
            predicate: #Predicate<AccountTransaction> { transaction in
                transaction.typeRawValue == typeRawValue
                    && transaction.categoryRawValue == categoryKey
            }
        )
    }
}

extension ModelContext {
    /// 判断收支流水引用的分类是否仍可使用：已删除的分类不可用；
    /// 预置分类即使还没有存储行也可用，自定义分类必须存在。
    ///
    /// - Parameters:
    ///   - key: 流水引用的分类 key。
    ///   - direction: 收支方向。
    func isCategoryAvailable(key: String, direction: BookkeepingEntryType) throws -> Bool {
        let directionRawValue = direction.rawValue
        let categoryKey = key
        let descriptor = FetchDescriptor<BookkeepingCategory>(
            predicate: #Predicate<BookkeepingCategory> { category in
                category.directionRawValue == directionRawValue
                    && category.key == categoryKey
            }
        )
        guard let row = try fetch(descriptor).first else {
            return BookkeepingCategoryKey.isPreset(key, direction: direction)
        }
        return !row.isTombstoned
    }
}
