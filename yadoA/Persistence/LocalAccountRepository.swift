import Foundation
import SwiftData

/// 账户生命周期处置方式。
enum AccountDisposalAction: Equatable, Sendable {
    /// 永久删除没有任何账户流水的账户。
    case delete

    /// 保留账户与历史流水，仅改变日常可用性。
    case deactivate
}

/// 本地账户写入边界产生的错误。
enum AccountRepositoryError: Error, Equatable {
    /// 相同草稿 UUID 已成功保存，拒绝再次插入。
    case duplicateID(UUID)

    /// 编辑或生命周期请求对应的账户已不存在。
    case accountNotFound(UUID)

    /// 停用账户不能继续编辑或执行财务写入。
    case accountDeactivated(UUID)

    /// 账户类型未知或当前不具备默认资格。
    case invalidDefaultCandidate(UUID)

    /// 目标账户仍有任意类型流水，不能永久删除。
    case accountHasTransactions(UUID)

    /// 有历史账户余额必须精确为零后才能停用。
    case nonZeroBalance(UUID)

    /// 当前默认账户被处置时存在候选，但没有提交接替者。
    case replacementRequired(UUID)

    /// 当前默认账户没有可用候选，必须明确确认无默认。
    case noDefaultConfirmationRequired(UUID)

    /// 最终提交时账户、默认或接替候选已发生变化，需要重新确认。
    case expectedStateChanged

    /// 只能恢复当前处于停用状态的账户。
    case accountAlreadyActive(UUID)
}

/// 账户管理页提交给仓库的最终处置预期。
struct AccountDisposalExpectation: Equatable, Sendable {
    /// 要处置的账户 UUID。
    let accountID: UUID

    /// 预期执行的处置动作，防止删除被静默降级为停用。
    let action: AccountDisposalAction

    /// 确认弹窗展示时的有效默认账户 UUID；无默认时为 `nil`。
    let expectedDefaultAccountID: UUID?

    /// 用户选择的接替账户；确认无默认时为空。
    let replacementAccountID: UUID?

    /// 没有接替候选时用户是否明确确认继续无默认。
    let allowsNoDefault: Bool
}

/// 账户管理界面展示的处置预检快照；最终提交仍必须重新读取。
struct AccountDisposalPlan: Identifiable, Equatable, Sendable {
    /// 目标账户稳定 UUID。
    let accountID: UUID

    /// 确认界面展示的账户名称快照。
    let accountName: String

    /// 当前余额的值类型快照。
    let balance: Decimal

    /// 目标账户关联的全部流水数量。
    let transactionCount: Int

    /// 预检时解析出的有效默认账户 UUID。
    let defaultAccountID: UUID?

    /// 可作为默认接替者的值类型候选。
    let replacementCandidates: [AccountCandidate]

    /// `sheet(item:)` 使用目标账户 UUID 作为稳定标识。
    var id: UUID { accountID }

    /// 没有流水时可以永久删除。
    var canPermanentlyDelete: Bool { transactionCount == 0 }

    /// 余额为零时可以停用。
    var canDeactivate: Bool { balance == .zero }

    /// 是否需要为当前默认选择接替者或确认无默认。
    var isCurrentDefault: Bool { defaultAccountID == accountID }
}

/// 默认接替选择器使用的稳定值类型账户候选。
struct AccountCandidate: Identifiable, Equatable, Sendable {
    /// 候选账户 UUID。
    let id: UUID

    /// 候选账户展示名称。
    let name: String
}

/// 在主 actor 上串行管理本地账户和默认偏好的仓库。
@MainActor
final class LocalAccountRepository {
    /// 应用或测试持有的完整本地财务容器；每个命令从这里创建新 context。
    private let container: ModelContainer

    /// 测试可注入的保存前故障点；生产环境默认为空操作。
    private let beforeSave: () throws -> Void

    /// 使用应用级容器创建账户仓库。
    init(
        container: ModelContainer,
        beforeSave: @escaping () throws -> Void = {}
    ) {
        self.container = container
        self.beforeSave = beforeSave
    }

    /// 为兼容既有测试和诊断提供一个关闭自动保存的新鲜 context。
    var modelContext: ModelContext {
        makeContext()
    }

    /// 校验草稿、拒绝重复 UUID，并原子地插入账户及必要的默认偏好。
    func save(
        _ draft: AccountDraft,
        locale: Locale = .current,
        now: Date = .now
    ) throws {
        let account = try Account.validating(draft: draft, locale: locale, now: now)
        let context = makeContext()
        guard try self.account(id: draft.id, in: context) == nil else {
            throw AccountRepositoryError.duplicateID(draft.id)
        }

        try persistChanges(in: context) {
            context.insert(account)
            let preference = try canonicalPreference(in: context)
            let accounts = try allAccounts(in: context) + [account]
            if BookkeepingPreference.resolvedAccountID(
                preference: preference,
                accounts: accounts
            ) == nil, account.isEligibleForDefault {
                preference.defaultAccountID = account.id
            }
        }
    }

    /// 校验并原子更新已有账户资料，不改变余额、状态或账户流水。
    func update(
        _ draft: AccountEditDraft,
        now: Date = .now
    ) throws {
        let context = makeContext()
        guard let account = try account(id: draft.id, in: context) else {
            throw AccountRepositoryError.accountNotFound(draft.id)
        }
        guard account.isActive else {
            throw AccountRepositoryError.accountDeactivated(draft.id)
        }

        try persistChanges(in: context) {
            try account.applying(draft, now: now)
        }
    }

    /// 手动切换唯一的全局默认记账账户。
    func setDefaultAccount(id: UUID) throws {
        let context = makeContext()
        guard let account = try account(id: id, in: context), account.isEligibleForDefault else {
            throw AccountRepositoryError.invalidDefaultCandidate(id)
        }

        try persistChanges(in: context) {
            let preference = try canonicalPreference(in: context)
            preference.defaultAccountID = account.id
        }
    }

    /// 读取当前有效默认；失效 UUID 只在读取结果中降级为无默认，不写库。
    func defaultResolution() throws -> BookkeepingDefaultResolution {
        let context = makeContext()
        return try BookkeepingPreference.resolution(
            preference: preference(in: context),
            accounts: allAccounts(in: context)
        )
    }

    /// 返回当前启用且符合默认资格的候选账户。
    func defaultCandidates() throws -> [AccountCandidate] {
        try accounts()
            .filter { $0.isEligibleForDefault }
            .map { AccountCandidate(id: $0.id, name: $0.name) }
    }

    /// 返回账户处置确认所需的当前状态快照。
    func disposalExpectation(
        for accountID: UUID,
        action: AccountDisposalAction,
        replacementAccountID: UUID? = nil,
        allowsNoDefault: Bool = false
    ) throws -> AccountDisposalExpectation {
        AccountDisposalExpectation(
            accountID: accountID,
            action: action,
            expectedDefaultAccountID: try effectiveDefaultAccountID(),
            replacementAccountID: replacementAccountID,
            allowsNoDefault: allowsNoDefault
        )
    }

    /// 生成删除或停用确认界面使用的值类型预检快照。
    func disposalPlan(for accountID: UUID) throws -> AccountDisposalPlan {
        let context = makeContext()
        guard let account = try account(id: accountID, in: context) else {
            throw AccountRepositoryError.accountNotFound(accountID)
        }
        let accounts = try allAccounts(in: context)
        let defaultAccountID = BookkeepingPreference.resolvedAccountID(
            preference: try preference(in: context),
            accounts: accounts
        )
        let candidates = accounts
            .filter { $0.id != accountID && $0.isEligibleForDefault }
            .sorted(by: AccountOrdering.newestFirst)
            .map { AccountCandidate(id: $0.id, name: $0.name) }
        return AccountDisposalPlan(
            accountID: accountID,
            accountName: account.name,
            balance: account.balance,
            transactionCount: try transactionCount(for: accountID, in: context),
            defaultAccountID: defaultAccountID,
            replacementCandidates: candidates
        )
    }

    /// 在最终边界重新校验并原子执行永久删除或停用。
    func dispose(
        _ expectation: AccountDisposalExpectation,
        now: Date = .now
    ) throws {
        let context = makeContext()
        guard let account = try account(id: expectation.accountID, in: context) else {
            throw AccountRepositoryError.accountNotFound(expectation.accountID)
        }
        guard account.isActive else {
            throw AccountRepositoryError.accountDeactivated(expectation.accountID)
        }

        let accounts = try allAccounts(in: context)
        let preference = try preference(in: context)
        let currentDefault = BookkeepingPreference.resolvedAccountID(
            preference: preference,
            accounts: accounts
        )
        guard currentDefault == expectation.expectedDefaultAccountID else {
            throw AccountRepositoryError.expectedStateChanged
        }

        let isCurrentDefault = currentDefault == account.id
        let replacement = try validatedReplacement(
            expectation.replacementAccountID,
            excluding: account.id,
            in: accounts,
            isRequired: isCurrentDefault,
            allowsNoDefault: expectation.allowsNoDefault
        )
        let transactionCount = try transactionCount(for: account.id, in: context)

        switch expectation.action {
        case .delete:
            guard transactionCount == 0 else {
                throw AccountRepositoryError.accountHasTransactions(account.id)
            }
        case .deactivate:
            guard account.balance == .zero else {
                throw AccountRepositoryError.nonZeroBalance(account.id)
            }
        }

        try persistChanges(in: context) {
            switch expectation.action {
            case .delete:
                context.delete(account)
            case .deactivate:
                account.deactivatedAt = now
            }

            if isCurrentDefault {
                let canonicalPreference = try canonicalPreference(in: context)
                canonicalPreference.defaultAccountID = replacement?.id
            }
        }
    }

    /// 恢复停用账户；无有效默认时，合格账户在同一次保存中自动成为默认。
    func restore(id: UUID) throws {
        let context = makeContext()
        guard let account = try account(id: id, in: context) else {
            throw AccountRepositoryError.accountNotFound(id)
        }
        guard !account.isActive else {
            throw AccountRepositoryError.accountAlreadyActive(id)
        }

        try persistChanges(in: context) {
            account.deactivatedAt = nil
            let preference = try canonicalPreference(in: context)
            let accounts = try allAccounts(in: context)
            if BookkeepingPreference.resolvedAccountID(
                preference: preference,
                accounts: accounts
            ) == nil, account.isEligibleForDefault {
                preference.defaultAccountID = account.id
            }
        }
    }

    /// 获取指定稳定 UUID 的当前账户；读取命令使用新鲜 context。
    func account(id: UUID) throws -> Account? {
        try account(id: id, in: makeContext())
    }

    /// 获取确定性排序的全部账户，包含停用账户供管理和历史详情使用。
    func accounts() throws -> [Account] {
        try allAccounts(in: makeContext()).sorted(by: AccountOrdering.newestFirst)
    }

    /// 获取当前有效默认 UUID，不修改失效偏好。
    private func effectiveDefaultAccountID() throws -> UUID? {
        let context = makeContext()
        return BookkeepingPreference.resolvedAccountID(
            preference: try preference(in: context),
            accounts: try allAccounts(in: context)
        )
    }

    /// 创建或读取 canonical singleton；只在写命令中调用。
    private func canonicalPreference(in context: ModelContext) throws -> BookkeepingPreference {
        if let preference = try preference(in: context) {
            return preference
        }
        let preference = BookkeepingPreference()
        context.insert(preference)
        return preference
    }

    /// 读取固定 singleton，忽略非 canonical 的偏好记录。
    private func preference(in context: ModelContext) throws -> BookkeepingPreference? {
        let singletonID = BookkeepingPreference.singletonID
        var descriptor = FetchDescriptor<BookkeepingPreference>(
            predicate: #Predicate<BookkeepingPreference> { preference in
                preference.id == singletonID
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// 在同一 context 中读取全部账户。
    private func allAccounts(in context: ModelContext) throws -> [Account] {
        try context.fetch(FetchDescriptor<Account>())
    }

    /// 在同一 context 中按 UUID 读取账户。
    private func account(id: UUID, in context: ModelContext) throws -> Account? {
        let accountID = id
        var descriptor = FetchDescriptor<Account>(
            predicate: #Predicate<Account> { account in
                account.id == accountID
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// 统计账户关联的全部流水类型，未来新增流水无需修改删除语义。
    private func transactionCount(for accountID: UUID, in context: ModelContext) throws -> Int {
        let targetAccountID = accountID
        let descriptor = FetchDescriptor<AccountTransaction>(
            predicate: #Predicate<AccountTransaction> { transaction in
                transaction.accountID == targetAccountID
            }
        )
        return try context.fetchCount(descriptor)
    }

    /// 在最终提交时校验接替账户和“无默认”确认。
    private func validatedReplacement(
        _ replacementID: UUID?,
        excluding accountID: UUID,
        in accounts: [Account],
        isRequired: Bool,
        allowsNoDefault: Bool
    ) throws -> Account? {
        guard isRequired else {
            guard replacementID == nil else { throw AccountRepositoryError.expectedStateChanged }
            return nil
        }

        if let replacementID {
            guard replacementID != accountID,
                  let replacement = accounts.first(where: { $0.id == replacementID }),
                  replacement.isEligibleForDefault
            else { throw AccountRepositoryError.expectedStateChanged }
            return replacement
        }

        let candidates = accounts.filter {
            $0.id != accountID && $0.isEligibleForDefault
        }
        if candidates.isEmpty {
            guard allowsNoDefault else {
                throw AccountRepositoryError.noDefaultConfirmationRequired(accountID)
            }
            return nil
        }
        throw AccountRepositoryError.replacementRequired(accountID)
    }

    /// 创建一个关闭自动保存的新鲜 context。
    private func makeContext() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    /// 在单个 context 中执行变更、显式保存并统一回滚失败。
    private func persistChanges(
        in context: ModelContext,
        _ changes: () throws -> Void
    ) throws {
        do {
            try changes()
            try beforeSave()
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}
