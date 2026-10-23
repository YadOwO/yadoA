import Foundation
import SwiftData

/// 参与云端同步的业务记录类型；rawValue 是与服务端约定的稳定值。
nonisolated enum SyncEntityType: String, CaseIterable, Sendable {
    /// 账户（`Account`）。
    case account

    /// 账户流水（`AccountTransaction`）。
    case transaction

    /// 收支分类设置（`BookkeepingCategory`）。
    case category

    /// 默认记账账户偏好（`BookkeepingPreference` 单例）。
    case preference
}

/// 本地同步台账：每条参与同步的业务记录对应一行，记录冲突裁决和上传所需的元数据。
///
/// 业务模型本身不带同步字段，本地删除仍是硬删除；删除只在台账里留下墓碑，
/// 所以现有查询都不需要额外过滤已删除记录。
/// 台账由 `SyncChangeTracker` 在统一保存入口 `saveOrRollback` 中自动维护。
@Model
final class SyncLedgerEntry {
    /// `<entityType>:<小写 UUID>`，在台账内唯一。
    @Attribute(.unique) var key: String

    /// `SyncEntityType.rawValue` 的持久化值。
    var entityTypeRawValue: String

    /// 对应业务记录的稳定 UUID。
    var recordID: UUID

    /// 这条记录最后一次真实修改的时间，作为「最后修改者胜出」的裁决时钟。
    ///
    /// 没改过的预置记录为 `distantPast`，保证它们不会覆盖其他设备上的修改。
    var modifiedAt: Date

    /// 最近一次登记时同步内容的 SHA-256；内容不变的保存不算修改。墓碑为空字符串。
    var payloadHash: String

    /// 记录已在本地删除，等待把删除上传到服务端。
    var isTombstone: Bool

    /// 本地每登记一次修改加 1。
    var revision: Int

    /// 已被服务端确认的 `revision`；与 `revision` 不相等表示还有修改没有上传。
    var pushedRevision: Int

    /// 解析后的记录类型；未知值返回 `nil`。
    var entityType: SyncEntityType? {
        SyncEntityType(rawValue: entityTypeRawValue)
    }

    /// 是否还有本地修改没有被服务端确认。
    var hasPendingChanges: Bool {
        revision != pushedRevision
    }

    /// 创建一条待上传的台账。
    ///
    /// - Parameters:
    ///   - entityType: 业务记录类型。
    ///   - recordID: 业务记录 UUID。
    ///   - modifiedAt: 裁决时钟。
    ///   - payloadHash: 同步内容的哈希；墓碑传空字符串。
    ///   - isTombstone: 是否为删除记录。
    init(
        entityType: SyncEntityType,
        recordID: UUID,
        modifiedAt: Date,
        payloadHash: String,
        isTombstone: Bool = false
    ) {
        key = Self.key(entityType: entityType, recordID: recordID)
        entityTypeRawValue = entityType.rawValue
        self.recordID = recordID
        self.modifiedAt = modifiedAt
        self.payloadHash = payloadHash
        self.isTombstone = isTombstone
        revision = 1
        pushedRevision = 0
    }

    /// 生成台账唯一键。
    ///
    /// - Parameters:
    ///   - entityType: 业务记录类型。
    ///   - recordID: 业务记录 UUID。
    /// - Returns: `<entityType>:<小写 UUID>`。
    nonisolated static func key(entityType: SyncEntityType, recordID: UUID) -> String {
        "\(entityType.rawValue):\(recordID.uuidString.lowercased())"
    }

    /// 登记一次本地修改：更新裁决时钟、内容哈希和删除标记，并标记为待上传。
    ///
    /// - Parameters:
    ///   - modifiedAt: 本次修改时间。
    ///   - payloadHash: 新内容的哈希；墓碑传空字符串。
    ///   - isTombstone: 本次修改是否为删除。
    func recordLocalChange(modifiedAt: Date, payloadHash: String, isTombstone: Bool) {
        self.modifiedAt = modifiedAt
        self.payloadHash = payloadHash
        self.isTombstone = isTombstone
        revision += 1
    }

    /// 记录本地内容已与服务端一致：应用了服务端版本，或推送被服务端确认。
    ///
    /// 丢弃尚未上传的本地修改；`pushedRevision` 大于 0 同时表示这条记录「已同步过」，全量同步据此判断要不要删除。
    ///
    /// - Parameters:
    ///   - modifiedAt: 服务端记录的裁决时钟（已钳制）。
    ///   - payloadHash: 本地模型重新编码后的内容哈希。
    func markSynced(modifiedAt: Date, payloadHash: String) {
        self.modifiedAt = modifiedAt
        self.payloadHash = payloadHash
        isTombstone = false
        pushedRevision = revision
    }

    /// 创建一条与服务端一致的台账，用于本地第一次见到的远端记录。
    ///
    /// - Parameters:
    ///   - entityType: 记录类型。
    ///   - recordID: 业务记录 UUID。
    ///   - modifiedAt: 服务端记录的裁决时钟。
    ///   - payloadHash: 本地模型编码后的内容哈希。
    /// - Returns: `revision` 与 `pushedRevision` 都为 1 的台账。
    static func synced(
        entityType: SyncEntityType,
        recordID: UUID,
        modifiedAt: Date,
        payloadHash: String
    ) -> SyncLedgerEntry {
        let entry = SyncLedgerEntry(
            entityType: entityType,
            recordID: recordID,
            modifiedAt: modifiedAt,
            payloadHash: payloadHash
        )
        entry.pushedRevision = entry.revision
        return entry
    }
}
