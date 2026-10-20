import CryptoKit
import Foundation
import SwiftData

/// SwiftData 中持久化的一条收支分类设置。
///
/// 预置分类与自定义分类共用这张表：预置分类只保存排序、隐藏和图标覆盖，
/// 名称来自 String Catalog；自定义分类额外保存用户输入的名称。
/// 流水通过 `key` 引用分类，删除分类时保留墓碑记录，为以后的多设备同步预留迁移目标。
@Model
final class BookkeepingCategory {
    /// 分类行的稳定标识；预置分类由「方向 + key」派生，保证各设备一致。
    @Attribute(.unique) var id: UUID

    /// `BookkeepingEntryType.rawValue`，区分支出分类与收入分类。
    var directionRawValue: String

    /// 流水 `categoryRawValue` 引用的分类 key；预置分类为枚举 rawValue，自定义分类为 `custom.<uuid>`。
    var key: String

    /// 自定义分类的用户名称；预置分类为 `nil`，名称走本地化。
    var customName: String?

    /// 分类使用的 SF Symbol 名称；预置分类可被用户覆盖。
    var symbolName: String

    /// 同一方向内的展示顺序，数值越小越靠前。
    var sortIndex: Int

    /// 是否在记账面板中隐藏；只影响新记账，不影响历史流水的展示与统计。
    var isHidden: Bool

    /// 最近一次修改时间，供以后的同步做冲突判断。
    var updatedAt: Date

    /// 删除时间；非空表示该分类已删除，只作为墓碑保留。
    var deletedAt: Date?

    /// 删除时流水被迁往的分类 key；以后其他设备同步删除时按同一目标迁移。
    var replacementKey: String?

    /// 创建一条分类设置。
    init(
        id: UUID,
        direction: BookkeepingEntryType,
        key: String,
        customName: String? = nil,
        symbolName: String,
        sortIndex: Int,
        isHidden: Bool = false,
        updatedAt: Date = .now,
        deletedAt: Date? = nil,
        replacementKey: String? = nil
    ) {
        self.id = id
        self.directionRawValue = direction.rawValue
        self.key = key
        self.customName = customName
        self.symbolName = symbolName
        self.sortIndex = sortIndex
        self.isHidden = isHidden
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.replacementKey = replacementKey
    }

    /// 已知的收支方向；未知或损坏值返回 `nil`。
    var direction: BookkeepingEntryType? {
        BookkeepingEntryType(rawValue: directionRawValue)
    }

    /// 是否为预置分类。
    var isPreset: Bool {
        guard let direction else { return false }
        return BookkeepingCategoryKey.isPreset(key, direction: direction)
    }

    /// 是否已删除（墓碑）；不能叫 `isDeleted`，那是 `PersistentModel` 自带的上下文删除状态。
    var isTombstoned: Bool { deletedAt != nil }
}

/// 预置分类的默认配置。
struct BookkeepingPresetCategory: Equatable, Sendable {
    /// 所属收支方向。
    let direction: BookkeepingEntryType

    /// 流水引用的稳定 key，即枚举 rawValue。
    let key: String

    /// 默认图标。
    let symbolName: String

    /// 默认排序。
    let sortIndex: Int

    /// String Catalog 中的名称键。
    var localizationKey: String { "\(direction.rawValue).category.\(key)" }

    /// 由「方向 + key」派生的稳定行标识。
    var id: UUID { BookkeepingCategoryKey.presetID(direction: direction, key: key) }
}

/// 分类 key 的格式规则与预置目录。
enum BookkeepingCategoryKey {
    /// 自定义分类 key 的前缀。
    static let customPrefix = "custom."

    /// 「其他」分类的 key；两个方向共用同一 rawValue。
    static let other = "other"

    /// 指定方向的全部预置分类，顺序即默认排序。
    static func presets(for direction: BookkeepingEntryType) -> [BookkeepingPresetCategory] {
        switch direction {
        case .expense:
            ExpenseCategory.allCases.enumerated().map { index, category in
                BookkeepingPresetCategory(
                    direction: .expense,
                    key: category.rawValue,
                    symbolName: category.symbolName,
                    sortIndex: index
                )
            }
        case .income:
            IncomeCategory.allCases.enumerated().map { index, category in
                BookkeepingPresetCategory(
                    direction: .income,
                    key: category.rawValue,
                    symbolName: category.symbolName,
                    sortIndex: index
                )
            }
        }
    }

    /// 两个方向的全部预置分类。
    static var allPresets: [BookkeepingPresetCategory] {
        BookkeepingEntryType.allCases.flatMap(presets(for:))
    }

    /// 查找指定方向的预置分类。
    static func preset(direction: BookkeepingEntryType, key: String) -> BookkeepingPresetCategory? {
        presets(for: direction).first { $0.key == key }
    }

    /// key 是否为该方向的预置分类。
    static func isPreset(_ key: String, direction: BookkeepingEntryType) -> Bool {
        switch direction {
        case .expense: ExpenseCategory(rawValue: key) != nil
        case .income: IncomeCategory(rawValue: key) != nil
        }
    }

    /// 为新的自定义分类生成 key。
    static func customKey(for id: UUID) -> String {
        customPrefix + id.uuidString.lowercased()
    }

    /// key 是否符合 `custom.<小写 uuid>` 格式。
    static func isCustom(_ key: String) -> Bool {
        guard key.hasPrefix(customPrefix) else { return false }
        let uuidText = String(key.dropFirst(customPrefix.count))
        guard let uuid = UUID(uuidString: uuidText) else { return false }
        return uuid.uuidString.lowercased() == uuidText
    }

    /// key 在该方向下是否为合法格式：预置 rawValue 或自定义 key。
    static func isValid(_ key: String, direction: BookkeepingEntryType) -> Bool {
        isPreset(key, direction: direction) || isCustom(key)
    }

    /// 由「方向 + key」派生确定性的 UUID，让各设备上的同一预置分类拥有相同行标识。
    static func presetID(direction: BookkeepingEntryType, key: String) -> UUID {
        let digest = SHA256.hash(data: Data("yadoA.category.\(direction.rawValue).\(key)".utf8))
        var bytes = Array(digest.prefix(16))
        // 标记为 RFC 4122 变体、版本 5 风格的名字派生 UUID。
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
