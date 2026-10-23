import Foundation
import OSLog
import SwiftData

/// 待推送的一条变更，以及取出时台账的版本，用于判断推送期间本地是否又被修改。
struct SyncPendingItem: Equatable {
    /// 台账唯一键。
    let key: String

    /// 取出时台账的 `revision`。
    let revision: Int

    /// 要推送的变更。
    let change: SyncChange
}

/// 一批待推送的变更。
struct SyncPendingBatch: Equatable {
    /// 本批变更，最多 `SyncContractLimits.maxPushChanges` 条。
    let items: [SyncPendingItem]

    /// 本次扫描到的、同步内容超过 `SyncContractLimits.maxPayloadBytes` 而不会上传的记录数。
    let oversizedCount: Int
}

/// 同步引擎的本地读写边界：读取待推送的台账，把服务端结果写入本地。
///
/// 和各仓库一样在主线程使用独立的 manual-save context：业务模型都隔离在主线程，
/// 改到后台 actor 需要整套模型层改为 nonisolated，代价过大。网络请求和 JSON 编解码已在 `SyncAPI` 中放到后台，
/// 这里只负责逐条写入模型，个人账本的数据量下耗时可以接受。
///
/// 应用服务端数据时不登记台账（`tracksSyncChanges: false`），台账由 `SyncRecordApplier` 直接改为「已同步」；
/// 只有因远端删除分类而迁移本地流水时，才走一次正常登记的保存，让迁移被推送出去。
@MainActor
final class SyncStore {
    /// 本地财务容器。
    private let container: ModelContainer

    /// 创建本地读写边界。
    ///
    /// - Parameter container: 应用或测试持有的本地财务容器。
    init(container: ModelContainer) {
        self.container = container
    }

    /// 取出一批待推送的变更：还没被服务端确认的台账，按裁决时钟从早到晚。
    ///
    /// 同步内容过大的记录跳过并计数；台账存在但业务记录已不在的（不应出现）跳过并记日志。
    ///
    /// - Parameter limit: 本批最多条数。
    /// - Returns: 一批变更；没有待推送的记录时为空。
    /// - Throws: 读取本地数据或编码同步内容失败时抛出底层错误。
    func pendingBatch(limit: Int = SyncContractLimits.maxPushChanges) throws -> SyncPendingBatch {
        let context = container.makeManualSaveContext()
        let entries = try context.fetch(
            FetchDescriptor<SyncLedgerEntry>(
                predicate: #Predicate<SyncLedgerEntry> { entry in entry.revision != entry.pushedRevision },
                sortBy: [SortDescriptor(\SyncLedgerEntry.modifiedAt)]
            )
        )
        var items: [SyncPendingItem] = []
        var oversizedCount = 0
        for entry in entries {
            // 凑满一批就停，不必为后面的记录编码内容
            guard items.count < limit else { break }
            guard let entityType = entry.entityType else { continue }
            let change: SyncChange
            if entry.isTombstone {
                change = .deletion(entityType: entityType, recordID: entry.recordID, modifiedAt: entry.modifiedAt)
            } else {
                guard let model = try model(entityType, id: entry.recordID, in: context),
                      let record = try SyncPayloadCoder.record(for: model)
                else {
                    SyncRecordApplier.logger.error("台账对应的业务记录不存在：\(entry.key, privacy: .public)")
                    continue
                }
                guard record.payload.count <= SyncContractLimits.maxPayloadBytes else {
                    oversizedCount += 1
                    continue
                }
                change = try .upsert(
                    entityType: entityType,
                    recordID: entry.recordID,
                    modifiedAt: entry.modifiedAt,
                    payload: record.payload
                )
            }
            items.append(SyncPendingItem(key: entry.key, revision: entry.revision, change: change))
        }
        return SyncPendingBatch(items: items, oversizedCount: oversizedCount)
    }

    /// 写入推送结果。
    ///
    /// - applied：记下服务端确认的版本和钳制后的裁决时钟；已上传的删除不再需要，移除台账；
    /// - stale：本地版本作废，用服务端带回的当前版本覆盖本地；
    /// - 推送期间本地又改过的（`revision` 变了）：只记下已确认的版本，新修改保持待上传，不被覆盖。
    ///
    /// - Parameters:
    ///   - batch: 推送的那一批。
    ///   - response: 服务端响应，`results` 与 `batch.items` 一一对应。
    ///   - now: 重新登记时使用的时间。
    /// - Returns: 应用 stale 版本的结果。
    /// - Throws: 结果条数与请求不一致时抛出 `SyncAPIError.invalidContract`；读写本地数据失败时抛出底层错误。
    @discardableResult
    func applyPushResults(
        _ batch: SyncPendingBatch,
        response: SyncPushResponse,
        now: Date = .now
    ) throws -> SyncApplyOutcome {
        guard response.results.count == batch.items.count else { throw SyncAPIError.invalidContract }
        let context = container.makeManualSaveContext()
        var ledger = try loadLedger(in: context)
        var staleRecords: [SyncRemoteRecord] = []

        for (item, result) in zip(batch.items, response.results) {
            guard let entry = ledger[item.key] else { continue }
            guard entry.revision == item.revision else {
                if result.status == .applied {
                    entry.pushedRevision = max(entry.pushedRevision, item.revision)
                }
                continue
            }
            switch result.status {
            case .applied:
                if entry.isTombstone {
                    ledger.removeValue(forKey: item.key)
                    context.delete(entry)
                } else {
                    entry.modifiedAt = result.modifiedAt
                    entry.pushedRevision = entry.revision
                }
            case .stale:
                // 先作废本地的待上传状态，下面应用服务端版本时才不会被「本地更新」规则挡住
                entry.pushedRevision = entry.revision
                if let current = result.current {
                    staleRecords.append(current)
                }
            }
        }

        let outcome = try SyncRecordApplier.apply(staleRecords, in: context, ledger: &ledger, now: now)
        try finish(outcome, in: context, now: now)
        return outcome
    }

    /// 应用一页增量拉取的变更。
    ///
    /// - Parameters:
    ///   - records: 按序号升序的变更。
    ///   - now: 重新登记时使用的时间。
    /// - Returns: 应用结果。
    /// - Throws: 读写本地数据失败时抛出底层错误。
    @discardableResult
    func applyIncremental(_ records: [SyncRemoteRecord], now: Date = .now) throws -> SyncApplyOutcome {
        let context = container.makeManualSaveContext()
        var ledger = try loadLedger(in: context)
        let outcome = try SyncRecordApplier.apply(records, in: context, ledger: &ledger, now: now)
        try finish(outcome, in: context, now: now)
        return outcome
    }

    /// 用一整轮全量拉取的结果替换本地已同步的数据（KTD10）。
    ///
    /// - 结果中的记录按增量规则应用（本地有更新的待上传版本时保留本地）；
    /// - 本地已同步过（`pushedRevision > 0`）、但整轮结果里没有的记录在本地删除，即使有待上传的修改也删除：
    ///   它们在云端已被删除，只是墓碑已被清理；
    /// - 从未上传过的记录保留，之后推送。
    ///
    /// - Parameters:
    ///   - records: 整轮所有页的变更，必须是完整的一轮；整轮为空表示云端没有任何记录。
    ///   - now: 重新登记时使用的时间。
    /// - Returns: 应用结果。
    /// - Throws: 读写本地数据失败时抛出底层错误。
    @discardableResult
    func replaceAll(with records: [SyncRemoteRecord], now: Date = .now) throws -> SyncApplyOutcome {
        let context = container.makeManualSaveContext()
        var ledger = try loadLedger(in: context)
        var outcome = try SyncRecordApplier.apply(records, in: context, ledger: &ledger, now: now)

        let remoteKeys = Set(records.compactMap { record in
            record.entityType.map { SyncLedgerEntry.key(entityType: $0, recordID: record.recordID) }
        })
        let absent = ledger.values
            .filter { $0.pushedRevision > 0 && !remoteKeys.contains($0.key) }
            .compactMap { entry in entry.entityType.map { (entityType: $0, recordID: entry.recordID) } }
            // 账户放在最后删除，判断引用时已看到流水的删除
            .sorted { SyncRecordApplier.applyPhase($0.entityType, isDeleted: true) < SyncRecordApplier.applyPhase($1.entityType, isDeleted: true) }
        for record in absent {
            try SyncRecordApplier.removeLocal(
                entityType: record.entityType,
                recordID: record.recordID,
                in: context,
                ledger: &ledger,
                now: now,
                outcome: &outcome
            )
        }
        try finish(outcome, in: context, now: now)
        return outcome
    }

    // MARK: - 私有方法

    /// 重算余额并保存（不登记台账）；再把引用已删除分类的流水迁走（登记台账，让迁移被推送）。
    private func finish(_ outcome: SyncApplyOutcome, in context: ModelContext, now: Date) throws {
        if context.hasChanges {
            // 余额不同步，各端按期初余额和流水重算；全量重算对个人账本的规模足够快
            try AccountBalanceRebuilder.rebuild(in: context)
            try context.saveOrRollback(tracksSyncChanges: false)
        }
        guard !outcome.categoryMigrations.isEmpty else { return }
        try migrateTransactions(for: outcome.categoryMigrations)
    }

    /// 把本地仍引用已删除分类的流水迁到删除时指定的分类；对方选择「随分类删除流水」或目标已不可用时迁到「其他」，
    /// 不删除本机独有的流水。迁移按普通修改登记，之后推送。
    private func migrateTransactions(for migrations: Set<SyncCategoryMigration>) throws {
        let context = container.makeManualSaveContext()
        let categories = try context.fetch(FetchDescriptor<BookkeepingCategory>())
        let transactions = try context.fetch(FetchDescriptor<AccountTransaction>())
        for migration in migrations {
            let directionRawValue = migration.direction.rawValue
            let isAvailable: (String) -> Bool = { key in
                // 预置分类即使还没有存储行也可用；有存储行时不能是墓碑
                let row = categories.first { $0.directionRawValue == directionRawValue && $0.key == key }
                if let row { return !row.isTombstoned }
                return BookkeepingCategoryKey.preset(direction: migration.direction, key: key) != nil
            }
            let target = migration.replacementKey.flatMap { isAvailable($0) ? $0 : nil } ?? BookkeepingCategoryKey.other
            let typeRawValue = switch migration.direction {
            case .expense: AccountTransactionType.expense.rawValue
            case .income: AccountTransactionType.income.rawValue
            }
            for transaction in transactions
            where transaction.typeRawValue == typeRawValue && transaction.categoryRawValue == migration.key {
                transaction.categoryRawValue = target
            }
        }
        if context.hasChanges {
            try context.saveOrRollback()
        }
    }

    /// 读取全部台账，按唯一键索引。
    private func loadLedger(in context: ModelContext) throws -> [String: SyncLedgerEntry] {
        Dictionary(
            try context.fetch(FetchDescriptor<SyncLedgerEntry>()).map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// 按类型和 UUID 读取业务模型。
    private func model(_ entityType: SyncEntityType, id: UUID, in context: ModelContext) throws -> (any PersistentModel)? {
        switch entityType {
        case .account:
            return try context.account(id: id)
        case .transaction:
            return try context.transaction(id: id)
        case .category:
            var descriptor = FetchDescriptor<BookkeepingCategory>(
                predicate: #Predicate<BookkeepingCategory> { category in category.id == id }
            )
            descriptor.fetchLimit = 1
            return try context.fetch(descriptor).first
        case .preference:
            var descriptor = FetchDescriptor<BookkeepingPreference>(
                predicate: #Predicate<BookkeepingPreference> { preference in preference.id == id }
            )
            descriptor.fetchLimit = 1
            return try context.fetch(descriptor).first
        }
    }
}
