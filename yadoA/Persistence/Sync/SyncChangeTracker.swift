import Foundation
import SwiftData

/// 在保存前把本次 context 里的业务修改登记到同步台账。
///
/// 由 `ModelContext.saveOrRollback` 统一调用，与业务修改在同一次保存里提交或回滚，
/// 各仓库不需要关心同步。规则：
/// - 新增或修改：同步内容的哈希变了才登记，只改了余额缓存这类不同步字段的保存会被跳过；
/// - 删除：本机已绑定账号时留下墓碑等待上传；未绑定时直接删掉台账，服务端从不知道这条记录；
/// - 没改过的预置记录，修改时间记为 `distantPast`。
enum SyncChangeTracker {
    /// 读取绑定状态的 UserDefaults；测试可替换为独立的 suite。
    static var defaults: UserDefaults = .standard

    /// 一次保存涉及的记录数超过该值时，一次读出全部台账，避免谓词参数过多。
    private static let batchLookupThreshold = 200

    /// 把 context 中尚未保存的新增、修改、删除登记到同步台账；不保存。
    ///
    /// - Parameters:
    ///   - context: 即将保存的 context。
    ///   - now: 本次修改时间。
    /// - Returns: 登记的记录数。
    /// - Throws: 编码同步内容或读取台账失败时抛出底层错误。
    @discardableResult
    static func recordLocalChanges(in context: ModelContext, now: Date = .now) throws -> Int {
        var upserts: [String: (record: SyncPayloadCoder.Record, isPristine: Bool)] = [:]
        for model in context.insertedModelsArray + context.changedModelsArray {
            guard let record = try SyncPayloadCoder.record(for: model) else { continue }
            let key = SyncLedgerEntry.key(entityType: record.entityType, recordID: record.recordID)
            upserts[key] = (record, SyncPayloadCoder.isPristineDefault(model))
        }
        var deletions: [String: (entityType: SyncEntityType, recordID: UUID)] = [:]
        for model in context.deletedModelsArray {
            guard let identity = SyncPayloadCoder.identity(of: model) else { continue }
            let key = SyncLedgerEntry.key(entityType: identity.0, recordID: identity.1)
            // 同一次保存里删了又插回同一标识时，以插回后的内容为准。
            guard upserts[key] == nil else { continue }
            deletions[key] = (identity.0, identity.1)
        }
        guard !upserts.isEmpty || !deletions.isEmpty else { return 0 }

        let entries = try existingEntries(
            keys: Set(upserts.keys).union(deletions.keys),
            in: context
        )
        var recordedCount = 0

        for (key, change) in upserts {
            let hash = change.record.payloadHash
            if let entry = entries[key] {
                guard entry.isTombstone || entry.payloadHash != hash else { continue }
                entry.recordLocalChange(modifiedAt: now, payloadHash: hash, isTombstone: false)
            } else {
                context.insert(
                    SyncLedgerEntry(
                        entityType: change.record.entityType,
                        recordID: change.record.recordID,
                        modifiedAt: change.isPristine ? .distantPast : now,
                        payloadHash: hash
                    )
                )
            }
            recordedCount += 1
        }

        let keepsTombstones = SyncState.load(from: defaults).isBound
        for (key, deletion) in deletions {
            if let entry = entries[key] {
                if keepsTombstones {
                    entry.recordLocalChange(modifiedAt: now, payloadHash: "", isTombstone: true)
                } else {
                    context.delete(entry)
                }
            } else if keepsTombstones {
                context.insert(
                    SyncLedgerEntry(
                        entityType: deletion.entityType,
                        recordID: deletion.recordID,
                        modifiedAt: now,
                        payloadHash: "",
                        isTombstone: true
                    )
                )
            }
            recordedCount += 1
        }
        return recordedCount
    }

    /// 按唯一键读取已有台账。
    private static func existingEntries(
        keys: Set<String>,
        in context: ModelContext
    ) throws -> [String: SyncLedgerEntry] {
        let entries: [SyncLedgerEntry]
        if keys.count > batchLookupThreshold {
            entries = try context.fetch(FetchDescriptor<SyncLedgerEntry>())
                .filter { keys.contains($0.key) }
        } else {
            let keyList = Array(keys)
            entries = try context.fetch(
                FetchDescriptor<SyncLedgerEntry>(
                    predicate: #Predicate<SyncLedgerEntry> { entry in
                        keyList.contains(entry.key)
                    }
                )
            )
        }
        return Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
