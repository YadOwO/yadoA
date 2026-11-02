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

/// 一次修改账户的组合变更，按「恢复 → 改资料 → 设为默认 → 停用」的顺序在一次保存中执行。
///
/// 语音会话一句话可能同时恢复并改名、或改资料并设为默认，拆成多次保存时后一步失败会留下半截改动。
struct AccountChange: Equatable, Sendable {
    /// 恢复停用账户；恢复后没有有效默认且账户可以当默认时，同时设为默认，与 `restore(id:)` 一致。
    var restores = false

    /// 新的名称、备注与卡号后四位；为 `nil` 表示不改。
    var profile: AccountEditDraft?

    /// 设为默认记账账户。
    var setsDefault = false

    /// 停用账户；要求余额为 0，且不是当前默认账户。
    var deactivates = false
}

/// 账户全部持久化字段的值类型快照，撤销语音会话对账户的修改或删除时按它原样还原。
struct AccountSnapshot: Equatable, Sendable {
    /// 账户稳定 UUID。
    let id: UUID

    /// `AccountType.rawValue` 的持久化值。
    let typeRawValue: String

    /// 模板稳定标识。
    let templateID: String?

    /// 账户名称。
    let name: String

    /// 备注。
    let note: String?

    /// 卡号后四位。
    let lastFourDigits: String?

    /// 当前余额。
    let balance: Decimal

    /// 期初余额。
    let openingBalance: Decimal

    /// 货币代码。
    let currencyCode: String

    /// 创建时间。
    let createdAt: Date

    /// 资料更新时间。
    let updatedAt: Date

    /// 停用时间；启用中为 `nil`。
    let deactivatedAt: Date?

    /// 拷贝账户当前的全部字段。
    init(account: Account) {
        id = account.id
        typeRawValue = account.typeRawValue
        templateID = account.templateID
        name = account.name
        note = account.note
        lastFourDigits = account.lastFourDigits
        balance = account.balance
        openingBalance = account.openingBalance
        currencyCode = account.currencyCode
        createdAt = account.createdAt
        updatedAt = account.updatedAt
        deactivatedAt = account.deactivatedAt
    }

    /// 按快照生成尚未插入 context 的账户。
    func makeAccount() -> Account {
        Account(
            id: id, typeRawValue: typeRawValue, templateID: templateID, name: name, note: note,
            lastFourDigits: lastFourDigits, balance: balance, openingBalance: openingBalance,
            currencyCode: currencyCode, createdAt: createdAt, updatedAt: updatedAt, deactivatedAt: deactivatedAt
        )
    }
}

/// 撤销语音会话中一次账户改动的反向变更。
enum AccountRevert: Equatable, Sendable {
    /// 删除新建的账户；账户已有流水，或还原默认账户后它仍是默认账户时失败。
    case remove(accountID: UUID)

    /// 把名称、备注、卡号后四位、启用状态与资料更新时间还原为快照，余额不动。
    ///
    /// 要重新停用账户时与停用约束一致：余额须为 0，且不是默认账户。
    case restore(AccountSnapshot)

    /// 按快照插回被删除的账户。
    case reinsert(AccountSnapshot)
}

/// 一次账户改动对默认记账账户偏好的修改，只在改动确实换了默认账户时记录。
///
/// 撤销时只在偏好仍是 `after` 时改回 `before`；期间用户或其他设备另选了默认，保留新的选择。
struct DefaultAccountChange: Equatable, Sendable {
    /// 改动前偏好中记录的默认账户。
    let before: UUID?

    /// 改动后偏好中记录的默认账户。
    let after: UUID?
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
        try save([draft], locale: locale, now: now)
    }

    /// 一次保存多个账户：全部校验通过才写入，要么都成功，要么都不生效。
    ///
    /// 还没有默认记账账户时，按传入顺序把第一个符合资格的账户设为默认。首次引导最后一页点按钮时用它一次写入用户选的账户。
    /// - Parameters:
    ///   - drafts: 按用户选择顺序排列的账户草稿。
    ///   - locale: 解析金额时使用的语言环境。
    ///   - now: 注入的创建和更新时间。
    /// - Throws: 任一草稿校验失败、UUID 重复或保存失败时抛出，此时不写入任何账户。
    func save(
        _ drafts: [AccountDraft],
        locale: Locale = .current,
        now: Date = .now
    ) throws {
        guard !drafts.isEmpty else { return }
        let accounts = try drafts.map { try Account.validating(draft: $0, locale: locale, now: now) }
        let context = makeContext()
        var seenIDs: Set<UUID> = []
        for draft in drafts {
            guard seenIDs.insert(draft.id).inserted, try context.account(id: draft.id) == nil else {
                throw AccountRepositoryError.duplicateID(draft.id)
            }
        }

        try persistChanges(in: context) {
            let preference = try canonicalPreference(in: context)
            var knownAccounts = try allAccounts(in: context)
            for account in accounts {
                context.insert(account)
                knownAccounts.append(account)
                if BookkeepingPreference.resolvedAccountID(
                    preference: preference,
                    accounts: knownAccounts
                ) == nil, account.isEligibleForDefault {
                    preference.defaultAccountID = account.id
                }
            }
        }
    }

    /// 校验并原子更新已有账户资料，不改变余额、状态或账户流水。
    func update(
        _ draft: AccountEditDraft,
        now: Date = .now
    ) throws {
        let context = makeContext()
        guard let account = try context.account(id: draft.id) else {
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
        guard let account = try context.account(id: id), account.isEligibleForDefault else {
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
            preference: context.canonicalBookkeepingPreference(),
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
        guard let account = try context.account(id: accountID) else {
            throw AccountRepositoryError.accountNotFound(accountID)
        }
        let accounts = try allAccounts(in: context)
        let defaultAccountID = BookkeepingPreference.resolvedAccountID(
            preference: try context.canonicalBookkeepingPreference(),
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
        guard let account = try context.account(id: expectation.accountID) else {
            throw AccountRepositoryError.accountNotFound(expectation.accountID)
        }
        guard account.isActive else {
            throw AccountRepositoryError.accountDeactivated(expectation.accountID)
        }

        let accounts = try allAccounts(in: context)
        let preference = try context.canonicalBookkeepingPreference()
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
        guard let account = try context.account(id: id) else {
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

    /// 在一次保存中依次恢复、改资料、设为默认、停用一个账户，任一步不符合约束则整体不生效。
    ///
    /// 恢复已启用的账户视为没有变化；其余约束与 `restore(id:)`、`update(_:now:)`、`setDefaultAccount(id:)`、
    /// `dispose(_:now:)` 一致。停用当前默认账户时不自动选接替者，直接拒绝，由调用方先设好新的默认。
    ///
    /// - Parameters:
    ///   - change: 要执行的组合变更。
    ///   - id: 目标账户 UUID。
    ///   - now: 资料更新与停用时间。
    /// - Throws: `AccountRepositoryError` 或 `AccountValidationError`。
    func apply(_ change: AccountChange, toAccount id: UUID, now: Date = .now) throws {
        let context = makeContext()
        guard let account = try context.account(id: id) else {
            throw AccountRepositoryError.accountNotFound(id)
        }

        try persistChanges(in: context) {
            if change.restores, !account.isActive {
                account.deactivatedAt = nil
                if try effectiveDefaultAccountID(in: context) == nil, account.isEligibleForDefault {
                    try canonicalPreference(in: context).defaultAccountID = account.id
                }
            }
            guard account.isActive else {
                throw AccountRepositoryError.accountDeactivated(id)
            }
            if let profile = change.profile {
                try account.applying(profile, now: now)
            }
            if change.setsDefault {
                guard account.isEligibleForDefault else {
                    throw AccountRepositoryError.invalidDefaultCandidate(id)
                }
                try canonicalPreference(in: context).defaultAccountID = account.id
            }
            if change.deactivates {
                guard try effectiveDefaultAccountID(in: context) != account.id else {
                    throw AccountRepositoryError.replacementRequired(id)
                }
                guard account.balance == .zero else {
                    throw AccountRepositoryError.nonZeroBalance(id)
                }
                account.deactivatedAt = now
            }
        }
    }

    /// 在调用方的 context 中执行一次账户反向变更，并按需还原默认记账账户；不保存。
    ///
    /// 撤销语音会话的一轮时，与收支、转账、余额调整的反向变更在同一次保存中提交。
    /// 先还原默认账户，再还原账户本身：要删除或重新停用的账户此时不能还是默认账户。
    ///
    /// - Parameters:
    ///   - revert: 反向变更。
    ///   - defaultChange: 改动对默认账户的修改；为 `nil` 时不碰默认账户。
    ///   - context: 调用方的 manual-save context。
    /// - Throws: 账户不存在、已有流水、UUID 冲突，要删除的账户是默认账户，或要重新停用的账户余额不为 0、
    ///   已是默认账户时抛出
    ///   `AccountRepositoryError`，由调用方回滚。
    func revert(_ revert: AccountRevert, defaultChange: DefaultAccountChange?, in context: ModelContext) throws {
        if let defaultChange,
           let preference = try context.canonicalBookkeepingPreference(),
           preference.defaultAccountID == defaultChange.after {
            preference.defaultAccountID = defaultChange.before
        }
        switch revert {
        case let .remove(accountID):
            guard let account = try context.account(id: accountID) else {
                throw AccountRepositoryError.accountNotFound(accountID)
            }
            guard try transactionCount(for: accountID, in: context) == 0 else {
                throw AccountRepositoryError.accountHasTransactions(accountID)
            }
            // 新建后被别处设为默认：直接删除会让默认偏好指向不存在的账户
            guard try context.canonicalBookkeepingPreference()?.defaultAccountID != accountID else {
                throw AccountRepositoryError.replacementRequired(accountID)
            }
            context.delete(account)
        case let .restore(snapshot):
            guard let account = try context.account(id: snapshot.id) else {
                throw AccountRepositoryError.accountNotFound(snapshot.id)
            }
            if snapshot.deactivatedAt != nil, account.isActive {
                // 改动恢复了这个账户，之后可能有人往里记了账或把它设为默认；与停用账户的约束一致
                guard account.balance == .zero else {
                    throw AccountRepositoryError.nonZeroBalance(snapshot.id)
                }
                guard try effectiveDefaultAccountID(in: context) != account.id else {
                    throw AccountRepositoryError.replacementRequired(snapshot.id)
                }
            }
            account.name = snapshot.name
            account.note = snapshot.note
            account.lastFourDigits = snapshot.lastFourDigits
            account.updatedAt = snapshot.updatedAt
            account.deactivatedAt = snapshot.deactivatedAt
        case let .reinsert(snapshot):
            guard try context.account(id: snapshot.id) == nil else {
                throw AccountRepositoryError.duplicateID(snapshot.id)
            }
            context.insert(snapshot.makeAccount())
        }
    }

    /// 获取指定稳定 UUID 的当前账户；读取命令使用新鲜 context。
    func account(id: UUID) throws -> Account? {
        try makeContext().account(id: id)
    }

    /// 获取确定性排序的全部账户，包含停用账户供管理和历史详情使用。
    func accounts() throws -> [Account] {
        try allAccounts(in: makeContext()).sorted(by: AccountOrdering.newestFirst)
    }

    /// 获取当前有效默认 UUID，不修改失效偏好。
    private func effectiveDefaultAccountID() throws -> UUID? {
        try effectiveDefaultAccountID(in: makeContext())
    }

    /// 在指定 context 中解析当前有效默认 UUID，能看到该 context 尚未保存的修改。
    private func effectiveDefaultAccountID(in context: ModelContext) throws -> UUID? {
        BookkeepingPreference.resolvedAccountID(
            preference: try context.canonicalBookkeepingPreference(),
            accounts: try allAccounts(in: context)
        )
    }

    /// 创建或读取 canonical singleton；只在写命令中调用。
    private func canonicalPreference(in context: ModelContext) throws -> BookkeepingPreference {
        if let preference = try context.canonicalBookkeepingPreference() {
            return preference
        }
        let preference = BookkeepingPreference()
        preference.isAutoCreated = true
        context.insert(preference)
        return preference
    }

    /// 在同一 context 中读取全部账户。
    private func allAccounts(in context: ModelContext) throws -> [Account] {
        try context.fetch(FetchDescriptor<Account>())
    }

    /// 统计账户关联的全部流水类型，包括转入该账户的转账；未来新增流水无需修改删除语义。
    private func transactionCount(for accountID: UUID, in context: ModelContext) throws -> Int {
        let targetAccountID = accountID
        let descriptor = FetchDescriptor<AccountTransaction>(
            predicate: #Predicate<AccountTransaction> { transaction in
                transaction.accountID == targetAccountID
                    || transaction.counterpartAccountID == targetAccountID
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
        if allowsNoDefault {
            throw AccountRepositoryError.expectedStateChanged
        }
        throw AccountRepositoryError.replacementRequired(accountID)
    }

    /// 创建一个关闭自动保存的新鲜 context。
    private func makeContext() -> ModelContext {
        container.makeManualSaveContext()
    }

    /// 在单个 context 中执行变更、显式保存并统一回滚失败。
    private func persistChanges(
        in context: ModelContext,
        _ changes: () throws -> Void
    ) throws {
        do {
            try changes()
        } catch {
            context.rollback()
            throw error
        }
        try context.saveOrRollback(beforeSave: beforeSave)
    }
}
