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
    /// 登记一条语音记账产生的首页提示。
    ///
    /// - Parameter highlight: 变更对应的提示。
    func mark(_ highlight: VoiceEntryHighlight) {
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

/// 一次工具执行的结果。
struct VoiceToolExecution: Equatable {
    /// 回传给服务端的执行结果。
    let result: VoiceToolResult

    /// 成功写入时的流水变更；查询、汇总和失败时为 `nil`。
    let change: VoiceEntryChange?
}

/// 在本机执行语音记账会话的工具调用。
///
/// 新增、修改、删除都经由 `LocalExpenseRepository.apply(_:)`，与手动记账使用同一套账户、分类、
/// 金额校验和余额联动；查询与汇总只读本地数据，不包含余额调整。
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
        let (output, change): (VoiceToolOutput, VoiceEntryChange?) = switch call {
        case let .searchTransactions(_, input): (search(input), nil)
        case let .summarizeTransactions(_, input): (summarize(input), nil)
        case let .createTransaction(_, input): create(input)
        case let .updateTransaction(_, input): update(input)
        case let .deleteTransaction(_, input): delete(input)
        }
        return VoiceToolExecution(
            result: VoiceToolResult(toolCallId: call.id, name: call.name, output: output),
            change: change
        )
    }

    /// 撤销一轮中的全部变更：按相反顺序在一次保存中执行反向操作，失败时没有任何变更生效。
    ///
    /// - Parameter changes: 这一轮按执行顺序记录的变更。
    /// - Returns: 撤销后首页要播放的提示。
    /// - Throws: 反向操作不符合约束（例如期间账户被停用）或保存失败时抛出错误。
    func revert(_ changes: [VoiceEntryChange]) throws -> [VoiceEntryHighlight] {
        let context = container.makeManualSaveContext()
        let catalog = Self.catalog(in: context)
        // 撤销前拷贝首页行快照：撤销新增的要画删除残影，撤销修改的要展示从什么改回什么
        let highlights = changes.reversed().compactMap { change -> VoiceEntryHighlight? in
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
        try repository.apply(changes.reversed().map(\.inverse))
        return highlights
    }

    // MARK: - 写入

    private var repository: LocalExpenseRepository {
        LocalExpenseRepository(container: container, beforeSave: beforeSave)
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
        // 手动编辑会把分类名写成标题；换了分类时若标题仍是旧分类名，清空标题，让展示跟随新分类
        if updated.categoryKey != previous.categoryKey || updated.entryType != previous.entryType,
           let title = previous.title,
           title == target.catalog.resolvedItem(direction: previous.entryType, key: previous.categoryKey).title(locale: locale) {
            updated.title = nil
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
            row: row,
            accountName: (try? context.account(id: snapshot.accountID))?.name,
            label: label(for: snapshot, catalog: catalog),
            formattedAmount: formattedAmount(snapshot.amount),
            inferredFields: inferredFields,
            inverse: inverse,
            highlight: highlight
        )
    }

    /// 结果提示里称呼一笔流水的文字：优先备注，其次标题，最后分类名称。
    private func label(for snapshot: BookkeepingEntrySnapshot, catalog: BookkeepingCategoryCatalog) -> String {
        snapshot.note
            ?? snapshot.title
            ?? catalog.resolvedItem(direction: snapshot.entryType, key: snapshot.categoryKey).title(locale: locale)
    }

    /// 不带正负号的本地化 CNY 金额。
    private func formattedAmount(_ amount: Decimal) -> String {
        amount.formatted(.currency(code: "CNY").locale(locale))
    }

    // MARK: - 查询

    private func search(_ input: VoiceSearchTransactionsInput) -> VoiceToolOutput {
        let context = container.makeManualSaveContext()
        guard let matches = matchingEntries(input.filter, in: context) else { return .failure(.invalidInput) }
        let activeAccountIDs = Self.activeAccountIDs(in: context)
        let items = matches.prefix(max(1, min(input.limit, 20))).map { entry in
            let combinedNote = [entry.title, entry.note].compactMap { $0 }.joined(separator: " · ")
            return VoiceTransactionItem(
                id: entry.id.uuidString,
                date: Self.dateString(from: entry.transactionDay),
                type: VoiceEntryType(entry.entryType),
                amount: Self.amountString(entry.amount),
                categoryId: entry.categoryKey,
                accountId: entry.accountID.uuidString,
                // 标题常是商家或用途，和备注一起提供给模型识别「打车那笔」
                note: combinedNote.isEmpty ? nil : String(combinedNote.prefix(VoiceSessionLimits.maxResultNoteLength)),
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

        return transactions.compactMap(BookkeepingEntrySnapshot.init(transaction:)).filter { entry in
            if let entryType, entry.entryType != entryType { return false }
            if let categoryKeys, !categoryKeys.contains(entry.categoryKey) { return false }
            if let accountIDs, !accountIDs.contains(entry.accountID) { return false }
            if let minimum = amountMin.flatMap({ $0 }), entry.amount < minimum { return false }
            if let maximum = amountMax.flatMap({ $0 }), entry.amount > maximum { return false }
            if let keyword, !keyword.isEmpty {
                let text = [entry.title, entry.note].compactMap { $0 }.joined(separator: " ")
                if !text.localizedCaseInsensitiveContains(keyword) { return false }
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
        case is AccountTransactionValidationError:
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
