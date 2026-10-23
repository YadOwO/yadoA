import Foundation
import OSLog
import SwiftData

/// 应用一批服务端记录的结果，同步引擎据此决定后续动作并汇报。
struct SyncApplyOutcome: Equatable {
    /// 写入或删除了本地数据的记录数。
    var appliedCount = 0

    /// 本地有更新的待上传版本、因而保留本地的记录数。
    var keptLocalCount = 0

    /// 内容校验失败或类型不认识、被跳过的记录数。
    var skippedCount = 0

    /// 远端已删除、但本地仍有流水引用而保留并重新登记上传的账户。
    var resurrectedAccountIDs: Set<UUID> = []

    /// 已删除的分类，需要把本地仍引用它的流水迁走。
    var categoryMigrations: Set<SyncCategoryMigration> = []
}

/// 远端删除了一个分类后，本地流水的迁移目标。
struct SyncCategoryMigration: Hashable {
    /// 分类方向。
    let direction: BookkeepingEntryType

    /// 已删除的分类 key。
    let key: String

    /// 删除时指定的迁移目标；为 nil 表示对方「随分类删除流水」。
    let replacementKey: String?
}

/// 把服务端记录写入本地模型（KTD11），只修改 context，不保存。
///
/// 规则：
/// - 本地台账有待上传的修改且裁决时钟更新时，保留本地版本，等下一轮推送；
/// - 远端删除的账户若本地仍有流水引用，忽略这次删除，并按当前时间重新登记以便推送回去；
/// - 远端删除的分类，记下迁移需求，由调用方在单独一次「登记修改」的保存中迁移本地流水；
/// - 内容校验失败的记录跳过并记日志，不中断整批。
///
/// 应用时不调用 `SyncChangeTracker`：台账由这里直接改成「与服务端一致」。
enum SyncRecordApplier {
    /// 同步日志。
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "yadoA", category: "Sync")

    /// 记录内容不合法，跳过。
    private struct InvalidRecord: Error {}

    /// 应用一批记录。
    ///
    /// 同一条记录出现多次时只取序号最大的版本；先应用新增和修改，再应用删除，删除账户放在最后，
    /// 这样判断「账户是否仍被流水引用」时已经看到了本批全部流水的变化。
    ///
    /// - Parameters:
    ///   - records: 服务端记录。
    ///   - context: 调用方的 manual-save context。
    ///   - ledger: 全部台账，按唯一键索引；会同步增删。
    ///   - now: 重新登记时使用的时间。
    /// - Returns: 应用结果。
    /// - Throws: 读取本地数据或编码同步内容失败时抛出底层错误。
    static func apply(
        _ records: [SyncRemoteRecord],
        in context: ModelContext,
        ledger: inout [String: SyncLedgerEntry],
        now: Date
    ) throws -> SyncApplyOutcome {
        var outcome = SyncApplyOutcome()
        var latest: [String: (entityType: SyncEntityType, record: SyncRemoteRecord)] = [:]
        for record in records {
            guard let entityType = record.entityType else {
                // 新版本服务端的类型，本版本不认识；升级后由同步格式版本触发全量同步补回
                outcome.skippedCount += 1
                continue
            }
            let key = SyncLedgerEntry.key(entityType: entityType, recordID: record.recordID)
            if let existing = latest[key], existing.record.serverVersion >= record.serverVersion { continue }
            latest[key] = (entityType, record)
        }

        let ordered = latest.values.sorted { lhs, rhs in
            let lhsPhase = applyPhase(lhs.entityType, isDeleted: lhs.record.isDeleted)
            let rhsPhase = applyPhase(rhs.entityType, isDeleted: rhs.record.isDeleted)
            if lhsPhase != rhsPhase { return lhsPhase < rhsPhase }
            return lhs.record.serverVersion < rhs.record.serverVersion
        }

        for (entityType, record) in ordered {
            let key = SyncLedgerEntry.key(entityType: entityType, recordID: record.recordID)
            if let entry = ledger[key], entry.hasPendingChanges, entry.modifiedAt > record.modifiedAt {
                outcome.keptLocalCount += 1
                continue
            }
            if record.isDeleted {
                try removeLocal(
                    entityType: entityType,
                    recordID: record.recordID,
                    in: context,
                    ledger: &ledger,
                    now: now,
                    outcome: &outcome
                )
                continue
            }
            do {
                guard let payload = record.payload else { throw InvalidRecord() }
                let model = try upsert(entityType, recordID: record.recordID, payload: payload.jsonData(), in: context)
                guard let encoded = try SyncPayloadCoder.record(for: model) else { throw InvalidRecord() }
                if let entry = ledger[key] {
                    entry.markSynced(modifiedAt: record.modifiedAt, payloadHash: encoded.payloadHash)
                } else {
                    let entry = SyncLedgerEntry.synced(
                        entityType: entityType,
                        recordID: record.recordID,
                        modifiedAt: record.modifiedAt,
                        payloadHash: encoded.payloadHash
                    )
                    context.insert(entry)
                    ledger[key] = entry
                }
                if let category = model as? BookkeepingCategory,
                   category.isTombstoned,
                   let direction = category.direction {
                    outcome.categoryMigrations.insert(
                        SyncCategoryMigration(direction: direction, key: category.key, replacementKey: category.replacementKey)
                    )
                }
                outcome.appliedCount += 1
            } catch is InvalidRecord, is DecodingError, is AccountTransactionValidationError {
                logger.error("跳过不合法的同步记录：\(entityType.rawValue, privacy: .public) v\(record.serverVersion)")
                outcome.skippedCount += 1
            }
        }
        return outcome
    }

    /// 删除一条本地记录及其台账；账户仍被流水引用时改为保留并重新登记上传。
    ///
    /// 用于应用远端墓碑，以及全量同步时删除云端已不存在的记录（此时即使本地有待上传的修改也删除）。
    ///
    /// - Parameters:
    ///   - entityType: 记录类型。
    ///   - recordID: 业务记录 UUID。
    ///   - context: 调用方的 manual-save context。
    ///   - ledger: 全部台账；会同步删除对应项。
    ///   - now: 保留账户时重新登记的时间。
    ///   - outcome: 累计的应用结果。
    /// - Throws: 读取本地数据或编码同步内容失败时抛出底层错误。
    static func removeLocal(
        entityType: SyncEntityType,
        recordID: UUID,
        in context: ModelContext,
        ledger: inout [String: SyncLedgerEntry],
        now: Date,
        outcome: inout SyncApplyOutcome
    ) throws {
        let key = SyncLedgerEntry.key(entityType: entityType, recordID: recordID)
        switch entityType {
        case .account:
            if let account = try context.account(id: recordID) {
                if try isReferenced(accountID: recordID, in: context) {
                    try reregister(account, entityType: .account, key: key, in: context, ledger: &ledger, now: now)
                    outcome.resurrectedAccountIDs.insert(recordID)
                    return
                }
                context.delete(account)
            }
        case .transaction:
            if let transaction = try context.transaction(id: recordID) {
                context.delete(transaction)
            }
        case .category:
            if let row = try category(id: recordID, in: context) {
                context.delete(row)
            }
        case .preference:
            if let row = try preference(id: recordID, in: context) {
                context.delete(row)
            }
        }
        if let entry = ledger.removeValue(forKey: key) {
            context.delete(entry)
        }
        outcome.appliedCount += 1
    }

    /// 应用顺序：0 新增和修改，1 删除流水、分类、偏好，2 删除账户。
    static func applyPhase(_ entityType: SyncEntityType, isDeleted: Bool) -> Int {
        guard isDeleted else { return 0 }
        return entityType == .account ? 2 : 1
    }

    // MARK: - 写入模型

    /// 按类型解码并校验同步内容，覆盖已有模型或插入新模型。
    ///
    /// - Returns: context 中对应的模型。
    /// - Throws: 内容不合法时抛出 `InvalidRecord`、`DecodingError` 或 `AccountTransactionValidationError`。
    private static func upsert(
        _ entityType: SyncEntityType,
        recordID: UUID,
        payload: Data,
        in context: ModelContext
    ) throws -> any PersistentModel {
        let decoder = BackupFileEncoding.makeDecoder()
        switch entityType {
        case .account:
            return try upsertAccount(decoder.decode(BackupAccount.self, from: payload), recordID: recordID, in: context)
        case .transaction:
            return try upsertTransaction(decoder.decode(BackupTransaction.self, from: payload), recordID: recordID, in: context)
        case .category:
            return try upsertCategory(decoder.decode(BackupCategory.self, from: payload), recordID: recordID, in: context)
        case .preference:
            return try upsertPreference(
                decoder.decode(BackupBookkeepingPreference.self, from: payload),
                recordID: recordID,
                in: context
            )
        }
    }

    /// 写入账户；余额不在同步内容里，新账户先取期初余额，之后由调用方统一重算。
    private static func upsertAccount(_ dto: BackupAccount, recordID: UUID, in context: ModelContext) throws -> Account {
        guard dto.id == recordID,
              !dto.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !dto.type.isEmpty,
              !dto.currencyCode.isEmpty,
              let openingBalance = BackupImportService.decimal(from: dto.openingBalance ?? "0")
        else { throw InvalidRecord() }

        if let account = try context.account(id: recordID) {
            account.typeRawValue = dto.type
            account.templateID = dto.templateID
            account.name = dto.name
            account.note = dto.note
            account.lastFourDigits = dto.lastFourDigits
            account.openingBalance = openingBalance
            account.currencyCode = dto.currencyCode
            account.createdAt = dto.createdAt
            account.updatedAt = dto.updatedAt
            account.deactivatedAt = dto.deactivatedAt
            return account
        }
        let account = Account(
            id: dto.id,
            typeRawValue: dto.type,
            templateID: dto.templateID,
            name: dto.name,
            note: dto.note,
            lastFourDigits: dto.lastFourDigits,
            balance: openingBalance,
            openingBalance: openingBalance,
            currencyCode: dto.currencyCode,
            createdAt: dto.createdAt,
            updatedAt: dto.updatedAt,
            deactivatedAt: dto.deactivatedAt
        )
        context.insert(account)
        return account
    }

    /// 写入流水；字段组合按与备份导入相同的规则校验，不要求所属账户已在本地（可能在同批稍后写入）。
    private static func upsertTransaction(
        _ dto: BackupTransaction,
        recordID: UUID,
        in context: ModelContext
    ) throws -> AccountTransaction {
        // 流水工厂固定写入 CNY；其他币种若放行会被静默改写
        guard dto.id == recordID, dto.currencyCode == "CNY" else { throw InvalidRecord() }
        let validated: AccountTransaction
        do {
            validated = try AccountTransaction.validatingPersistedFields(
                id: dto.id,
                accountID: dto.accountID,
                typeRawValue: dto.type,
                categoryRawValue: dto.category,
                amount: BackupImportService.optionalDecimal(from: dto.amount),
                balanceBefore: BackupImportService.optionalDecimal(from: dto.balanceBefore),
                balanceAfter: BackupImportService.optionalDecimal(from: dto.balanceAfter),
                balanceDelta: BackupImportService.optionalDecimal(from: dto.balanceDelta),
                counterpartAccountID: dto.counterpartAccountID,
                transactionDay: dto.transactionDay,
                note: dto.note ?? "",
                savedAt: dto.savedAt,
                title: dto.title
            )
        } catch is BackupImportError {
            throw InvalidRecord()
        }
        if let transaction = try context.transaction(id: recordID) {
            transaction.overwrite(with: validated)
            return transaction
        }
        context.insert(validated)
        return validated
    }

    /// 写入分类设置；预置分类的名称和图标固定，按默认值写回。
    private static func upsertCategory(
        _ dto: BackupCategory,
        recordID: UUID,
        in context: ModelContext
    ) throws -> BookkeepingCategory {
        guard dto.id == recordID,
              let direction = BookkeepingEntryType(rawValue: dto.direction),
              BookkeepingCategoryKey.isValid(dto.key, direction: direction),
              !dto.symbolName.isEmpty
        else { throw InvalidRecord() }
        let preset = BookkeepingCategoryKey.preset(direction: direction, key: dto.key)
        if let preset {
            // 「其他」是删除迁移的兜底目标，必须始终可用
            guard dto.id == preset.id,
                  dto.deletedAt == nil || dto.key != BookkeepingCategoryKey.other
            else { throw InvalidRecord() }
        } else if LocalCategoryRepository.cleanedName(dto.customName ?? "").isEmpty {
            throw InvalidRecord()
        }

        let validated = BookkeepingCategory(
            id: dto.id,
            direction: direction,
            key: dto.key,
            customName: preset == nil ? dto.customName : nil,
            symbolName: preset?.symbolName ?? dto.symbolName,
            sortIndex: dto.sortIndex,
            updatedAt: dto.updatedAt,
            deletedAt: dto.deletedAt,
            replacementKey: dto.replacementKey
        )
        if let existing = try category(id: recordID, in: context) {
            existing.overwrite(with: validated)
            return existing
        }
        context.insert(validated)
        return validated
    }

    /// 写入默认记账账户偏好；只接受 canonical 单例，失效指针原样保存，由读取端重新解析。
    private static func upsertPreference(
        _ dto: BackupBookkeepingPreference,
        recordID: UUID,
        in context: ModelContext
    ) throws -> BookkeepingPreference {
        guard recordID == BookkeepingPreference.singletonID else { throw InvalidRecord() }
        if let preference = try context.canonicalBookkeepingPreference() {
            preference.defaultAccountID = dto.defaultAccountID
            return preference
        }
        let preference = BookkeepingPreference(defaultAccountID: dto.defaultAccountID)
        context.insert(preference)
        return preference
    }

    // MARK: - 辅助

    /// 账户是否仍被未删除的流水引用（作为所属账户或转入账户），包括本 context 中尚未保存的新增。
    private static func isReferenced(accountID: UUID, in context: ModelContext) throws -> Bool {
        let referencing: (AccountTransaction) -> Bool = { transaction in
            !transaction.isDeleted
                && (transaction.accountID == accountID || transaction.counterpartAccountID == accountID)
        }
        if context.insertedModelsArray.contains(where: { ($0 as? AccountTransaction).map(referencing) ?? false }) {
            return true
        }
        return try context.fetch(FetchDescriptor<AccountTransaction>()).contains(where: referencing)
    }

    /// 把本地仍需保留的记录按当前时间重新登记为待上传，让它在服务端「复活」。
    private static func reregister(
        _ model: any PersistentModel,
        entityType: SyncEntityType,
        key: String,
        in context: ModelContext,
        ledger: inout [String: SyncLedgerEntry],
        now: Date
    ) throws {
        guard let encoded = try SyncPayloadCoder.record(for: model) else { return }
        if let entry = ledger[key] {
            entry.recordLocalChange(modifiedAt: now, payloadHash: encoded.payloadHash, isTombstone: false)
        } else {
            let entry = SyncLedgerEntry(
                entityType: entityType,
                recordID: encoded.recordID,
                modifiedAt: now,
                payloadHash: encoded.payloadHash
            )
            context.insert(entry)
            ledger[key] = entry
        }
    }

    /// 按 UUID 读取分类设置。
    private static func category(id: UUID, in context: ModelContext) throws -> BookkeepingCategory? {
        var descriptor = FetchDescriptor<BookkeepingCategory>(
            predicate: #Predicate<BookkeepingCategory> { category in category.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// 按 UUID 读取偏好记录（含非 canonical 的残留记录）。
    private static func preference(id: UUID, in context: ModelContext) throws -> BookkeepingPreference? {
        var descriptor = FetchDescriptor<BookkeepingPreference>(
            predicate: #Predicate<BookkeepingPreference> { preference in preference.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
