import CryptoKit
import Foundation
import SwiftData

/// 业务模型与同步内容（payload）之间的转换边界。
///
/// payload 复用备份格式的 DTO（`BackupAccount`、`BackupTransaction` 等），
/// 它们本身就有版本演进和缺字段容错的约定。编码结果按键排序，同样的内容总是得到同样的字节，
/// 因此可以用哈希判断一次保存是否真的改了同步内容。
enum SyncPayloadCoder {
    /// 一条业务记录的同步身份和内容。
    struct Record: Equatable {
        /// 记录类型。
        let entityType: SyncEntityType

        /// 记录的稳定 UUID。
        let recordID: UUID

        /// 按键排序的 JSON 内容。
        let payload: Data

        /// `payload` 的 SHA-256 十六进制字符串。
        var payloadHash: String { SyncPayloadCoder.hash(payload) }
    }

    /// 复用的编码器；导入备份等大批量保存时避免逐条创建。
    private static let encoder = BackupFileEncoding.makeEncoder()

    /// 各类型 payload 中不参与同步的字段：派生值或本地缓存。
    private static let excludedKeys: [SyncEntityType: Set<String>] = [
        // 余额由期初余额和流水推导，各端自行重算。
        .account: ["balance"],
    ]

    /// 若模型属于同步类型，返回它的同步身份；不生成内容，供删除登记使用。
    ///
    /// - Parameter model: context 中的任意持久化模型。
    /// - Returns: 记录类型和 UUID；不参与同步的模型返回 `nil`。
    static func identity(of model: any PersistentModel) -> (SyncEntityType, UUID)? {
        switch model {
        case let account as Account:
            (.account, account.id)
        case let transaction as AccountTransaction:
            (.transaction, transaction.id)
        case let category as BookkeepingCategory:
            (.category, category.id)
        case let preference as BookkeepingPreference:
            (.preference, preference.id)
        default:
            nil
        }
    }

    /// 生成模型的同步内容。
    ///
    /// - Parameter model: context 中的任意持久化模型。
    /// - Returns: 同步身份和内容；不参与同步的模型返回 `nil`。
    /// - Throws: 编码失败时抛出底层错误。
    static func record(for model: any PersistentModel) throws -> Record? {
        switch model {
        case let account as Account:
            return try makeRecord(.account, id: account.id, dto: BackupAccount(account))
        case let transaction as AccountTransaction:
            return try makeRecord(.transaction, id: transaction.id, dto: BackupTransaction(transaction))
        case let category as BookkeepingCategory:
            return try makeRecord(.category, id: category.id, dto: BackupCategory(category))
        case let preference as BookkeepingPreference:
            return try makeRecord(
                .preference,
                id: preference.id,
                dto: BackupBookkeepingPreference(defaultAccountID: preference.defaultAccountID)
            )
        default:
            return nil
        }
    }

    /// 判断记录是否由 App 自动创建、且仍保持创建时的默认状态。
    ///
    /// 包括两类：每台设备都会自动补齐的预置分类，以及写账户时自动创建、尚未指向任何账户的偏好单例。
    /// 这样的记录在台账里的修改时间记为 `distantPast`，首次合并时不会覆盖其他设备上的排序、删除或默认账户选择。
    ///
    /// 只看内容无法区分「系统初始化」和「用户或导入明确写入的同样内容」，所以同时要求创建路径打上
    /// `isAutoCreated` 标记；自动创建后在同一次保存里又被用户改过的，也不算。
    /// 只在台账首次登记该记录时使用；之后的任何修改都按当前时间登记。
    ///
    /// - Parameter model: context 中的任意持久化模型。
    /// - Returns: 是否为未被改动过的自动创建记录。
    static func isPristineDefault(_ model: any PersistentModel) -> Bool {
        switch model {
        case let category as BookkeepingCategory:
            guard category.isAutoCreated,
                  let direction = category.direction,
                  let preset = BookkeepingCategoryKey.preset(direction: direction, key: category.key)
            else { return false }
            return category.id == preset.id
                && category.customName == nil
                && category.symbolName == preset.symbolName
                && category.sortIndex == preset.sortIndex
                && category.deletedAt == nil
                && category.replacementKey == nil
        case let preference as BookkeepingPreference:
            return preference.isAutoCreated && preference.defaultAccountID == nil
        default:
            return false
        }
    }

    /// 计算内容的 SHA-256 十六进制字符串。
    ///
    /// - Parameter data: 同步内容。
    /// - Returns: 64 位小写十六进制字符串。
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 编码 DTO，去掉不参与同步的字段，再按键排序输出紧凑 JSON。
    private static func makeRecord<DTO: Encodable>(
        _ entityType: SyncEntityType,
        id: UUID,
        dto: DTO
    ) throws -> Record {
        let encoded = try encoder.encode(dto)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw EncodingError.invalidValue(
                dto,
                EncodingError.Context(codingPath: [], debugDescription: "同步内容必须是 JSON 对象")
            )
        }
        for key in excludedKeys[entityType] ?? [] {
            object.removeValue(forKey: key)
        }
        let payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return Record(entityType: entityType, recordID: id, payload: payload)
    }
}
