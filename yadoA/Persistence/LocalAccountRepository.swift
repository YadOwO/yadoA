import Foundation
import SwiftData

/// 本地账户写入边界产生的错误。
enum AccountRepositoryError: Error, Equatable {
    /// 相同草稿 UUID 已成功保存，拒绝再次插入。
    case duplicateID(UUID)

    /// 编辑请求对应的账户已不存在。
    case accountNotFound(UUID)
}

/// 在主 actor 上串行管理单一 ModelContext 的本地账户仓库。
@MainActor
final class LocalAccountRepository {
    /// 唯一写入 context；关闭自动保存后仅显式保存成功才算持久化。
    let modelContext: ModelContext

    /// 测试可注入的保存前故障点；生产环境默认为空操作。
    private let beforeSave: () throws -> Void

    /// 使用应用级容器创建串行写入仓库。
    ///
    /// - Parameters:
    ///   - container: 应用或测试持有的 SwiftData 容器。
    ///   - beforeSave: 显式保存前执行的可注入操作。
    convenience init(
        container: ModelContainer,
        beforeSave: @escaping () throws -> Void = {}
    ) {
        self.init(
            modelContext: ModelContext(container),
            beforeSave: beforeSave
        )
    }

    /// 使用仓库独占的 context 创建仓库。
    private init(
        modelContext: ModelContext,
        beforeSave: @escaping () throws -> Void = {}
    ) {
        modelContext.autosaveEnabled = false
        self.modelContext = modelContext
        self.beforeSave = beforeSave
    }

    /// 校验草稿、拒绝重复 UUID，并原子地插入和显式保存账户。
    ///
    /// 保存阶段任一错误都会回滚 context，避免失败重试留下幽灵或重复账户。
    func save(
        _ draft: AccountDraft,
        locale: Locale = .current,
        now: Date = .now
    ) throws {
        let account = try Account.validating(draft: draft, locale: locale, now: now)
        guard try self.account(id: draft.id) == nil else {
            throw AccountRepositoryError.duplicateID(draft.id)
        }

        try persistChanges {
            modelContext.insert(account)
        }
    }

    /// 校验并原子更新已有账户资料，不改变余额或账户流水。
    ///
    /// 保存阶段任一错误都会回滚 context，确保编辑失败时原资料仍可重试。
    func update(
        _ draft: AccountEditDraft,
        now: Date = .now
    ) throws {
        guard let account = try account(id: draft.id) else {
            throw AccountRepositoryError.accountNotFound(draft.id)
        }

        try persistChanges {
            try account.applying(draft, now: now)
        }
    }

    /// 在同一 context 中执行变更、显式保存并统一处理失败回滚。
    private func persistChanges(_ changes: () throws -> Void) throws {
        do {
            try changes()
            try beforeSave()
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// 获取指定稳定 UUID 的当前账户。
    func account(id: UUID) throws -> Account? {
        var descriptor = FetchDescriptor<Account>(
            predicate: #Predicate<Account> { account in
                account.id == id
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /// 获取确定性排序的全部账户，最新更新时间优先，UUID 作为并列键。
    func accounts() throws -> [Account] {
        try modelContext.fetch(FetchDescriptor<Account>()).sorted(by: AccountOrdering.newestFirst)
    }
}
