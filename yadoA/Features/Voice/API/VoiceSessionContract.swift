import Foundation

// 与 yado_ai `POST /v1/yadoa/voice-session/turn` 对应的数据契约，结构以服务端 openapi.json 为准。
//
// 服务端不保存会话：App 每次请求都带上全部事件，服务端返回的工具调用要原样放回事件再发送，
// 因此这里手写编解码，保证必填的可空字段编码为 null、修改备注能区分「不改」与「清空」。

// MARK: - 基础字段

/// 契约中的收支类型；持久化值 `diningExpense` 对外统一为 `expense`。
nonisolated enum VoiceEntryType: String, Codable, Equatable, Sendable {
    /// 支出。
    case expense

    /// 收入。
    case income
}

/// 新增时由 AI 推断或取了默认值的字段，界面上标「待确认」。
nonisolated enum VoiceInferredField: String, Codable, Equatable, Sendable {
    /// 金额拿不准（例如语音转写可能有误）。
    case amount

    /// 没提到账户，按默认记账账户或唯一启用账户处理。
    case account

    /// 判断不出收支类型，按支出处理。
    case type

    /// 没有合适的分类，归入「其他」。
    case category
}

/// 服务端下发的工具名称。
nonisolated enum VoiceToolName: String, Codable, Equatable, Sendable {
    /// 按条件查询流水。
    case searchTransactions = "search_transactions"

    /// 按条件汇总笔数与总额。
    case summarizeTransactions = "summarize_transactions"

    /// 新增一笔流水。
    case createTransaction = "create_transaction"

    /// 修改一笔流水。
    case updateTransaction = "update_transaction"

    /// 删除一笔流水。
    case deleteTransaction = "delete_transaction"

    /// 调整账户余额。
    case adjustBalance = "adjust_balance"

    /// 账户之间转账；只有一边账户时为单边余额调整。
    case transfer

    /// 新建账户。
    case createAccount = "create_account"

    /// 修改账户资料、设为默认、停用或恢复。
    case updateAccount = "update_account"

    /// 删除账户。
    case deleteAccount = "delete_account"
}

/// 新建账户时由 AI 推断或取了默认值的字段，界面上标「待确认」。
nonisolated enum VoiceAccountInferredField: String, Codable, Equatable, Sendable {
    /// 判断不出类型，按自定义资产处理。
    case type

    /// 没说余额，按 0 处理。
    case balance
}

// MARK: - 工具入参（服务端 → App）

/// 流水查询条件；所有条件取交集，`nil` 表示不限制。只覆盖收支，不含余额调整。
nonisolated struct VoiceTransactionFilter: Codable, Equatable, Sendable {
    /// 起始记账日 `YYYY-MM-DD`（含）。
    var dateFrom: String?

    /// 结束记账日 `YYYY-MM-DD`（含）。
    var dateTo: String?

    /// 收支类型。
    var type: VoiceEntryType?

    /// 分类 key 列表。
    var categoryIds: [String]?

    /// 账户 UUID 字符串列表。
    var accountIds: [String]?

    /// 金额下限（含），十进制字符串。
    var amountMin: String?

    /// 金额上限（含），十进制字符串。
    var amountMax: String?

    /// 标题或备注中包含的关键词。
    var keyword: String?

    /// 成员逐一初始化，全部默认不限制。
    init(
        dateFrom: String? = nil,
        dateTo: String? = nil,
        type: VoiceEntryType? = nil,
        categoryIds: [String]? = nil,
        accountIds: [String]? = nil,
        amountMin: String? = nil,
        amountMax: String? = nil,
        keyword: String? = nil
    ) {
        self.dateFrom = dateFrom
        self.dateTo = dateTo
        self.type = type
        self.categoryIds = categoryIds
        self.accountIds = accountIds
        self.amountMin = amountMin
        self.amountMax = amountMax
        self.keyword = keyword
    }
}

/// `search_transactions` 的入参。
nonisolated struct VoiceSearchTransactionsInput: Codable, Equatable, Sendable {
    /// 查询条件。
    var filter: VoiceTransactionFilter

    /// 最多返回的笔数，1～20。
    var limit: Int
}

/// `summarize_transactions` 的入参。
nonisolated struct VoiceSummarizeTransactionsInput: Codable, Equatable, Sendable {
    /// 汇总条件。
    var filter: VoiceTransactionFilter
}

/// `create_transaction` 的入参；服务端已补齐默认值并核对账户、分类。
nonisolated struct VoiceCreateTransactionInput: Codable, Equatable, Sendable {
    /// 收支类型。
    var type: VoiceEntryType

    /// 大于零的十进制金额字符串。
    var amount: String

    /// 启用中的账户 UUID 字符串。
    var accountId: String

    /// 与 `type` 匹配的分类 key。
    var categoryId: String

    /// 记账日 `YYYY-MM-DD`。
    var date: String

    /// 备注，最多 30 字；没有时为 `nil`，编码为 `null`。
    var note: String?

    /// 由 AI 推断或取了默认值的字段。
    var inferredFields: [VoiceInferredField]

    private enum CodingKeys: String, CodingKey {
        case type, amount, accountId, categoryId, date, note, inferredFields
    }

    /// 成员逐一初始化。
    init(
        type: VoiceEntryType,
        amount: String,
        accountId: String,
        categoryId: String,
        date: String,
        note: String?,
        inferredFields: [VoiceInferredField]
    ) {
        self.type = type
        self.amount = amount
        self.accountId = accountId
        self.categoryId = categoryId
        self.date = date
        self.note = note
        self.inferredFields = inferredFields
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(VoiceEntryType.self, forKey: .type)
        amount = try container.decode(String.self, forKey: .amount)
        accountId = try container.decode(String.self, forKey: .accountId)
        categoryId = try container.decode(String.self, forKey: .categoryId)
        date = try container.decode(String.self, forKey: .date)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        inferredFields = try container.decodeIfPresent([VoiceInferredField].self, forKey: .inferredFields) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(amount, forKey: .amount)
        try container.encode(accountId, forKey: .accountId)
        try container.encode(categoryId, forKey: .categoryId)
        try container.encode(date, forKey: .date)
        // 契约要求 note 字段必须出现，没有备注时为 null
        try container.encode(note, forKey: .note)
        try container.encode(inferredFields, forKey: .inferredFields)
    }
}

/// 可清空的文本字段（备注、卡号后四位）的修改方式：`patch` 中不出现表示不改，`null` 表示清空。
nonisolated enum VoiceTextPatch: Equatable, Sendable {
    /// 改为新值。
    case set(String)

    /// 清空。
    case clear

    /// 从 `patch` 中解码一个可清空的字段。
    ///
    /// - Parameters:
    ///   - container: `patch` 的解码容器。
    ///   - key: 字段名。
    /// - Returns: 字段不出现时为 `nil`，为 `null` 时为清空。
    static func decode<Key: CodingKey>(from container: KeyedDecodingContainer<Key>, forKey key: Key) throws -> VoiceTextPatch? {
        guard container.contains(key) else { return nil }
        return try container.decodeNil(forKey: key) ? .clear : .set(container.decode(String.self, forKey: key))
    }

    /// 把一个可清空的字段编码进 `patch`。
    ///
    /// - Parameters:
    ///   - patch: 修改方式；为 `nil` 时不写这个字段。
    ///   - container: `patch` 的编码容器。
    ///   - key: 字段名。
    static func encode<Key: CodingKey>(
        _ patch: VoiceTextPatch?,
        to container: inout KeyedEncodingContainer<Key>,
        forKey key: Key
    ) throws {
        switch patch {
        case let .set(value): try container.encode(value, forKey: key)
        case .clear: try container.encodeNil(forKey: key)
        case nil: break
        }
    }
}

/// `update_transaction` 中要修改的字段；`nil` 表示不改。
nonisolated struct VoiceTransactionPatch: Codable, Equatable, Sendable {
    /// 新的收支类型；修改时服务端保证同时给出匹配的分类。
    var type: VoiceEntryType?

    /// 新金额。
    var amount: String?

    /// 新账户 UUID 字符串。
    var accountId: String?

    /// 新分类 key。
    var categoryId: String?

    /// 新记账日 `YYYY-MM-DD`。
    var date: String?

    /// 备注的修改方式。
    var note: VoiceTextPatch?

    private enum CodingKeys: String, CodingKey {
        case type, amount, accountId, categoryId, date, note
    }

    /// 成员逐一初始化，全部默认不改。
    init(
        type: VoiceEntryType? = nil,
        amount: String? = nil,
        accountId: String? = nil,
        categoryId: String? = nil,
        date: String? = nil,
        note: VoiceTextPatch? = nil
    ) {
        self.type = type
        self.amount = amount
        self.accountId = accountId
        self.categoryId = categoryId
        self.date = date
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(VoiceEntryType.self, forKey: .type)
        amount = try container.decodeIfPresent(String.self, forKey: .amount)
        accountId = try container.decodeIfPresent(String.self, forKey: .accountId)
        categoryId = try container.decodeIfPresent(String.self, forKey: .categoryId)
        date = try container.decodeIfPresent(String.self, forKey: .date)
        note = try VoiceTextPatch.decode(from: container, forKey: .note)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(amount, forKey: .amount)
        try container.encodeIfPresent(accountId, forKey: .accountId)
        try container.encodeIfPresent(categoryId, forKey: .categoryId)
        try container.encodeIfPresent(date, forKey: .date)
        try VoiceTextPatch.encode(note, to: &container, forKey: .note)
    }
}

/// `update_transaction` 的入参。
nonisolated struct VoiceUpdateTransactionInput: Codable, Equatable, Sendable {
    /// 要修改的流水 UUID 字符串。
    var id: String

    /// 要修改的字段。
    var patch: VoiceTransactionPatch
}

/// `delete_transaction` 的入参。
nonisolated struct VoiceDeleteTransactionInput: Codable, Equatable, Sendable {
    /// 要删除的流水 UUID 字符串。
    var id: String
}

/// `adjust_balance` 的入参：把余额调到目标值，或按差额增减；`targetBalance` 与 `delta` 恰好一个不为 `nil`。
nonisolated struct VoiceAdjustBalanceInput: Codable, Equatable, Sendable {
    /// 启用中的账户 UUID 字符串。
    var accountId: String

    /// 调整后的余额，带符号的十进制字符串；信用卡、负债为欠款。
    var targetBalance: String?

    /// 余额增减额，不为 0；执行时加到当时的余额上。信用卡、负债为欠款的增减。
    var delta: String?

    /// 调整原因，最多 30 字。
    var note: String?

    private enum CodingKeys: String, CodingKey {
        case accountId, targetBalance, delta, note
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accountId, forKey: .accountId)
        // 契约要求可空字段必须出现，没有值时为 null
        try container.encode(targetBalance, forKey: .targetBalance)
        try container.encode(delta, forKey: .delta)
        try container.encode(note, forKey: .note)
    }
}

/// `transfer` 的入参。
///
/// 两边账户都有时记一笔转账；只有一边时，只给这个账户记一笔余额调整，增减方向与转账一致
/// （例如只转入信用卡时欠款减少）。
nonisolated struct VoiceTransferInput: Codable, Equatable, Sendable {
    /// 转出账户 UUID 字符串；用户选择不选账户时为 `nil`。
    var fromAccountId: String?

    /// 转入账户 UUID 字符串；用户选择不选账户时为 `nil`。
    var toAccountId: String?

    /// 大于零的十进制金额字符串。
    var amount: String

    /// 记账日 `YYYY-MM-DD`。
    var date: String

    /// 备注，最多 30 字。
    var note: String?

    /// 金额由 AI 推断，界面上标「待确认」。
    var isAmountUncertain: Bool

    private enum CodingKeys: String, CodingKey {
        case fromAccountId, toAccountId, amount, date, note, isAmountUncertain
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fromAccountId, forKey: .fromAccountId)
        try container.encode(toAccountId, forKey: .toAccountId)
        try container.encode(amount, forKey: .amount)
        try container.encode(date, forKey: .date)
        try container.encode(note, forKey: .note)
        try container.encode(isAmountUncertain, forKey: .isAmountUncertain)
    }
}

/// `create_account` 的入参；服务端已补齐默认值。
nonisolated struct VoiceCreateAccountInput: Codable, Equatable, Sendable {
    /// 账户类型，即 `AccountType.rawValue`；不认识时按参数不合法处理。
    var type: String

    /// 账户模板 id，例如 `debitCard.cmb`；储蓄卡、信用卡、虚拟账户、投资账户必有，其余类型为 `nil`。
    var templateId: String?

    /// 账户名称，最多 50 字；为 `nil` 时使用模板名称或类型名称。
    var name: String?

    /// 期初余额，非负十进制字符串；信用卡、负债为欠款金额。
    var balance: String

    /// 卡号后四位；只有储蓄卡、信用卡会有。
    var lastFourDigits: String?

    /// 备注，最多 30 字。
    var note: String?

    /// 由 AI 推断或取了默认值的字段。
    var inferredFields: [VoiceAccountInferredField]

    private enum CodingKeys: String, CodingKey {
        case type, templateId, name, balance, lastFourDigits, note, inferredFields
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(templateId, forKey: .templateId)
        try container.encode(name, forKey: .name)
        try container.encode(balance, forKey: .balance)
        try container.encode(lastFourDigits, forKey: .lastFourDigits)
        try container.encode(note, forKey: .note)
        try container.encode(inferredFields, forKey: .inferredFields)
    }
}

/// `update_account` 中要修改的字段；`nil` 表示不改。
///
/// App 按「恢复 → 改资料 → 设为默认 → 停用」的顺序执行。服务端保证：不会停用默认记账账户，不会同时停用并设为默认，
/// 已停用的账户只有同时恢复时才会改其他字段；恢复时若没有有效的默认账户且该账户可以当默认，会同时设为默认。
nonisolated struct VoiceAccountPatch: Codable, Equatable, Sendable {
    /// 新名称，最多 50 字。
    var name: String?

    /// 备注的修改方式。
    var note: VoiceTextPatch?

    /// 卡号后四位的修改方式。
    var lastFourDigits: VoiceTextPatch?

    /// 是否设为默认记账账户；契约中只会出现 `true`，`false` 表示不改。
    var setsDefault: Bool

    /// `false` 停用，`true` 恢复。
    var isActive: Bool?

    private enum CodingKeys: String, CodingKey {
        case name, note, lastFourDigits
        case setsDefault = "isDefault"
        case isActive
    }

    /// 成员逐一初始化，全部默认不改。
    init(
        name: String? = nil,
        note: VoiceTextPatch? = nil,
        lastFourDigits: VoiceTextPatch? = nil,
        setsDefault: Bool = false,
        isActive: Bool? = nil
    ) {
        self.name = name
        self.note = note
        self.lastFourDigits = lastFourDigits
        self.setsDefault = setsDefault
        self.isActive = isActive
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        note = try VoiceTextPatch.decode(from: container, forKey: .note)
        lastFourDigits = try VoiceTextPatch.decode(from: container, forKey: .lastFourDigits)
        setsDefault = try container.decodeIfPresent(Bool.self, forKey: .setsDefault) ?? false
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try VoiceTextPatch.encode(note, to: &container, forKey: .note)
        try VoiceTextPatch.encode(lastFourDigits, to: &container, forKey: .lastFourDigits)
        // 契约只接受 true，不设为默认时不写这个字段
        if setsDefault {
            try container.encode(true, forKey: .setsDefault)
        }
        try container.encodeIfPresent(isActive, forKey: .isActive)
    }
}

/// `update_account` 的入参。
nonisolated struct VoiceUpdateAccountInput: Codable, Equatable, Sendable {
    /// 要修改的账户 UUID 字符串。
    var accountId: String

    /// 要修改的字段。
    var patch: VoiceAccountPatch
}

/// `delete_account` 的入参；服务端保证不是默认记账账户、不是已停用账户。
nonisolated struct VoiceDeleteAccountInput: Codable, Equatable, Sendable {
    /// 要删除的账户 UUID 字符串。
    var accountId: String
}

/// 服务端下发的一次工具调用；App 执行后要把它原样放回事件中回传。
nonisolated enum VoiceToolCall: Codable, Equatable, Sendable {
    /// 查询流水。
    case searchTransactions(id: String, input: VoiceSearchTransactionsInput)

    /// 汇总流水。
    case summarizeTransactions(id: String, input: VoiceSummarizeTransactionsInput)

    /// 新增流水。
    case createTransaction(id: String, input: VoiceCreateTransactionInput)

    /// 修改流水。
    case updateTransaction(id: String, input: VoiceUpdateTransactionInput)

    /// 删除流水。
    case deleteTransaction(id: String, input: VoiceDeleteTransactionInput)

    /// 调整账户余额。
    case adjustBalance(id: String, input: VoiceAdjustBalanceInput)

    /// 转账；只有一边账户时为单边余额调整。
    case transfer(id: String, input: VoiceTransferInput)

    /// 新建账户。
    case createAccount(id: String, input: VoiceCreateAccountInput)

    /// 修改账户。
    case updateAccount(id: String, input: VoiceUpdateAccountInput)

    /// 删除账户。
    case deleteAccount(id: String, input: VoiceDeleteAccountInput)

    /// 调用 id，在整个会话内唯一。
    var id: String {
        switch self {
        case let .searchTransactions(id, _), let .summarizeTransactions(id, _),
             let .createTransaction(id, _), let .updateTransaction(id, _), let .deleteTransaction(id, _),
             let .adjustBalance(id, _), let .transfer(id, _),
             let .createAccount(id, _), let .updateAccount(id, _), let .deleteAccount(id, _):
            id
        }
    }

    /// 工具名称。
    var name: VoiceToolName {
        switch self {
        case .searchTransactions: .searchTransactions
        case .summarizeTransactions: .summarizeTransactions
        case .createTransaction: .createTransaction
        case .updateTransaction: .updateTransaction
        case .deleteTransaction: .deleteTransaction
        case .adjustBalance: .adjustBalance
        case .transfer: .transfer
        case .createAccount: .createAccount
        case .updateAccount: .updateAccount
        case .deleteAccount: .deleteAccount
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, input
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        switch try container.decode(VoiceToolName.self, forKey: .name) {
        case .searchTransactions:
            self = try .searchTransactions(id: id, input: container.decode(VoiceSearchTransactionsInput.self, forKey: .input))
        case .summarizeTransactions:
            self = try .summarizeTransactions(id: id, input: container.decode(VoiceSummarizeTransactionsInput.self, forKey: .input))
        case .createTransaction:
            self = try .createTransaction(id: id, input: container.decode(VoiceCreateTransactionInput.self, forKey: .input))
        case .updateTransaction:
            self = try .updateTransaction(id: id, input: container.decode(VoiceUpdateTransactionInput.self, forKey: .input))
        case .deleteTransaction:
            self = try .deleteTransaction(id: id, input: container.decode(VoiceDeleteTransactionInput.self, forKey: .input))
        case .adjustBalance:
            self = try .adjustBalance(id: id, input: container.decode(VoiceAdjustBalanceInput.self, forKey: .input))
        case .transfer:
            self = try .transfer(id: id, input: container.decode(VoiceTransferInput.self, forKey: .input))
        case .createAccount:
            self = try .createAccount(id: id, input: container.decode(VoiceCreateAccountInput.self, forKey: .input))
        case .updateAccount:
            self = try .updateAccount(id: id, input: container.decode(VoiceUpdateAccountInput.self, forKey: .input))
        case .deleteAccount:
            self = try .deleteAccount(id: id, input: container.decode(VoiceDeleteAccountInput.self, forKey: .input))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        switch self {
        case let .searchTransactions(_, input): try container.encode(input, forKey: .input)
        case let .summarizeTransactions(_, input): try container.encode(input, forKey: .input)
        case let .createTransaction(_, input): try container.encode(input, forKey: .input)
        case let .updateTransaction(_, input): try container.encode(input, forKey: .input)
        case let .deleteTransaction(_, input): try container.encode(input, forKey: .input)
        case let .adjustBalance(_, input): try container.encode(input, forKey: .input)
        case let .transfer(_, input): try container.encode(input, forKey: .input)
        case let .createAccount(_, input): try container.encode(input, forKey: .input)
        case let .updateAccount(_, input): try container.encode(input, forKey: .input)
        case let .deleteAccount(_, input): try container.encode(input, forKey: .input)
        }
    }
}

// MARK: - 工具执行结果（App → 服务端）

/// 工具执行失败的原因。
nonisolated enum VoiceToolErrorCode: String, Codable, Equatable, Sendable {
    /// 流水或账户不存在。
    case notFound = "not_found"

    /// 余额调整，或已停用账户下的流水，不能修改、删除；或要操作的账户已停用。
    case notEditable = "not_editable"

    /// 参数不合法，例如账户已停用、分类已删除、日期无效、调整后余额与当前相同。
    case invalidInput = "invalid_input"

    /// 停用账户时余额不为 0。
    case balanceNotZero = "balance_not_zero"

    /// 删除账户时账户还有流水。
    case hasTransactions = "has_transactions"

    /// 其他本地错误，例如保存失败。
    case failed
}

/// 查询结果中的一笔流水。
nonisolated struct VoiceTransactionItem: Encodable, Equatable, Sendable {
    /// 流水 UUID 字符串。
    var id: String

    /// 记账日 `YYYY-MM-DD`。
    var date: String

    /// 收支类型。
    var type: VoiceEntryType

    /// 金额，十进制字符串。
    var amount: String

    /// 分类 key。
    var categoryId: String

    /// 账户 UUID 字符串。
    var accountId: String

    /// 标题与备注，最多 200 字；没有时编码为 `null`。
    var note: String?

    /// 是否可以修改、删除；已停用账户下的流水为 `false`。
    var isEditable: Bool

    private enum CodingKeys: String, CodingKey {
        case id, date, type, amount, categoryId, accountId, note, isEditable
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(date, forKey: .date)
        try container.encode(type, forKey: .type)
        try container.encode(amount, forKey: .amount)
        try container.encode(categoryId, forKey: .categoryId)
        try container.encode(accountId, forKey: .accountId)
        try container.encode(note, forKey: .note)
        try container.encode(isEditable, forKey: .isEditable)
    }
}

/// 一次工具执行的输出。
nonisolated enum VoiceToolOutput: Encodable, Equatable, Sendable {
    /// 执行失败。
    case failure(VoiceToolErrorCode)

    /// 查询成功：符合条件的总笔数与按记账日倒序的前若干笔。
    case searchResult(total: Int, items: [VoiceTransactionItem])

    /// 汇总成功。
    case summary(count: Int, expenseTotal: String, incomeTotal: String)

    /// 新增成功，携带新流水、新转账流水或新账户的 UUID 字符串。
    case created(id: String)

    /// 余额调整成功，携带调整前后的余额（带符号的十进制字符串）。
    case balanceAdjusted(before: String, after: String)

    /// 修改或删除成功。
    case succeeded

    /// 是否执行成功。
    var isSuccess: Bool {
        if case .failure = self { return false }
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case ok, code, total, items, count, expenseTotal, incomeTotal, id, balanceBefore, balanceAfter
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isSuccess, forKey: .ok)
        switch self {
        case let .failure(code):
            try container.encode(code, forKey: .code)
        case let .searchResult(total, items):
            try container.encode(total, forKey: .total)
            try container.encode(items, forKey: .items)
        case let .summary(count, expenseTotal, incomeTotal):
            try container.encode(count, forKey: .count)
            try container.encode(expenseTotal, forKey: .expenseTotal)
            try container.encode(incomeTotal, forKey: .incomeTotal)
        case let .created(id):
            try container.encode(id, forKey: .id)
        case let .balanceAdjusted(before, after):
            try container.encode(before, forKey: .balanceBefore)
            try container.encode(after, forKey: .balanceAfter)
        case .succeeded:
            break
        }
    }
}

/// 一次工具执行结果，`name` 必须与对应调用一致。
nonisolated struct VoiceToolResult: Encodable, Equatable, Sendable {
    /// 对应的调用 id。
    var toolCallId: String

    /// 对应的工具名称。
    var name: VoiceToolName

    /// 执行输出。
    var output: VoiceToolOutput
}

// MARK: - 会话事件、请求与响应

/// 会话中的一条事件，按发生顺序排列；每个工具调用后面紧跟它的执行结果。
nonisolated enum VoiceSessionEvent: Encodable, Equatable, Sendable {
    /// 用户说的话；点选候选项时为该项的 label，并带上候选项 id。
    case user(text: String, selectedOptionId: String?)

    /// 之前轮次的回复、追问或 App 本地生成的结果提示。
    case assistant(text: String)

    /// 服务端下发、App 已执行的工具调用。
    case toolCall(VoiceToolCall)

    /// 工具执行结果。
    case toolResult(VoiceToolResult)

    private enum CodingKeys: String, CodingKey {
        case kind, text, selectedOptionId, toolCall, toolResult
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .user(text, selectedOptionId):
            try container.encode("user", forKey: .kind)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(selectedOptionId, forKey: .selectedOptionId)
        case let .assistant(text):
            try container.encode("assistant", forKey: .kind)
            try container.encode(text, forKey: .text)
        case let .toolCall(call):
            try container.encode("tool_call", forKey: .kind)
            try container.encode(call, forKey: .toolCall)
        case let .toolResult(result):
            try container.encode("tool_result", forKey: .kind)
            try container.encode(result, forKey: .toolResult)
        }
    }
}

/// 上下文中的一个账户。
nonisolated struct VoiceAccountOption: Encodable, Equatable, Sendable {
    /// 账户 UUID 字符串。
    var id: String

    /// 账户名称，最多 50 字。
    var name: String

    /// 是否可以新增或改入流水。
    var isActive: Bool

    /// 账户类型，即 `AccountType.rawValue`，最多 32 字；服务端不认识的类型按资产处理。
    var type: String

    /// 当前余额，带符号、最多两位小数的十进制字符串；信用卡、负债为欠款金额。
    ///
    /// 服务端据此回答余额、总资产等问题，每一步都要按本地最新余额发送。
    var balance: String
}

/// 上下文中的一个分类；支出与收入下的 key 可能相同，需与 `type` 一起确定。
nonisolated struct VoiceCategoryOption: Encodable, Equatable, Sendable {
    /// 分类 key。
    var id: String

    /// 当前语言下的分类名称，最多 50 字。
    var name: String

    /// 所属收支方向。
    var type: VoiceEntryType
}

/// 向服务端声明的客户端能力；服务端只会下发声明过的工具。
nonisolated enum VoiceSessionCapability: String, Encodable, Equatable, Sendable {
    /// 账户工具：调整余额、转账、新建、修改、删除账户。声明后每个账户都必须带类型和余额。
    case accountTools = "account_tools"

    /// 当前版本声明的能力；声明某项能力前，它对应的工具必须都能解码和执行。
    static let declared: [VoiceSessionCapability] = [.accountTools]
}

/// 一次请求：会话上下文与截至目前的全部事件。
nonisolated struct VoiceSessionTurnRequest: Encodable, Equatable, Sendable {
    /// 界面语言：`zh-Hans` 或 `en`。
    var locale: String

    /// 客户端支持的能力。
    var capabilities: [VoiceSessionCapability]

    /// 设备本地时刻，带时区偏移的 ISO 8601。
    var now: String

    /// 默认记账账户；没有时编码为 `null`。
    var defaultAccountId: String?

    /// 全部账户，最多 50 个。
    var accounts: [VoiceAccountOption]

    /// 未删除的分类，最多 100 个。
    var categories: [VoiceCategoryOption]

    /// 本次会话的全部事件，最多 80 条。
    var events: [VoiceSessionEvent]

    private enum CodingKeys: String, CodingKey {
        case locale, capabilities, now, defaultAccountId, accounts, categories, events
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(locale, forKey: .locale)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(now, forKey: .now)
        try container.encode(defaultAccountId, forKey: .defaultAccountId)
        try container.encode(accounts, forKey: .accounts)
        try container.encode(categories, forKey: .categories)
        try container.encode(events, forKey: .events)
    }
}

/// 追问时供用户点选的候选项。
nonisolated struct VoiceAskOption: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// 候选项 id，例如候选流水的 UUID 字符串。
    var id: String

    /// 展示文字。
    var label: String
}

/// 与工具调用一起下发的追问，例如「午饭 28，打车」中缺金额的那笔。
nonisolated struct VoiceFollowUpAsk: Decodable, Equatable, Sendable {
    /// 要问用户的问题。
    var question: String

    /// 供用户点选的候选项；可为空，表示只需语音回答。
    var options: [VoiceAskOption]

    private enum CodingKeys: String, CodingKey {
        case question, options
    }

    /// 创建追问。
    ///
    /// - Parameters:
    ///   - question: 要问用户的问题。
    ///   - options: 候选项。
    init(question: String, options: [VoiceAskOption] = []) {
        self.question = question
        self.options = options
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        question = try container.decode(String.self, forKey: .question)
        options = try container.decodeIfPresent([VoiceAskOption].self, forKey: .options) ?? []
    }
}

/// 一次响应。
nonisolated enum VoiceSessionTurnResponse: Decodable, Equatable, Sendable {
    /// 需要 App 依次执行的工具调用。
    ///
    /// `canFinishLocally` 为真且全部成功时在本地结束本轮；带 `followUpAsk` 且全部成功时直接显示追问、结束本轮，
    /// 两者都省去一次请求。有任一调用失败时都要带结果继续请求。
    case toolCalls([VoiceToolCall], canFinishLocally: Bool, followUpAsk: VoiceFollowUpAsk? = nil)

    /// 追问，本轮结束，等待用户回答。
    case ask(question: String, options: [VoiceAskOption])

    /// 本轮回复。
    case reply(text: String)

    private enum CodingKeys: String, CodingKey {
        case status, toolCalls, canFinishLocally, ask, question, options, text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let status = try container.decode(String.self, forKey: .status)
        switch status {
        case "tool_calls":
            self = try .toolCalls(
                container.decode([VoiceToolCall].self, forKey: .toolCalls),
                // 旧版本服务端没有该字段，按需要继续请求处理
                canFinishLocally: container.decodeIfPresent(Bool.self, forKey: .canFinishLocally) ?? false,
                followUpAsk: container.decodeIfPresent(VoiceFollowUpAsk.self, forKey: .ask)
            )
        case "ask":
            self = try .ask(
                question: container.decode(String.self, forKey: .question),
                options: container.decodeIfPresent([VoiceAskOption].self, forKey: .options) ?? []
            )
        case "reply":
            self = try .reply(text: container.decode(String.self, forKey: .text))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .status, in: container, debugDescription: "未知的响应状态：\(status)"
            )
        }
    }
}

/// 契约上限，与服务端保持一致。
nonisolated enum VoiceSessionLimits {
    /// 一次会话最多的事件数。
    static let maxEvents = 80

    /// 用户一句话的最大长度。
    static let maxUserTextLength = 500

    /// assistant 事件文字的最大长度。
    static let maxAssistantTextLength = 1000

    /// 最多发送的账户数。
    static let maxAccounts = 50

    /// 最多发送的分类数。
    static let maxCategories = 100

    /// 账户、分类名称的最大长度。
    static let maxOptionNameLength = 50

    /// 账户类型的最大长度。
    static let maxAccountTypeLength = 32

    /// 查询结果中备注的最大长度。
    static let maxResultNoteLength = 200

    /// 新增、修改写入的备注最大长度。
    static let maxWrittenNoteLength = 30
}
