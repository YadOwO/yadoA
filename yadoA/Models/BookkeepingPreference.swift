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

/// 本地财务容器中唯一的默认记账账户偏好。
@Model
final class BookkeepingPreference {
    /// 跨文件重开保持不变的 canonical singleton ID。
    static let singletonID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// 偏好实体的稳定唯一标识。
    @Attribute(.unique) var id: UUID

    /// 默认账户的稳定 UUID；为空表示用户确认当前没有默认账户。
    var defaultAccountID: UUID?

    /// 创建一条偏好实体。
    init(
        id: UUID = BookkeepingPreference.singletonID,
        defaultAccountID: UUID? = nil
    ) {
        self.id = id
        self.defaultAccountID = defaultAccountID
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
