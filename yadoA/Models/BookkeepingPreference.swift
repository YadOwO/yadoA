import Foundation
import SwiftData

/// 默认记账账户偏好解析结果，区分缺失、明确无默认和失效指针。
enum BookkeepingDefaultResolution: Equatable, Sendable {
    /// 存储中还没有 canonical singleton。
    case missing

    /// 用户或系统明确保存了“无默认”。
    case none

    /// 偏好指向当前存在、启用且符合默认资格的账户。
    case valid(UUID)

    /// 偏好存在但指针无法解析为有效默认账户。
    case invalid(UUID)
}

/// 本地财务容器中唯一的记账偏好：默认记账账户和账户分类顺序。
@Model
final class BookkeepingPreference {
    /// 跨文件重开保持不变的 canonical singleton ID。
    static let singletonID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// 偏好实体的稳定唯一标识。
    @Attribute(.unique) var id: UUID

    /// 默认账户的稳定 UUID；为空表示用户确认当前没有默认账户。
    var defaultAccountID: UUID?

    /// 用户调整过的账户分类顺序，存 `AccountType.rawValue`；为空表示沿用添加账户页的默认顺序。
    ///
    /// 只存原始值，读取时由 `AccountDisplayOrder` 去掉未知和重复值，并补齐缺少的分类。
    var accountTypeOrder: [String]?

    /// 本实体是否由写账户命令自动创建；不持久化，只在创建它的那次保存中有效。
    ///
    /// 同步台账据此区分系统初始化和用户或导入写入的「无默认」，见 `SyncPayloadCoder.isPristineDefault`。
    @Transient var isAutoCreated = false

    /// 创建一条偏好实体。
    init(
        id: UUID = BookkeepingPreference.singletonID,
        defaultAccountID: UUID? = nil,
        accountTypeOrder: [String]? = nil
    ) {
        self.id = id
        self.defaultAccountID = defaultAccountID
        self.accountTypeOrder = accountTypeOrder
    }

    /// 从查询结果中取出 canonical 单例；SwiftUI 视图的 `@Query` 结果用它，忽略非 canonical 的残留记录。
    ///
    /// - Parameter preferences: 查询到的全部偏好记录。
    /// - Returns: canonical 偏好；不存在时为 `nil`。
    static func canonical(in preferences: [BookkeepingPreference]) -> BookkeepingPreference? {
        preferences.first { $0.id == singletonID }
    }

    /// 根据 canonical 偏好和当前账户快照解析默认状态。
    static func resolution(
        preference: BookkeepingPreference?,
        accounts: [Account]
    ) -> BookkeepingDefaultResolution {
        guard let preference else { return .missing }
        guard let accountID = preference.defaultAccountID else { return .none }
        return accounts.contains(where: { $0.id == accountID && $0.isEligibleForDefault })
            ? .valid(accountID)
            : .invalid(accountID)
    }

    /// 仅返回当前可用的默认账户 UUID；失效指针不会被读取操作静默修复。
    static func resolvedAccountID(
        preference: BookkeepingPreference?,
        accounts: [Account]
    ) -> UUID? {
        guard case let .valid(accountID) = resolution(preference: preference, accounts: accounts)
        else { return nil }
        return accountID
    }
}
