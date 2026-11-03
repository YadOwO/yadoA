import Foundation
import SwiftData

/// 在本机执行语音记账会话的工具调用。
///
/// 收支的新增、修改、删除都经由 `LocalExpenseRepository.apply(_:)`，与手动记账使用同一套账户、分类、
/// 金额校验和余额联动；余额调整、转账、账户与周期记账的增删改分别经由对应的本地仓库，规则与手动操作一致。
/// 查询与汇总只读本地数据，不包含余额调整和转账。
struct VoiceToolExecutor {
    // 各类工具的实现按领域拆在 `VoiceToolExecutor+*.swift` 扩展里；跨文件共用的辅助方法因此不能是 `private`，
    // 但仍只供本类型及其扩展使用。

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
    /// - Returns: 回传结果与成功写入的改动。
    func execute(_ call: VoiceToolCall) -> VoiceToolExecution {
        let (output, changes): (VoiceToolOutput, [VoiceChange]) = switch call {
        case let .searchTransactions(_, input): (search(input), [])
        case let .summarizeTransactions(_, input): (summarize(input), [])
        case let .createTransaction(_, input): Self.entry(create(input))
        case let .updateTransaction(_, input): Self.entry(update(input))
        case let .deleteTransaction(_, input): Self.entry(delete(input))
        case let .adjustBalance(_, input): Self.account(adjustBalance(input))
        case let .transfer(_, input): Self.account(transfer(input))
        case let .createAccount(_, input): Self.account(createAccount(input))
        case let .updateAccount(_, input): Self.account(updateAccount(input))
        case let .deleteAccount(_, input): Self.account(deleteAccount(input))
        case let .searchRecurringRules(_, input): (searchRecurringRules(input), [])
        case let .createRecurringRule(_, input): createRecurringRule(input)
        case let .updateRecurringRule(_, input): updateRecurringRule(input)
        case let .deleteRecurringRule(_, input): Self.recurring(deleteRecurringRule(input))
        }
        var insight: AIChatInsight?
        if case let .summarizeTransactions(_, input) = call, output.isSuccess {
            insight = queryInsight(for: input.filter)
        }
        return VoiceToolExecution(
            result: VoiceToolResult(toolCallId: call.id, name: call.name, output: output),
            changes: changes,
            insight: insight
        )
    }

    /// 撤销一轮中的全部改动：按相反顺序在一次保存中执行反向操作，失败时没有任何改动生效。
    ///
    /// 收支、账户与周期记账的改动可能交错（例如先新建账户再往里记账，或新建周期记账后当场记入一期），
    /// 必须在同一个 context 里倒序撤销。
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
                case let .recurring(recurring):
                    try LocalRecurringRuleRepository.revert(recurring.inverse, in: context)
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
    static func entry(_ result: (VoiceToolOutput, VoiceEntryChange?)) -> (VoiceToolOutput, [VoiceChange]) {
        (result.0, result.1.map { [.entry($0)] } ?? [])
    }

    /// 把账户相关的执行结果包装为通用改动。
    static func account(_ result: (VoiceToolOutput, VoiceAccountChange?)) -> (VoiceToolOutput, [VoiceChange]) {
        (result.0, result.1.map { [.account($0)] } ?? [])
    }

    /// 把不带当场记入流水的周期记账执行结果（删除）包装为通用改动。
    static func recurring(_ result: (VoiceToolOutput, VoiceRecurringChange?)) -> (VoiceToolOutput, [VoiceChange]) {
        (result.0, result.1.map { [.recurring($0)] } ?? [])
    }

    // MARK: - 格式转换

    /// 当前分类目录。
    static func catalog(in context: ModelContext) -> BookkeepingCategoryCatalog {
        BookkeepingCategoryCatalog(categories: (try? context.fetch(FetchDescriptor<BookkeepingCategory>())) ?? [])
    }

    /// 启用中的账户 UUID。
    static func activeAccountIDs(in context: ModelContext) -> Set<UUID> {
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
    static let contractLocale = Locale(identifier: "en_US_POSIX")

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
    static func nonNegativeAmount(from text: String) -> Decimal? {
        AccountAmountParser.cnyAmount(fromNormalized: text)
    }

    /// 把金额转为不带千分位、使用英文句点的十进制字符串。
    static func amountString(_ amount: Decimal) -> String {
        var value = amount
        return NSDecimalString(&value, Locale(identifier: "en_US_POSIX"))
    }

    /// 把写入失败映射为回传给模型的错误码。
    static func errorCode(for error: Error) -> VoiceToolErrorCode {
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
        case let error as RecurringRuleRepositoryError:
            switch error {
            case .ruleNotFound: .notFound
            case .invalidInput: .invalidInput
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

extension RecurringFrequency {
    /// 由契约的重复频率转换。
    init(_ frequency: VoiceRecurringFrequency) {
        switch frequency {
        case .daily: self = .daily
        case .weekly: self = .weekly
        case .biweekly: self = .biweekly
        case .monthly: self = .monthly
        case .quarterly: self = .quarterly
        case .yearly: self = .yearly
        }
    }
}

extension VoiceRecurringFrequency {
    /// 由本地重复频率转换。
    init(_ frequency: RecurringFrequency) {
        switch frequency {
        case .daily: self = .daily
        case .weekly: self = .weekly
        case .biweekly: self = .biweekly
        case .monthly: self = .monthly
        case .quarterly: self = .quarterly
        case .yearly: self = .yearly
        }
    }
}

extension VoiceRecurringRuleStatus {
    /// 由周期记账列表的状态转换。
    init(_ status: RecurringRuleStatus) {
        switch status {
        case .active: self = .active
        case .paused: self = .paused
        case .finished: self = .finished
        case .unavailable: self = .unavailable
        }
    }
}
