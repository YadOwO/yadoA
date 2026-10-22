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

/// 修改备注的方式：`patch` 中不出现表示不改，`null` 表示清空。
nonisolated enum VoiceNotePatch: Equatable, Sendable {
    /// 改为新备注。
    case set(String)

    /// 清空备注。
    case clear
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
    var note: VoiceNotePatch?

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
        note: VoiceNotePatch? = nil
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
        if container.contains(.note) {
            note = try container.decodeNil(forKey: .note)
                ? .clear
                : .set(container.decode(String.self, forKey: .note))
        } else {
            note = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(amount, forKey: .amount)
        try container.encodeIfPresent(accountId, forKey: .accountId)
        try container.encodeIfPresent(categoryId, forKey: .categoryId)
        try container.encodeIfPresent(date, forKey: .date)
        switch note {
        case let .set(value): try container.encode(value, forKey: .note)
        case .clear: try container.encodeNil(forKey: .note)
        case nil: break
        }
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

    /// 调用 id，在整个会话内唯一。
    var id: String {
        switch self {
        case let .searchTransactions(id, _), let .summarizeTransactions(id, _),
             let .createTransaction(id, _), let .updateTransaction(id, _), let .deleteTransaction(id, _):
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
        }
    }
}

// MARK: - 工具执行结果（App → 服务端）

/// 工具执行失败的原因。
nonisolated enum VoiceToolErrorCode: String, Codable, Equatable, Sendable {
    /// 流水不存在。
    case notFound = "not_found"

    /// 余额调整，或已停用账户下的流水，不能修改、删除。
    case notEditable = "not_editable"

    /// 参数不合法，例如账户已停用、分类已删除、日期无效。
    case invalidInput = "invalid_input"

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

    /// 新增成功，携带新流水的 UUID 字符串。
    case created(id: String)

    /// 修改或删除成功。
    case succeeded

    /// 是否执行成功。
    var isSuccess: Bool {
        if case .failure = self { return false }
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case ok, code, total, items, count, expenseTotal, incomeTotal, id
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

/// 一次请求：会话上下文与截至目前的全部事件。
nonisolated struct VoiceSessionTurnRequest: Encodable, Equatable, Sendable {
    /// 界面语言：`zh-Hans` 或 `en`。
    var locale: String

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
        case locale, now, defaultAccountId, accounts, categories, events
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(locale, forKey: .locale)
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

    /// 查询结果中备注的最大长度。
    static let maxResultNoteLength = 200

    /// 新增、修改写入的备注最大长度。
    static let maxWrittenNoteLength = 30
}
