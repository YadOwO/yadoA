import Foundation
import SwiftData

/// 一次流水变更在首页上要播放的提示，与 `HomeRecentEntryHighlight` 的三种提示对应。
enum VoiceEntryHighlight: Equatable {
    /// 新记了一笔。
    case added(id: UUID, transactionDay: Int)

    /// 修改了一笔；携带修改前的首页行快照。
    case updated(id: UUID, transactionDay: Int, previous: HomeOverviewRowPresentation?)

    /// 删除了一笔；携带删除前的首页行快照。
    case deleted(HomeOverviewDeletedRow)
}

extension HomeRecentEntryHighlight {
    /// 登记一条语音记账产生的首页提示；首页不在屏幕上时不登记。
    ///
    /// 语音只在用户正看着首页时原地提示。在别的页面说的、或在别的页面撤销的，回到首页时不再自动跳月份标红，
    /// 想看哪一笔点会话卡片上的结果定位。
    /// - Parameter highlight: 变更对应的提示。
    func mark(_ highlight: VoiceEntryHighlight) {
        guard isHomeVisible else { return }
        switch highlight {
        case let .added(id, transactionDay):
            mark(id: id, transactionDay: transactionDay)
        case let .updated(id, transactionDay, previous):
            mark(id: id, transactionDay: transactionDay, change: .updated(previous: previous))
        case let .deleted(row):
            markDeleted(row)
        }
    }
}

/// 一次工具执行成功写入的流水变更，供结果展示、撤销与首页提示使用。
struct VoiceEntryChange: Equatable, Identifiable {
    /// 变更类型。
    enum Kind: Equatable {
        /// 新增。
        case created

        /// 修改。
        case updated

        /// 删除。
        case deleted
    }

    /// 本次变更的唯一标识；同一笔流水在一轮里可能先后被改多次。
    let id = UUID()

    /// 变更类型。
    let kind: Kind

    /// 流水 UUID。
    let transactionID: UUID

    /// 变更后的 `YYYYMMDD` 记账日；删除时为删除前的记账日。
    let transactionDay: Int

    /// 变更后的流水展示；删除时为删除前的样子。流水不在首页展示范围内时为 `nil`。
    let row: HomeOverviewRowPresentation?

    /// 流水所属账户的名称；账户不存在时为 `nil`。
    let accountName: String?

    /// 结果提示里称呼这笔流水的文字：备注、标题或分类名称，例如「午饭」。
    let label: String

    /// 不带正负号的本地化金额，例如「¥28.00」。
    let formattedAmount: String

    /// 由 AI 推断或取了默认值的字段，只有新增时可能非空。
    let inferredFields: [VoiceInferredField]

    /// 撤销本次变更的反向操作。
    let inverse: BookkeepingEntryMutation

    /// 首页提示；删除的流水不在首页展示范围、没有残影可画时为 `nil`。
    let highlight: VoiceEntryHighlight?
}

/// 账户相关改动撤销时执行的反向变更。
enum VoiceAccountInverse: Equatable {
    /// 删除余额调整流水，并从账户余额中扣回它的差额。
    case removeBalanceAdjustment(UUID)

    /// 删除转账流水，并改回两边账户的余额。
    case removeTransfer(UUID)

    /// 还原账户；改动换了默认记账账户时一并改回，没换时为 `nil`。
    case account(AccountRevert, defaultChange: DefaultAccountChange?)
}

/// 一次工具执行成功写入的账户相关改动：余额调整、转账、新建、修改或删除账户。
///
/// 余额调整与转账不在首页明细中展示，结果里点这一行打开账户详情，而不是在首页定位；
/// 文字在执行时按当时的语言生成，账户之后改名也不影响已展示的结果。
struct VoiceAccountChange: Equatable, Identifiable {
    /// 本次改动的唯一标识。
    let id = UUID()

    /// 改动涉及、改动后仍然存在的账户，转账时依次为转出、转入账户；删除账户时为空。
    ///
    /// 结果里点这一行打开第一个账户的详情，账户页列表在这些账户上补笔迹提示。
    let accountIDs: [UUID]

    /// 行首的动作，例如「调整余额」「转账」「新建账户」「已停用」。
    let actionText: String

    /// 行标题：账户名称；转账时为「招行 → 微信」。
    let title: String

    /// 行图标，取账户模板或类型的图标。
    let symbolName: String

    /// 行尾金额：调整后的余额、转账金额或新账户的余额；修改、删除账户时为 `nil`。
    let formattedAmount: String?

    /// 补充说明，例如「原 ¥500.00」「储蓄卡 · 待确认：余额」。
    let detail: String?

    /// 结果提示中的一句，例如「已把微信的余额调整为 ¥487.50」。
    let summary: String

    /// 撤销本次改动的反向变更。
    let inverse: VoiceAccountInverse
}

/// 一次工具执行成功写入的改动；一轮按执行顺序记录，撤销时倒序执行。
enum VoiceChange: Equatable, Identifiable {
    /// 收支流水的新增、修改、删除，可以在首页定位。
    case entry(VoiceEntryChange)

    /// 账户相关的改动。
    case account(VoiceAccountChange)

    /// 改动的唯一标识。
    var id: UUID {
        switch self {
        case let .entry(change): change.id
        case let .account(change): change.id
        }
    }

    /// 收支流水的改动；账户相关的改动为 `nil`。
    var entryChange: VoiceEntryChange? {
        if case let .entry(change) = self { return change }
        return nil
    }
}

/// 一次工具执行的结果。
struct VoiceToolExecution: Equatable {
    /// 回传给服务端的执行结果。
    let result: VoiceToolResult

    /// 成功写入时的改动；查询、汇总和失败时为 `nil`。
    let change: VoiceChange?
}

/// 在本机执行语音记账会话的工具调用。
///
/// 收支的新增、修改、删除都经由 `LocalExpenseRepository.apply(_:)`，与手动记账使用同一套账户、分类、
/// 金额校验和余额联动；余额调整、转账与账户的增删改分别经由对应的本地仓库，规则与手动操作一致。
/// 查询与汇总只读本地数据，不包含余额调整和转账。
struct VoiceToolExecutor {
    /// 应用持有的本地财务容器。
    let container: ModelContainer

    /// 生成首页行快照和名称使用的语言环境。
    let locale: Locale

    /// 生成首页行快照使用的日历。
    let calendar: Calendar

    /// 时间源，作为新流水的保存时间。
    var now: () -> Date = { .now }

    /// 测试可注入的保存前故障点。
    var beforeSave: () throws -> Void = {}

    /// 执行一次工具调用；任何错误都转换为失败结果回传，不向调用方抛出。
    ///
    /// - Parameter call: 服务端下发的工具调用。
    /// - Returns: 回传结果与成功写入时的流水变更。
    func execute(_ call: VoiceToolCall) -> VoiceToolExecution {
        let (output, change): (VoiceToolOutput, VoiceChange?) = switch call {
        case let .searchTransactions(_, input): (search(input), nil)
        case let .summarizeTransactions(_, input): (summarize(input), nil)
        case let .createTransaction(_, input): Self.entry(create(input))
        case let .updateTransaction(_, input): Self.entry(update(input))
        case let .deleteTransaction(_, input): Self.entry(delete(input))
        case let .adjustBalance(_, input): Self.account(adjustBalance(input))
        case let .transfer(_, input): Self.account(transfer(input))
        case let .createAccount(_, input): Self.account(createAccount(input))
        case let .updateAccount(_, input): Self.account(updateAccount(input))
        case let .deleteAccount(_, input): Self.account(deleteAccount(input))
        }
        return VoiceToolExecution(
            result: VoiceToolResult(toolCallId: call.id, name: call.name, output: output),
            change: change
        )
    }

    /// 撤销一轮中的全部改动：按相反顺序在一次保存中执行反向操作，失败时没有任何改动生效。
    ///
    /// 收支与账户相关的改动可能交错（例如先新建账户再往里记账），必须在同一个 context 里倒序撤销。
    ///
    /// - Parameter changes: 这一轮按执行顺序记录的改动。
    /// - Returns: 撤销后首页要播放的提示。
    /// - Throws: 反向操作不符合约束（例如期间账户被停用）或保存失败时抛出错误。
    func revert(_ changes: [VoiceChange]) throws -> [VoiceEntryHighlight] {
        let context = container.makeManualSaveContext()
        let catalog = Self.catalog(in: context)
        // 撤销前拷贝首页行快照：撤销新增的要画删除残影，撤销修改的要展示从什么改回什么
        let highlights = changes.reversed().compactMap(\.entryChange).compactMap { change -> VoiceEntryHighlight? in
            let transaction = try? context.transaction(id: change.transactionID)
            switch change.kind {
            case .created:
                return transaction
                    .flatMap { HomeOverviewPresentation.deletedRow(for: $0, locale: locale, calendar: calendar, catalog: catalog) }
                    .map(VoiceEntryHighlight.deleted)
            case .updated:
                guard case let .replace(previous) = change.inverse else { return nil }
                let current = transaction.flatMap {
                    HomeOverviewPresentation.row(for: $0, locale: locale, calendar: calendar, catalog: catalog)
                }
                return .updated(id: previous.id, transactionDay: previous.transactionDay, previous: current)
            case .deleted:
                guard case let .insert(previous) = change.inverse else { return nil }
                return .added(id: previous.id, transactionDay: previous.transactionDay)
            }
        }
        let entries = repository
        let accounts = accountRepository
        do {
            for change in changes.reversed() {
                switch change {
                case let .entry(entry):
                    try entries.apply(entry.inverse, in: context)
                case let .account(account):
                    try revert(account.inverse, accounts: accounts, in: context)
                }
            }
        } catch {
            context.rollback()
            throw error
        }
        try context.saveOrRollback(beforeSave: beforeSave)
        return highlights
    }

    /// 在撤销用的 context 中执行一次账户相关的反向变更；不保存。
    private func revert(
        _ inverse: VoiceAccountInverse,
        accounts: LocalAccountRepository,
        in context: ModelContext
    ) throws {
        switch inverse {
        case let .removeBalanceAdjustment(id):
            try LocalBalanceAdjustmentRepository.delete(id: id, in: context)
        case let .removeTransfer(id):
            try LocalTransferRepository.delete(id: id, in: context)
        case let .account(revert, defaultChange):
            try accounts.revert(revert, defaultChange: defaultChange, in: context)
        }
    }

    /// 把收支流水的执行结果包装为通用改动。
    private static func entry(_ result: (VoiceToolOutput, VoiceEntryChange?)) -> (VoiceToolOutput, VoiceChange?) {
        (result.0, result.1.map(VoiceChange.entry))
    }

    /// 把账户相关的执行结果包装为通用改动。
    private static func account(_ result: (VoiceToolOutput, VoiceAccountChange?)) -> (VoiceToolOutput, VoiceChange?) {
        (result.0, result.1.map(VoiceChange.account))
    }

    // MARK: - 写入

    private var repository: LocalExpenseRepository {
        LocalExpenseRepository(container: container, beforeSave: beforeSave)
    }

    private var accountRepository: LocalAccountRepository {
        LocalAccountRepository(container: container, beforeSave: beforeSave)
    }

    private func create(_ input: VoiceCreateTransactionInput) -> (VoiceToolOutput, VoiceEntryChange?) {
        guard let accountID = UUID(uuidString: input.accountId),
              let amount = Self.amount(from: input.amount),
              let transactionDay = Self.transactionDay(from: input.date)
        else { return (.failure(.invalidInput), nil) }

        let snapshot = BookkeepingEntrySnapshot(
            id: UUID(),
            accountID: accountID,
            entryType: BookkeepingEntryType(input.type),
            categoryKey: input.categoryId,
            amount: amount,
            transactionDay: transactionDay,
            note: input.note.map { String($0.prefix(VoiceSessionLimits.maxWrittenNoteLength)) },
            savedAt: now()
        )
        do {
            try repository.apply([.insert(snapshot)])
        } catch {
            return (.failure(Self.errorCode(for: error)), nil)
        }
        let change = makeChange(
            kind: .created,
            snapshot: snapshot,
            inferredFields: input.inferredFields,
            inverse: .delete(snapshot.id),
            highlight: .added(id: snapshot.id, transactionDay: snapshot.transactionDay)
        )
        return (.created(id: snapshot.id.uuidString), change)
    }

    private func update(_ input: VoiceUpdateTransactionInput) -> (VoiceToolOutput, VoiceEntryChange?) {
        let target: EditableTarget
        switch editableTarget(id: input.id) {
        case let .success(found): target = found
        case let .failure(code): return (.failure(code), nil)
        }
        let previous = target.snapshot
        var updated = previous
        let patch = input.patch
        if let type = patch.type {
            updated.entryType = BookkeepingEntryType(type)
        }
        if let categoryKey = patch.categoryId {
            updated.categoryKey = categoryKey
        }
        if let amountText = patch.amount {
            guard let amount = Self.amount(from: amountText) else { return (.failure(.invalidInput), nil) }
            updated.amount = amount
        }
        if let accountText = patch.accountId {
            guard let accountID = UUID(uuidString: accountText) else { return (.failure(.invalidInput), nil) }
            updated.accountID = accountID
        }
        if let date = patch.date {
            guard let transactionDay = Self.transactionDay(from: date) else { return (.failure(.invalidInput), nil) }
            updated.transactionDay = transactionDay
        }
        switch patch.note {
        case let .set(note): updated.note = String(note.prefix(VoiceSessionLimits.maxWrittenNoteLength))
        case .clear: updated.note = nil
        case nil: break
        }

        do {
            try repository.apply([.replace(updated)])
        } catch {
            return (.failure(Self.errorCode(for: error)), nil)
        }
        let change = makeChange(
            kind: .updated,
            snapshot: updated,
            inferredFields: [],
            inverse: .replace(previous),
            highlight: .updated(id: updated.id, transactionDay: updated.transactionDay, previous: target.row)
        )
        return (.succeeded, change)
    }

    private func delete(_ input: VoiceDeleteTransactionInput) -> (VoiceToolOutput, VoiceEntryChange?) {
        let target: EditableTarget
        switch editableTarget(id: input.id) {
        case let .success(found): target = found
        case let .failure(code): return (.failure(code), nil)
        }
        do {
            try repository.apply([.delete(target.snapshot.id)])
        } catch {
            return (.failure(Self.errorCode(for: error)), nil)
        }
        let deletedRow = target.deletedRow
        let change = VoiceEntryChange(
            kind: .deleted,
            transactionID: target.snapshot.id,
            transactionDay: target.snapshot.transactionDay,
            row: deletedRow?.row,
            accountName: target.accountName,
            label: label(for: target.snapshot, catalog: target.catalog),
            formattedAmount: formattedAmount(target.snapshot.amount),
            inferredFields: [],
            inverse: .insert(target.snapshot),
            highlight: deletedRow.map(VoiceEntryHighlight.deleted)
        )
        return (.succeeded, change)
    }

    /// 修改、删除前读取到的目标流水。
    private struct EditableTarget {
        /// 修改、删除前的完整快照。
        let snapshot: BookkeepingEntrySnapshot

        /// 修改前的首页行。
        let row: HomeOverviewRowPresentation?

        /// 删除前的首页残影快照。
        let deletedRow: HomeOverviewDeletedRow?

        /// 所属账户名称。
        let accountName: String?

        /// 读取时的分类目录。
        let catalog: BookkeepingCategoryCatalog
    }

    /// 读取要修改或删除的流水，并确认它可以编辑：必须是收支流水，且所属账户仍启用。
    private func editableTarget(id: String) -> Result<EditableTarget, VoiceToolErrorCode> {
        guard let transactionID = UUID(uuidString: id) else { return .failure(.notFound) }
        let context = container.makeManualSaveContext()
        guard let transaction = try? context.transaction(id: transactionID) else { return .failure(.notFound) }
        guard let snapshot = BookkeepingEntrySnapshot(transaction: transaction),
              let account = try? context.account(id: transaction.accountID),
              account.isActive
        else { return .failure(.notEditable) }
        let catalog = Self.catalog(in: context)
        return .success(EditableTarget(
            snapshot: snapshot,
            row: HomeOverviewPresentation.row(for: transaction, locale: locale, calendar: calendar, catalog: catalog),
            deletedRow: HomeOverviewPresentation.deletedRow(
                for: transaction, locale: locale, calendar: calendar, catalog: catalog
            ),
            accountName: account.name,
            catalog: catalog
        ))
    }

    /// 写入成功后重新读取流水，生成结果展示用的变更记录。
    ///
    /// - Parameters:
    ///   - kind: 变更类型。
    ///   - snapshot: 写入后的流水快照。
    ///   - inferredFields: 新增时由 AI 推断的字段。
    ///   - inverse: 撤销本次变更的反向操作。
    ///   - highlight: 首页提示。
    private func makeChange(
        kind: VoiceEntryChange.Kind,
        snapshot: BookkeepingEntrySnapshot,
        inferredFields: [VoiceInferredField],
        inverse: BookkeepingEntryMutation,
        highlight: VoiceEntryHighlight
    ) -> VoiceEntryChange {
        let context = container.makeManualSaveContext()
        let catalog = Self.catalog(in: context)
        let transaction = try? context.transaction(id: snapshot.id)
        let row = transaction.flatMap {
            HomeOverviewPresentation.row(for: $0, locale: locale, calendar: calendar, catalog: catalog)
        }
        return VoiceEntryChange(
            kind: kind,
            transactionID: snapshot.id,
            transactionDay: snapshot.transactionDay,
            row: row,
            accountName: (try? context.account(id: snapshot.accountID))?.name,
            label: label(for: snapshot, catalog: catalog),
            formattedAmount: formattedAmount(snapshot.amount),
            inferredFields: inferredFields,
            inverse: inverse,
            highlight: highlight
        )
    }

    /// 结果提示里称呼一笔流水的文字：与列表主行一致，优先备注，没有时用分类名称。
    private func label(for snapshot: BookkeepingEntrySnapshot, catalog: BookkeepingCategoryCatalog) -> String {
        BookkeepingEntryLines(
            note: snapshot.note,
            categoryTitle: catalog.resolvedItem(direction: snapshot.entryType, key: snapshot.categoryKey).title(locale: locale)
        ).title
    }

    /// 本地化 CNY 金额；负数（例如透支后的余额）带负号。
    private func formattedAmount(_ amount: Decimal) -> String {
        amount.formatted(.currency(code: "CNY").locale(locale))
    }

    // MARK: - 账户

    private func adjustBalance(_ input: VoiceAdjustBalanceInput) -> (VoiceToolOutput, VoiceAccountChange?) {
        let context = container.makeManualSaveContext()
        guard let accountID = UUID(uuidString: input.accountId), let account = try? context.account(id: accountID) else {
            return (.failure(.notFound), nil)
        }
        let before = account.balance
        // 契约保证目标余额与增减额恰好一个；增减额加到执行时的余额上，信用卡、负债为欠款的增减
        let target: Decimal? = switch (input.targetBalance, input.delta) {
        case let (targetText?, nil):
            Self.signedAmount(from: targetText)
        case let (nil, deltaText?):
            Self.signedAmount(from: deltaText).flatMap { $0 == 0 ? nil : before.exactlyAdding($0) }
        default:
            nil
        }
        guard let target else { return (.failure(.invalidInput), nil) }

        let id = UUID()
        let after: Decimal
        switch saveBalanceAdjustment(id: id, accountID: accountID, target: target, transactionDay: nil, note: input.note) {
        case let .success(balance): after = balance
        case let .failure(code): return (.failure(code), nil)
        }
        let name = displayName(of: account)
        let change = VoiceAccountChange(
            accountIDs: [accountID],
            actionText: text("voice.account.action.adjustBalance"),
            title: name,
            symbolName: symbolName(of: account),
            formattedAmount: formattedAmount(after),
            detail: AccountLocalization.formatted("voice.account.balanceBefore", value: formattedAmount(before), locale: locale),
            summary: String(
                format: text("voice.summary.balanceAdjusted"), locale: locale,
                name, amountLabel(of: account), formattedAmount(after)
            ),
            inverse: .removeBalanceAdjustment(id)
        )
        return (.balanceAdjusted(before: Self.amountString(before), after: Self.amountString(after)), change)
    }

    private func transfer(_ input: VoiceTransferInput) -> (VoiceToolOutput, VoiceAccountChange?) {
        let context = container.makeManualSaveContext()
        /// 读取一边账户：没选时为 `nil`，选了却找不到时失败。
        func side(_ idText: String?) -> Result<Account?, VoiceToolErrorCode> {
            guard let idText else { return .success(nil) }
            guard let id = UUID(uuidString: idText), let account = try? context.account(id: id) else {
                return .failure(.notFound)
            }
            return .success(account)
        }
        let from: Account?
        let to: Account?
        switch (side(input.fromAccountId), side(input.toAccountId)) {
        case let (.success(fromAccount), .success(toAccount)):
            from = fromAccount
            to = toAccount
        case let (.failure(code), _), let (_, .failure(code)):
            return (.failure(code), nil)
        }
        guard let amount = Self.amount(from: input.amount), let transactionDay = Self.transactionDay(from: input.date) else {
            return (.failure(.invalidInput), nil)
        }
        let id = UUID()
        let formattedTransferAmount = formattedAmount(amount)
        let uncertainty = input.isAmountUncertain ? inferredText([text("voice.inferred.amount")]) : nil

        switch (from, to) {
        case let (from?, to?):
            guard from.id != to.id else { return (.failure(.invalidInput), nil) }
            let draft = TransferDraft(
                id: id, fromAccountID: from.id, toAccountID: to.id, amountText: Self.amountString(amount),
                transactionDay: transactionDay, note: Self.writtenNote(input.note)
            )
            do {
                try LocalTransferRepository(container: container, beforeSave: beforeSave).save(draft, savedAt: now())
            } catch {
                return (.failure(Self.errorCode(for: error)), nil)
            }
            let fromName = displayName(of: from)
            let toName = displayName(of: to)
            let change = VoiceAccountChange(
                accountIDs: [from.id, to.id],
                actionText: text("voice.account.action.transfer"),
                title: String(format: text("voice.account.transferTitle"), locale: locale, fromName, toName),
                symbolName: "arrow.left.arrow.right",
                formattedAmount: formattedTransferAmount,
                detail: Self.detail([dateText(transactionDay), uncertainty]),
                summary: String(
                    format: text("voice.summary.transferred"), locale: locale,
                    fromName, formattedTransferAmount, toName
                ),
                inverse: .removeTransfer(id)
            )
            return (.created(id: id.uuidString), change)
        case let (account?, nil), let (nil, account?):
            // 只有一边账户：只给它记一笔余额调整，方向与转账相同，例如只转入信用卡时欠款减少
            let isOutgoing = from != nil
            guard let type = account.accountType,
                  let target = try? LocalExpenseRepository.updatedBalance(
                      account.balance, by: amount,
                      effect: type.expenseBalanceEffect, entryType: isOutgoing ? .expense : .income
                  )
            else { return (.failure(.invalidInput), nil) }
            let after: Decimal
            switch saveBalanceAdjustment(
                id: id, accountID: account.id, target: target, transactionDay: transactionDay, note: input.note
            ) {
            case let .success(balance): after = balance
            case let .failure(code): return (.failure(code), nil)
            }
            let name = displayName(of: account)
            let change = VoiceAccountChange(
                accountIDs: [account.id],
                actionText: text(isOutgoing ? "voice.account.action.transferOut" : "voice.account.action.transferIn"),
                title: name,
                symbolName: symbolName(of: account),
                formattedAmount: formattedTransferAmount,
                detail: Self.detail([
                    AccountLocalization.formatted("voice.account.balanceAfter", value: formattedAmount(after), locale: locale),
                    dateText(transactionDay),
                    uncertainty,
                ]),
                summary: String(
                    format: text(isOutgoing ? "voice.summary.transferredOut" : "voice.summary.transferredIn"),
                    locale: locale, name, formattedTransferAmount
                ),
                inverse: .removeBalanceAdjustment(id)
            )
            return (.created(id: id.uuidString), change)
        case (nil, nil):
            return (.failure(.invalidInput), nil)
        }
    }

    private func createAccount(_ input: VoiceCreateAccountInput) -> (VoiceToolOutput, VoiceAccountChange?) {
        guard let type = AccountType(rawValue: input.type), let balance = Self.nonNegativeAmount(from: input.balance) else {
            return (.failure(.invalidInput), nil)
        }
        var template: AccountTemplate?
        if type.requiresTemplateSelection {
            guard let matched = type.templates.first(where: { $0.id == input.templateId }) else {
                return (.failure(.invalidInput), nil)
            }
            template = matched
        }
        // 银行卡、信用卡在 App 里固定显示机构名称，不采用模型给的名称；没有模板的类型用类型名称兜底
        let requestedName = input.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (type.showsEditableName ? requestedName.flatMap { $0.isEmpty ? nil : $0 } : nil)
            ?? template?.name(locale: locale)
            ?? type.title(locale: locale)
        let id = UUID()
        let draft = AccountDraft(
            id: id, accountType: type, template: template, name: name, note: Self.writtenNote(input.note),
            lastFourDigits: type.showsLastFourDigits ? input.lastFourDigits ?? "" : "",
            amountText: Self.amountString(balance), locale: locale
        )
        let defaultBefore = storedDefaultAccountID()
        do {
            // 金额字符串使用英文句点，按 POSIX 解析，不受界面语言的小数分隔符影响
            try accountRepository.save(draft, locale: Self.contractLocale, now: now())
        } catch {
            return (.failure(Self.errorCode(for: error)), nil)
        }
        let inferredNames = input.inferredFields.map { field in
            switch field {
            case .type: text("voice.inferred.accountType")
            case .balance: text("voice.inferred.balance")
            }
        }
        let change = VoiceAccountChange(
            accountIDs: [id],
            actionText: text("voice.account.action.create"),
            title: name,
            symbolName: template?.symbolName ?? type.symbolName,
            formattedAmount: formattedAmount(balance),
            detail: Self.detail([type.title(locale: locale), inferredText(inferredNames)]),
            summary: AccountLocalization.formatted("voice.summary.accountCreated", value: name, locale: locale),
            inverse: .account(.remove(accountID: id), defaultChange: defaultChange(since: defaultBefore))
        )
        return (.created(id: id.uuidString), change)
    }

    private func updateAccount(_ input: VoiceUpdateAccountInput) -> (VoiceToolOutput, VoiceAccountChange?) {
        let context = container.makeManualSaveContext()
        guard let id = UUID(uuidString: input.accountId), let account = try? context.account(id: id) else {
            return (.failure(.notFound), nil)
        }
        let patch = input.patch
        var change = AccountChange(
            restores: patch.isActive == true,
            setsDefault: patch.setsDefault,
            deactivates: patch.isActive == false
        )
        if patch.name != nil || patch.note != nil || patch.lastFourDigits != nil {
            var profile = AccountEditDraft(account: account)
            if let name = patch.name {
                // 银行卡、信用卡在 App 里固定显示机构名称，编辑页也不能改名
                guard account.accountType?.showsEditableName ?? true else { return (.failure(.invalidInput), nil) }
                profile.name = name
            }
            switch patch.note {
            case let .set(note): profile.note = String(note.prefix(VoiceSessionLimits.maxWrittenNoteLength))
            case .clear: profile.note = ""
            case nil: break
            }
            if let lastFourDigits = patch.lastFourDigits {
                guard account.accountType?.showsLastFourDigits == true else { return (.failure(.invalidInput), nil) }
                switch lastFourDigits {
                case let .set(digits): profile.lastFourDigits = digits
                case .clear: profile.lastFourDigits = ""
                }
            }
            change.profile = profile
        }
        guard change != AccountChange() else { return (.failure(.invalidInput), nil) }

        let snapshot = AccountSnapshot(account: account)
        let defaultBefore = storedDefaultAccountID()
        do {
            try accountRepository.apply(change, toAccount: id, now: now())
        } catch {
            return (.failure(Self.errorCode(for: error)), nil)
        }
        let name = patch.name.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? displayName(of: account)
        // 按执行顺序逐句说明，例如「已恢复账户：工行卡；已把工行卡设为默认记账账户」
        var sentences: [String] = []
        if change.restores { sentences.append(AccountLocalization.formatted("voice.summary.accountRestored", value: name, locale: locale)) }
        if change.profile != nil { sentences.append(AccountLocalization.formatted("voice.summary.accountUpdated", value: name, locale: locale)) }
        if change.setsDefault { sentences.append(AccountLocalization.formatted("voice.summary.accountSetDefault", value: name, locale: locale)) }
        if change.deactivates { sentences.append(AccountLocalization.formatted("voice.summary.accountDeactivated", value: name, locale: locale)) }
        let actionKey = if change.deactivates {
            "voice.account.action.deactivate"
        } else if change.restores {
            "voice.account.action.restore"
        } else if change.profile == nil {
            "voice.account.action.setDefault"
        } else {
            "voice.change.updated"
        }
        let result = VoiceAccountChange(
            accountIDs: [id],
            actionText: text(actionKey),
            title: name,
            symbolName: symbolName(of: account),
            formattedAmount: nil,
            detail: nil,
            summary: sentences.joined(separator: text("voice.summary.separator")),
            inverse: .account(.restore(snapshot), defaultChange: defaultChange(since: defaultBefore))
        )
        return (.succeeded, result)
    }

    private func deleteAccount(_ input: VoiceDeleteAccountInput) -> (VoiceToolOutput, VoiceAccountChange?) {
        let context = container.makeManualSaveContext()
        guard let id = UUID(uuidString: input.accountId), let account = try? context.account(id: id) else {
            return (.failure(.notFound), nil)
        }
        let snapshot = AccountSnapshot(account: account)
        let defaultBefore = storedDefaultAccountID()
        do {
            // 不提交接替账户：要删的是默认账户时仓库会拒绝，服务端也保证不会这样调用
            let repository = accountRepository
            try repository.dispose(repository.disposalExpectation(for: id, action: .delete), now: now())
        } catch {
            return (.failure(Self.errorCode(for: error)), nil)
        }
        let name = displayName(of: account)
        let change = VoiceAccountChange(
            accountIDs: [],
            actionText: text("voice.change.deleted"),
            title: name,
            symbolName: symbolName(of: account),
            formattedAmount: nil,
            detail: nil,
            summary: AccountLocalization.formatted("voice.summary.accountDeleted", value: name, locale: locale),
            inverse: .account(.reinsert(snapshot), defaultChange: defaultChange(since: defaultBefore))
        )
        return (.succeeded, change)
    }

    /// 把账户余额调到目标值，并记一笔余额调整流水。
    ///
    /// - Parameters:
    ///   - id: 新流水的 UUID。
    ///   - accountID: 账户 UUID。
    ///   - target: 调整后的余额；信用卡、负债为欠款。
    ///   - transactionDay: 记账日；为空时取今天。
    ///   - note: 调整原因。
    /// - Returns: 调整后的余额；与当前余额相同时为 `invalid_input`。
    private func saveBalanceAdjustment(
        id: UUID,
        accountID: UUID,
        target: Decimal,
        transactionDay: Int?,
        note: String?
    ) -> Result<Decimal, VoiceToolErrorCode> {
        let draft = BalanceAdjustmentDraft(
            id: id, accountID: accountID, amountText: Self.amountString(target.magnitude),
            sign: target < 0 ? .negative : .positive, note: Self.writtenNote(note)
        )
        do {
            let repository = LocalBalanceAdjustmentRepository(container: container, beforeSave: beforeSave)
            switch try repository.save(draft, now: now(), calendar: calendar, transactionDay: transactionDay) {
            case let .saved(balance): return .success(balance)
            case .unchanged: return .failure(.invalidInput)
            }
        } catch {
            return .failure(Self.errorCode(for: error))
        }
    }

    /// 偏好中记录的默认记账账户，不论是否仍然有效。
    private func storedDefaultAccountID() -> UUID? {
        let context = container.makeManualSaveContext()
        return (try? context.canonicalBookkeepingPreference())?.defaultAccountID
    }

    /// 对比改动前后偏好中记录的默认记账账户；没有变化时为 `nil`，撤销时不碰默认账户。
    private func defaultChange(since before: UUID?) -> DefaultAccountChange? {
        let after = storedDefaultAccountID()
        return after == before ? nil : DefaultAccountChange(before: before, after: after)
    }

    /// 写入前把备注截到契约上限。服务端应已截断，这里再防一层。
    private static func writtenNote(_ note: String?) -> String {
        String((note ?? "").prefix(VoiceSessionLimits.maxWrittenNoteLength))
    }

    /// 账户在账户页显示的名称：银行卡、信用卡显示机构名称。
    private func displayName(of account: Account) -> String {
        guard account.accountType?.showsEditableName == false, let template = template(of: account) else {
            return account.name
        }
        return template.name(locale: locale)
    }

    /// 账户的图标：优先模板图标，其次类型图标。
    private func symbolName(of account: Account) -> String {
        template(of: account)?.symbolName ?? account.accountType?.symbolName ?? "questionmark.circle.fill"
    }

    /// 与账户类型匹配的当前模板；模板已不存在时为 `nil`。
    private func template(of account: Account) -> AccountTemplate? {
        account.accountType?.templates.first { $0.id == account.templateID }
    }

    /// 金额的称呼：余额、欠款或金额，随账户类型而定。
    private func amountLabel(of account: Account) -> String {
        account.accountType?.amountLabel(locale: locale) ?? text("account.amount.balance")
    }

    /// 记账日不是今天时的日期文字，例如「9月28日」；今年的只写月日，其他年份带上年份。
    private func dateText(_ transactionDay: Int) -> String? {
        let today = TransactionDay.encode(now(), calendar: calendar)
        guard transactionDay != today,
              let date = TransactionDay.date(from: transactionDay, calendar: calendar, locale: locale)
        else { return nil }
        let template = transactionDay / 10_000 == today / 10_000 ? "MMMd" : "yMMMd"
        return BookkeepingDateFormatting.formatter(template: template, locale: locale, calendar: calendar).string(from: date)
    }

    /// 待确认字段的说明，例如「待确认：账户类型、余额」；没有时为 `nil`。
    private func inferredText(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        let formatter = ListFormatter()
        formatter.locale = locale
        return AccountLocalization.formatted(
            "voice.change.inferred", value: formatter.string(from: names) ?? names.joined(separator: ", "), locale: locale
        )
    }

    /// 当前语言下的文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }

    /// 用「 · 」连接非空的说明；全部为空时为 `nil`。
    private static func detail(_ parts: [String?]) -> String? {
        let present = parts.compactMap { $0 }
        return present.isEmpty ? nil : present.joined(separator: " · ")
    }

    // MARK: - 查询

    private func search(_ input: VoiceSearchTransactionsInput) -> VoiceToolOutput {
        let context = container.makeManualSaveContext()
        guard let matches = matchingEntries(input.filter, in: context) else { return .failure(.invalidInput) }
        let activeAccountIDs = Self.activeAccountIDs(in: context)
        let items = matches.prefix(max(1, min(input.limit, 20))).map { entry in
            VoiceTransactionItem(
                id: entry.id.uuidString,
                date: Self.dateString(from: entry.transactionDay),
                type: VoiceEntryType(entry.entryType),
                amount: Self.amountString(entry.amount),
                categoryId: entry.categoryKey,
                accountId: entry.accountID.uuidString,
                // 备注常是商家或用途，提供给模型识别「打车那笔」
                note: entry.note.map { String($0.prefix(VoiceSessionLimits.maxResultNoteLength)) },
                isEditable: activeAccountIDs.contains(entry.accountID)
            )
        }
        return .searchResult(total: matches.count, items: Array(items))
    }

    private func summarize(_ input: VoiceSummarizeTransactionsInput) -> VoiceToolOutput {
        let context = container.makeManualSaveContext()
        guard let matches = matchingEntries(input.filter, in: context) else { return .failure(.invalidInput) }
        var expenseTotal = Decimal.zero
        var incomeTotal = Decimal.zero
        for entry in matches {
            switch entry.entryType {
            case .expense: expenseTotal += entry.amount
            case .income: incomeTotal += entry.amount
            }
        }
        return .summary(
            count: matches.count,
            expenseTotal: Self.amountString(expenseTotal),
            incomeTotal: Self.amountString(incomeTotal)
        )
    }

    /// 按条件筛选收支流水，按记账日倒序；条件格式不合法时返回 `nil`。
    private func matchingEntries(
        _ filter: VoiceTransactionFilter,
        in context: ModelContext
    ) -> [BookkeepingEntrySnapshot]? {
        let dayFrom = filter.dateFrom.map(Self.transactionDay(from:))
        let dayTo = filter.dateTo.map(Self.transactionDay(from:))
        let amountMin = filter.amountMin.map(Self.nonNegativeAmount(from:))
        let amountMax = filter.amountMax.map(Self.nonNegativeAmount(from:))
        // 外层 Optional 表示是否给了条件，内层为 nil 表示条件格式不合法
        if dayFrom == .some(nil) || dayTo == .some(nil) || amountMin == .some(nil) || amountMax == .some(nil) {
            return nil
        }
        let lowerDay = dayFrom.flatMap { $0 } ?? Int.min
        let upperDay = dayTo.flatMap { $0 } ?? Int.max
        let accountIDs = filter.accountIds.map { Set($0.compactMap(UUID.init(uuidString:))) }
        let categoryKeys = filter.categoryIds.map(Set.init)
        let entryType = filter.type.map { BookkeepingEntryType($0) }
        let keyword = filter.keyword?.trimmingCharacters(in: .whitespacesAndNewlines)

        var descriptor = FetchDescriptor<AccountTransaction>(
            predicate: #Predicate<AccountTransaction> { transaction in
                transaction.transactionDay >= lowerDay && transaction.transactionDay <= upperDay
            }
        )
        descriptor.sortBy = AccountTransactionOrdering.sortDescriptors
        guard let transactions = try? context.fetch(descriptor) else { return nil }
        let catalog = Self.catalog(in: context)

        return transactions.compactMap(BookkeepingEntrySnapshot.init(transaction:)).filter { entry in
            if let entryType, entry.entryType != entryType { return false }
            if let categoryKeys, !categoryKeys.contains(entry.categoryKey) { return false }
            if let accountIDs, !accountIDs.contains(entry.accountID) { return false }
            if let minimum = amountMin.flatMap({ $0 }), entry.amount < minimum { return false }
            if let maximum = amountMax.flatMap({ $0 }), entry.amount > maximum { return false }
            // 与页面搜索一致：关键词命中备注或分类名称都算，没写备注的流水也能按分类名找到
            if let keyword, !keyword.isEmpty {
                let categoryTitle = catalog.resolvedItem(direction: entry.entryType, key: entry.categoryKey).title(locale: locale)
                guard entry.note?.localizedCaseInsensitiveContains(keyword) == true
                    || categoryTitle.localizedCaseInsensitiveContains(keyword)
                else { return false }
            }
            return true
        }
    }

    // MARK: - 格式转换

    /// 当前分类目录。
    static func catalog(in context: ModelContext) -> BookkeepingCategoryCatalog {
        BookkeepingCategoryCatalog(categories: (try? context.fetch(FetchDescriptor<BookkeepingCategory>())) ?? [])
    }

    /// 启用中的账户 UUID。
    private static func activeAccountIDs(in context: ModelContext) -> Set<UUID> {
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        return Set(accounts.filter(\.isActive).map(\.id))
    }

    /// 把契约的 `YYYY-MM-DD` 转为 `YYYYMMDD` 记账日；不是真实日期时返回 `nil`。
    static func transactionDay(from date: String) -> Int? {
        let parts = date.split(separator: "-")
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        let value = year * 10_000 + month * 100 + day
        return TransactionDay.isValid(value) ? value : nil
    }

    /// 把 `YYYYMMDD` 记账日转为契约的 `YYYY-MM-DD`。
    static func dateString(from transactionDay: Int) -> String {
        String(
            format: "%04d-%02d-%02d",
            transactionDay / 10_000, transactionDay / 100 % 100, transactionDay % 100
        )
    }

    /// 契约中的金额一律使用英文句点，传给按语言环境解析金额的仓库时用它。
    private static let contractLocale = Locale(identifier: "en_US_POSIX")

    /// 解析带符号、最多两位小数的十进制金额字符串，用于目标余额与余额增减额；`-0` 归一为 0。
    static func signedAmount(from text: String) -> Decimal? {
        let isNegative = text.hasPrefix("-")
        guard let magnitude = nonNegativeAmount(from: isNegative ? String(text.dropFirst()) : text) else { return nil }
        return isNegative && magnitude != 0 ? -magnitude : magnitude
    }

    /// 解析大于零、最多两位小数的十进制金额字符串。
    static func amount(from text: String) -> Decimal? {
        guard let amount = nonNegativeAmount(from: text), amount > 0 else { return nil }
        return amount
    }

    /// 解析非负、最多两位小数的十进制金额字符串，用于查询条件。
    private static func nonNegativeAmount(from text: String) -> Decimal? {
        AccountAmountParser.cnyAmount(fromNormalized: text)
    }

    /// 把金额转为不带千分位、使用英文句点的十进制字符串。
    static func amountString(_ amount: Decimal) -> String {
        var value = amount
        return NSDecimalString(&value, Locale(identifier: "en_US_POSIX"))
    }

    /// 把写入失败映射为回传给模型的错误码。
    private static func errorCode(for error: Error) -> VoiceToolErrorCode {
        switch error {
        case let error as ExpenseRepositoryError:
            switch error {
            case .transactionNotFound: .notFound
            case .transactionNotEditable: .notEditable
            case .accountNotFound, .accountDeactivated, .categoryUnavailable, .unsupportedCurrency,
                 .unsupportedAccountType, .duplicateID:
                .invalidInput
            case .balanceCalculationFailed: .failed
            }
        case let error as BalanceAdjustmentRepositoryError:
            switch error {
            case .accountNotFound, .transactionNotFound: .notFound
            case .accountDeactivated: .notEditable
            case .unsupportedAccountType, .unsupportedCurrency, .unsupportedStoredBalancePrecision,
                 .invalidTargetBalance, .notBalanceAdjustment:
                .invalidInput
            case .duplicateID: .failed
            }
        case let error as TransferRepositoryError:
            switch error {
            case .accountNotFound, .transactionNotFound: .notFound
            case .accountDeactivated: .notEditable
            case .invalidDraft, .unsupportedAccountType, .unsupportedCurrency, .notTransfer: .invalidInput
            case .duplicateID: .failed
            }
        case let error as AccountRepositoryError:
            switch error {
            case .accountNotFound: .notFound
            case .accountDeactivated: .notEditable
            case .nonZeroBalance: .balanceNotZero
            case .accountHasTransactions: .hasTransactions
            case .invalidDefaultCandidate, .replacementRequired, .noDefaultConfirmationRequired,
                 .expectedStateChanged, .accountAlreadyActive:
                .invalidInput
            case .duplicateID: .failed
            }
        case is AccountTransactionValidationError, is AccountValidationError:
            .invalidInput
        default:
            .failed
        }
    }
}

/// 修改、删除前查找目标流水失败时，以错误码作为 `Result` 的失败值。
extension VoiceToolErrorCode: Error {}

extension BookkeepingEntryType {
    /// 由契约的收支类型转换。
    init(_ type: VoiceEntryType) {
        switch type {
        case .expense: self = .expense
        case .income: self = .income
        }
    }
}

extension VoiceEntryType {
    /// 由本地收支方向转换。
    init(_ type: BookkeepingEntryType) {
        switch type {
        case .expense: self = .expense
        case .income: self = .income
        }
    }
}
