import Foundation
import SwiftData

/// 备份导入边界产生的错误。
///
/// 错误不携带可展示的记录细节；用户界面只呈现按类别区分的通用文案，
/// 避免把财务数据细节泄露到弹窗之外的位置。
enum BackupImportError: Error, Equatable {
    /// 所选文件无法读取（含安全作用域访问失败）。
    case fileUnreadable

    /// 文件不是可解码的 yadoA 备份 JSON。
    case invalidFormat

    /// 备份格式版本不在当前 App 支持的范围内；关联值为文件声明的版本。
    case unsupportedVersion(Int)

    /// 备份可以解码，但记录无法通过业务校验（重复标识、悬空账户、非法金额等）。
    case invalidContent

    /// 写入本地存储失败；现有数据保持原样。
    case restoreFailed
}

/// 已通过完整校验、等待用户确认的恢复计划。
///
/// 计划只携带备份值快照；真正写入前会在恢复边界重新校验，
/// 因此持有计划不代表存储已被修改。
nonisolated struct BackupImportPlan: Equatable, Sendable {
    /// 已解码并通过校验的备份信封。
    let backup: BackupFile

    /// 当前设备是否已有账户或流水；为真时恢复会替换这些数据。
    let replacesExistingData: Bool

    /// 备份的导出时间，用于确认提示。
    var exportedAt: Date { backup.exportedAt }

    /// 备份包含的账户数量（含已停用账户）。
    var accountCount: Int { backup.accounts.count }

    /// 备份包含的流水数量。
    var transactionCount: Int { backup.transactions.count }
}

/// 在主 actor 上完成「读取 → 解码 → 校验 → 整体替换」的本系统备份恢复服务。
///
/// 恢复语义为整体替换：成功后本地业务数据与备份完全一致，备份之外的记录被删除。
/// 完整优先：任何一条记录不可靠时整次恢复失败，不写入部分数据；
/// 全部变更在单一 context 中一次保存，保存失败时回滚，现有数据保持原样。
@MainActor
final class BackupImportService {
    /// 应用或测试持有的完整本地财务容器。
    private let container: ModelContainer

    /// 测试可注入的保存前故障点；生产环境默认为空操作。
    private let beforeSave: () throws -> Void

    /// 创建备份导入服务。
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

    /// 读取用户选择的备份文件并生成恢复计划；不修改本地存储。
    ///
    /// - Parameter url: 文件选择器返回的地址，可能位于应用沙盒之外。
    /// - Returns: 已通过完整校验的恢复计划。
    /// - Throws: 读取、解码、版本或内容校验失败时抛出 `BackupImportError`。
    func prepare(from url: URL) throws -> BackupImportPlan {
        // 沙盒外文件必须在安全作用域内读取；沙盒内地址返回 false 也可直接读取。
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing { url.stopAccessingSecurityScopedResource() }
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BackupImportError.fileUnreadable
        }
        return try prepare(from: data)
    }

    /// 解码并校验备份数据，生成恢复计划；不修改本地存储。
    ///
    /// - Parameter data: 备份文件的原始 JSON 数据。
    /// - Returns: 已通过完整校验的恢复计划。
    /// - Throws: 解码、版本或内容校验失败时抛出 `BackupImportError`。
    func prepare(from data: Data) throws -> BackupImportPlan {
        let backup: BackupFile
        do {
            backup = try BackupFileEncoding.decode(data)
        } catch {
            throw BackupImportError.invalidFormat
        }
        _ = try Self.validatedRecords(from: backup)

        let context = container.makeManualSaveContext()
        do {
            let existingCount = try context.fetchCount(FetchDescriptor<Account>())
                + context.fetchCount(FetchDescriptor<AccountTransaction>())
            return BackupImportPlan(backup: backup, replacesExistingData: existingCount > 0)
        } catch {
            throw BackupImportError.restoreFailed
        }
    }

    /// 用备份整体替换本地业务数据。
    ///
    /// 与备份同 UUID 的现有记录原地覆盖，其余现有记录删除，缺少的记录插入；
    /// 不对同一唯一标识执行「先删后插」，避免唯一约束在同一次保存中冲突。
    ///
    /// - Parameter plan: 用户已确认的恢复计划。
    /// - Throws: 校验失败抛出对应 `BackupImportError`；保存失败抛出
    ///   `.restoreFailed`，此时本地数据保持恢复前的状态。
    func restore(_ plan: BackupImportPlan) throws {
        let records = try Self.validatedRecords(from: plan.backup)
        let context = container.makeManualSaveContext()
        do {
            var staleAccounts = Dictionary(
                try context.fetch(FetchDescriptor<Account>()).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for account in records.accounts {
                if let existing = staleAccounts.removeValue(forKey: account.id) {
                    existing.overwrite(with: account)
                } else {
                    context.insert(account)
                }
            }
            staleAccounts.values.forEach(context.delete)

            var staleTransactions = Dictionary(
                try context.fetch(FetchDescriptor<AccountTransaction>()).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for transaction in records.transactions {
                if let existing = staleTransactions.removeValue(forKey: transaction.id) {
                    existing.overwrite(with: transaction)
                } else {
                    context.insert(transaction)
                }
            }
            staleTransactions.values.forEach(context.delete)

            var staleCategories = Dictionary(
                try context.fetch(FetchDescriptor<BookkeepingCategory>()).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for category in records.categories {
                if let existing = staleCategories.removeValue(forKey: category.id) {
                    existing.overwrite(with: category)
                } else {
                    context.insert(category)
                }
            }
            staleCategories.values.forEach(context.delete)

            try restorePreference(plan.backup.bookkeepingPreference, in: context)
            try context.saveOrRollback(beforeSave: beforeSave)
        } catch {
            context.rollback()
            throw BackupImportError.restoreFailed
        }
    }

    /// 让 canonical 偏好与备份一致，并清理非 canonical 的残留偏好记录。
    ///
    /// 备份没有偏好记录时删除现有记录，保持「缺失」与「明确无默认」可区分；
    /// 失效指针原样写入，由读取端按当前账户重新解析。
    private func restorePreference(
        _ backupPreference: BackupBookkeepingPreference?,
        in context: ModelContext
    ) throws {
        var canonical: BookkeepingPreference?
        for preference in try context.fetch(FetchDescriptor<BookkeepingPreference>()) {
            if preference.id == BookkeepingPreference.singletonID, canonical == nil {
                canonical = preference
            } else {
                context.delete(preference)
            }
        }

        guard let backupPreference else {
            if let canonical { context.delete(canonical) }
            return
        }
        if let canonical {
            canonical.defaultAccountID = backupPreference.defaultAccountID
        } else {
            context.insert(
                BookkeepingPreference(defaultAccountID: backupPreference.defaultAccountID)
            )
        }
    }
}

// MARK: - 校验

extension BackupImportService {
    /// 当前 App 能够恢复的备份格式版本范围。
    static let supportedFormatVersions = 1...BackupFormatVersion.current

    /// 备份转换出的、尚未插入任何 context 的持久化模型。
    struct ValidatedRecords {
        /// 与备份账户一一对应的账户模型。
        let accounts: [Account]

        /// 与备份流水一一对应的流水模型。
        let transactions: [AccountTransaction]

        /// 备份中的分类设置，备份缺少的预置分类以默认值补齐。
        let categories: [BookkeepingCategory]
    }

    /// 校验整份备份并转换为持久化模型；任何一条记录不合法都整体失败。
    ///
    /// - Parameter backup: 已解码的备份信封。
    /// - Returns: 尚未插入 context 的账户与流水模型。
    /// - Throws: 版本不支持抛出 `.unsupportedVersion`，记录不合法抛出 `.invalidContent`。
    static func validatedRecords(from backup: BackupFile) throws -> ValidatedRecords {
        guard supportedFormatVersions.contains(backup.formatVersion) else {
            throw BackupImportError.unsupportedVersion(backup.formatVersion)
        }

        var accountIDs = Set<UUID>()
        let accounts = try backup.accounts.map { account in
            guard accountIDs.insert(account.id).inserted,
                  !account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !account.type.isEmpty,
                  !account.currencyCode.isEmpty,
                  let balance = decimal(from: account.balance)
            else { throw BackupImportError.invalidContent }

            // 未知账户类型原样保留：模型允许未来类型，由展示层安全降级。
            return Account(
                id: account.id,
                typeRawValue: account.type,
                templateID: account.templateID,
                name: account.name,
                note: account.note,
                lastFourDigits: account.lastFourDigits,
                balance: balance,
                currencyCode: account.currencyCode,
                createdAt: account.createdAt,
                updatedAt: account.updatedAt,
                deactivatedAt: account.deactivatedAt
            )
        }

        let categories = try validatedCategories(from: backup.categories)
        // 流水只能引用未删除的分类；缺少的预置分类已在上一步补齐，所以这里覆盖全部可用分类。
        let availableKeys = Set(
            categories
                .filter { !$0.isTombstoned }
                .map { "\($0.directionRawValue).\($0.key)" }
        )

        var transactionIDs = Set<UUID>()
        let transactions = try backup.transactions.map { transaction in
            // 流水工厂固定写入 CNY；其他币种若放行会被静默改写，必须拒绝。
            guard transactionIDs.insert(transaction.id).inserted,
                  accountIDs.contains(transaction.accountID),
                  transaction.currencyCode == "CNY"
            else { throw BackupImportError.invalidContent }

            let record: AccountTransaction
            do {
                record = try AccountTransaction.validatingPersistedFields(
                    id: transaction.id,
                    accountID: transaction.accountID,
                    typeRawValue: transaction.type,
                    categoryRawValue: transaction.category,
                    amount: try optionalDecimal(from: transaction.amount),
                    balanceBefore: try optionalDecimal(from: transaction.balanceBefore),
                    balanceAfter: try optionalDecimal(from: transaction.balanceAfter),
                    balanceDelta: try optionalDecimal(from: transaction.balanceDelta),
                    transactionDay: transaction.transactionDay,
                    note: transaction.note ?? "",
                    savedAt: transaction.savedAt,
                    title: transaction.title
                )
            } catch {
                throw BackupImportError.invalidContent
            }
            if let reference = (try? record.validatedPayload())?.categoryReference,
               !availableKeys.contains("\(reference.direction.rawValue).\(reference.key)") {
                throw BackupImportError.invalidContent
            }
            return record
        }
        return ValidatedRecords(accounts: accounts, transactions: transactions, categories: categories)
    }

    /// 校验备份中的分类设置，并为缺少的预置分类补上默认值。
    ///
    /// 预置分类的名称和图标固定，恢复时统一写回默认图标，不采用备份里的值。
    ///
    /// - Parameter backupCategories: 备份中的分类快照。
    /// - Returns: 尚未插入 context 的分类模型。
    /// - Throws: 标识重复、方向或 key 不合法、预置分类标识不匹配、「其他」被标记删除、
    ///   自定义分类缺少名称时抛出 `.invalidContent`。
    private static func validatedCategories(
        from backupCategories: [BackupCategory]
    ) throws -> [BookkeepingCategory] {
        var ids = Set<UUID>()
        var keys = Set<String>()
        var categories = try backupCategories.map { category in
            guard ids.insert(category.id).inserted,
                  let direction = BookkeepingEntryType(rawValue: category.direction),
                  BookkeepingCategoryKey.isValid(category.key, direction: direction),
                  keys.insert("\(direction.rawValue).\(category.key)").inserted,
                  !category.symbolName.isEmpty
            else { throw BackupImportError.invalidContent }

            let preset = BookkeepingCategoryKey.preset(direction: direction, key: category.key)
            if let preset {
                // 「其他」是删除迁移的兜底目标，必须始终可用。
                guard category.id == preset.id,
                      category.deletedAt == nil || category.key != BookkeepingCategoryKey.other
                else { throw BackupImportError.invalidContent }
            } else {
                let name = LocalCategoryRepository.cleanedName(category.customName ?? "")
                guard !name.isEmpty else { throw BackupImportError.invalidContent }
            }
            return BookkeepingCategory(
                id: category.id,
                direction: direction,
                key: category.key,
                customName: preset == nil ? category.customName : nil,
                symbolName: preset?.symbolName ?? category.symbolName,
                sortIndex: category.sortIndex,
                updatedAt: category.updatedAt,
                deletedAt: category.deletedAt,
                replacementKey: category.replacementKey
            )
        }
        for preset in BookkeepingCategoryKey.allPresets where !ids.contains(preset.id) {
            categories.append(
                BookkeepingCategory(
                    id: preset.id,
                    direction: preset.direction,
                    key: preset.key,
                    symbolName: preset.symbolName,
                    sortIndex: preset.sortIndex
                )
            )
        }
        return categories
    }

    /// 解析可选金额：缺省保持 `nil`，存在但非法时抛错而不是静默丢弃。
    private static func optionalDecimal(from text: String?) throws -> Decimal? {
        guard let text else { return nil }
        guard let value = decimal(from: text) else { throw BackupImportError.invalidContent }
        return value
    }

    /// 严格解析备份中的十进制金额字符串（`Decimal.description` 的表达）。
    ///
    /// `Decimal(string:)` 会接受 `"12abc"` 这类前缀合法的输入，因此先做整串格式校验。
    private static func decimal(from text: String) -> Decimal? {
        guard text.wholeMatch(of: #/-?[0-9]+(\.[0-9]+)?/#) != nil else { return nil }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }
}

// MARK: - 原地覆盖

private extension Account {
    /// 用已校验的备份账户覆盖除稳定标识外的全部持久化字段。
    func overwrite(with other: Account) {
        typeRawValue = other.typeRawValue
        templateID = other.templateID
        name = other.name
        note = other.note
        lastFourDigits = other.lastFourDigits
        balance = other.balance
        currencyCode = other.currencyCode
        createdAt = other.createdAt
        updatedAt = other.updatedAt
        deactivatedAt = other.deactivatedAt
    }
}

private extension BookkeepingCategory {
    /// 用已校验的备份分类覆盖除稳定标识外的全部持久化字段。
    func overwrite(with other: BookkeepingCategory) {
        directionRawValue = other.directionRawValue
        key = other.key
        customName = other.customName
        symbolName = other.symbolName
        sortIndex = other.sortIndex
        updatedAt = other.updatedAt
        deletedAt = other.deletedAt
        replacementKey = other.replacementKey
    }
}

private extension AccountTransaction {
    /// 用已校验的备份流水覆盖除稳定标识外的全部持久化字段。
    func overwrite(with other: AccountTransaction) {
        accountID = other.accountID
        typeRawValue = other.typeRawValue
        categoryRawValue = other.categoryRawValue
        amount = other.amount
        title = other.title
        balanceBefore = other.balanceBefore
        balanceAfter = other.balanceAfter
        balanceDelta = other.balanceDelta
        currencyCode = other.currencyCode
        transactionDay = other.transactionDay
        note = other.note
        savedAt = other.savedAt
    }
}
