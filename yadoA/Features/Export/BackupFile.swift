import Foundation
import SwiftData

private extension UUID {
    /// 备份格式要求的小写连字符 UUID 字符串。
    nonisolated var backupJSONString: String {
        uuidString.lowercased()
    }
}

/// 备份格式版本号的演进规则边界。
///
/// 只新增可选字段时保持 `current` 不变；删除或改变既有字段语义时必须递增，
/// 由未来导入功能按版本迁移。该版本与 SwiftData schema 版本各自独立演进。
nonisolated enum BackupFormatVersion {
    /// 首版备份格式版本。
    static let current = 1
}

/// 备份文件的顶层信封：格式版本、导出元数据与全部业务数据。
///
/// 信封是备份格式的稳定契约：未来版本只允许追加可选字段，
/// 旧文件在新版本 App 中解码不得整体失效。
nonisolated struct BackupFile: Codable, Equatable, Sendable {
    /// 备份格式版本，读取端据此决定迁移策略。
    let formatVersion: Int

    /// 导出完成时间（UTC，含小数秒）。
    let exportedAt: Date

    /// 生成该备份的 App 营销版本（`CFBundleShortVersionString`）。
    let appVersion: String

    /// 生成该备份的 App 构建号（`CFBundleVersion`）；营销版本静态时的主要诊断值。
    let appBuild: String

    /// 全部账户，包含启用与已停用账户。
    let accounts: [BackupAccount]

    /// 全部账户流水，包含支出、收入与余额调整。
    let transactions: [BackupTransaction]

    /// canonical 默认记账账户偏好；为 `nil` 表示存储中还没有偏好记录。
    let bookkeepingPreference: BackupBookkeepingPreference?

    /// 从完整业务快照构造备份信封。
    init(
        formatVersion: Int = BackupFormatVersion.current,
        exportedAt: Date,
        appVersion: String,
        appBuild: String,
        accounts: [BackupAccount],
        transactions: [BackupTransaction],
        bookkeepingPreference: BackupBookkeepingPreference?
    ) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.accounts = accounts
        self.transactions = transactions
        self.bookkeepingPreference = bookkeepingPreference
    }

    /// 从备份 JSON 解码信封。
    ///
    /// 身份与元数据字段严格解码；数据数组允许缺省（向前兼容空集合），
    /// 未来新增的可选字段由各 DTO 自行容忍。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion) ?? ""
        appBuild = try container.decodeIfPresent(String.self, forKey: .appBuild) ?? ""
        accounts = try container.decodeIfPresent([BackupAccount].self, forKey: .accounts) ?? []
        transactions = try container.decodeIfPresent([BackupTransaction].self, forKey: .transactions) ?? []
        bookkeepingPreference = try container.decodeIfPresent(
            BackupBookkeepingPreference.self,
            forKey: .bookkeepingPreference
        )
    }
}

/// 备份中的账户值快照；字段与 `Account` 的持久化列一一镜像。
///
/// 只携带可长期解释的业务字段，不包含任何派生展示状态；
/// 金额使用精确十进制的字符串表达，避免浮点与语言环境差异。
nonisolated struct BackupAccount: Codable, Equatable, Sendable {
    /// 跨导出与导入保持稳定的账户标识；不得重新生成。
    let id: UUID

    /// `AccountType.rawValue` 的持久化原文。
    let type: String

    /// 静态模板稳定标识；直接创建的账户为 `nil`。
    let templateID: String?

    /// 账户展示名称。
    let name: String

    /// 可选备注。
    let note: String?

    /// 可选卡号后缀。
    let lastFourDigits: String?

    /// 精确十进制余额的字符串表达（`Decimal.description`）。
    let balance: String

    /// ISO 4217 货币代码。
    let currencyCode: String

    /// 账户创建时间。
    let createdAt: Date

    /// 账户资料最近一次更新时间。
    let updatedAt: Date

    /// 停用时间；为 `nil` 表示账户仍处于启用状态。
    let deactivatedAt: Date?

    /// 从持久化账户生成值快照。
    init(_ account: Account) {
        id = account.id
        type = account.typeRawValue
        templateID = account.templateID
        name = account.name
        note = account.note
        lastFourDigits = account.lastFourDigits
        balance = account.balance.description
        currencyCode = account.currencyCode
        createdAt = account.createdAt
        updatedAt = account.updatedAt
        deactivatedAt = account.deactivatedAt
    }

    /// 编码账户快照；所有字段都写入，`nil` 可选值以 JSON `null` 保留。
    ///
    /// UUID 显式使用小写连字符字符串，避免依赖 Foundation 默认编码的大小写。
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id.backupJSONString, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(templateID, forKey: .templateID)
        try container.encode(name, forKey: .name)
        try container.encode(note, forKey: .note)
        try container.encode(lastFourDigits, forKey: .lastFourDigits)
        try container.encode(balance, forKey: .balance)
        try container.encode(currencyCode, forKey: .currencyCode)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(deactivatedAt, forKey: .deactivatedAt)
    }

    /// 成员逐一初始化，供测试构造精确夹具。
    init(
        id: UUID,
        type: String,
        templateID: String?,
        name: String,
        note: String?,
        lastFourDigits: String?,
        balance: String,
        currencyCode: String,
        createdAt: Date,
        updatedAt: Date,
        deactivatedAt: Date?
    ) {
        self.id = id
        self.type = type
        self.templateID = templateID
        self.name = name
        self.note = note
        self.lastFourDigits = lastFourDigits
        self.balance = balance
        self.currencyCode = currencyCode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deactivatedAt = deactivatedAt
    }

    /// 从备份 JSON 解码账户快照。
    ///
    /// 身份字段严格解码；内容字段在旧文件缺少时使用安全默认值，
    /// 保证未来追加可选字段不会让旧版本解码整体失效。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        templateID = try container.decodeIfPresent(String.self, forKey: .templateID)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        note = try container.decodeIfPresent(String.self, forKey: .note)
        lastFourDigits = try container.decodeIfPresent(String.self, forKey: .lastFourDigits)
        balance = try container.decodeIfPresent(String.self, forKey: .balance) ?? "0"
        currencyCode = try container.decodeIfPresent(String.self, forKey: .currencyCode) ?? "CNY"
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        deactivatedAt = try container.decodeIfPresent(Date.self, forKey: .deactivatedAt)
    }
}

/// 备份中的账户流水量值快照；字段与 `AccountTransaction` 的持久化列一一镜像。
///
/// 类型与分类保存 rawValue 原文（如 `"diningExpense"`），由导入端按当前
/// 版本的枚举解释；字段矩阵的合法性校验与 `validatedPayload()` 一致。
nonisolated struct BackupTransaction: Codable, Equatable, Sendable {
    /// 跨导出与导入保持稳定的流水标识；不得重新生成。
    let id: UUID

    /// 流水绑定账户的稳定 UUID。
    let accountID: UUID

    /// `AccountTransactionType.rawValue` 的持久化原文。
    let type: String

    /// 支出或收入分类 rawValue 原文；余额调整为 `nil`。
    let category: String?

    /// 支出/收入的正数字符串金额；其他类型为 `nil`。
    let amount: String?

    /// 用户可选的流水标题。
    let title: String?

    /// 余额调整前值的字符串金额；其他类型为 `nil`。
    let balanceBefore: String?

    /// 余额调整后值的字符串金额；其他类型为 `nil`。
    let balanceAfter: String?

    /// 带符号差额的字符串金额；其他类型为 `nil`。
    let balanceDelta: String?

    /// ISO 4217 货币代码。
    let currencyCode: String

    /// `YYYYMMDD` 公历业务日整数。
    let transactionDay: Int

    /// 可选备注。
    let note: String?

    /// 流水首次保存时间，用于同业务日内排序。
    let savedAt: Date

    /// 从持久化流水生成值快照。
    init(_ transaction: AccountTransaction) {
        id = transaction.id
        accountID = transaction.accountID
        type = transaction.typeRawValue
        category = transaction.categoryRawValue
        amount = transaction.amount?.description
        title = transaction.title
        balanceBefore = transaction.balanceBefore?.description
        balanceAfter = transaction.balanceAfter?.description
        balanceDelta = transaction.balanceDelta?.description
        currencyCode = transaction.currencyCode
        transactionDay = transaction.transactionDay
        note = transaction.note
        savedAt = transaction.savedAt
    }

    /// 编码流水快照；所有字段都写入，`nil` 可选值以 JSON `null` 保留。
    ///
    /// UUID 显式使用小写连字符字符串，避免依赖 Foundation 默认编码的大小写。
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id.backupJSONString, forKey: .id)
        try container.encode(accountID.backupJSONString, forKey: .accountID)
        try container.encode(type, forKey: .type)
        try container.encode(category, forKey: .category)
        try container.encode(amount, forKey: .amount)
        try container.encode(title, forKey: .title)
        try container.encode(balanceBefore, forKey: .balanceBefore)
        try container.encode(balanceAfter, forKey: .balanceAfter)
        try container.encode(balanceDelta, forKey: .balanceDelta)
        try container.encode(currencyCode, forKey: .currencyCode)
        try container.encode(transactionDay, forKey: .transactionDay)
        try container.encode(note, forKey: .note)
        try container.encode(savedAt, forKey: .savedAt)
    }

    /// 成员逐一初始化，供测试构造精确夹具。
    init(
        id: UUID,
        accountID: UUID,
        type: String,
        category: String?,
        amount: String?,
        title: String?,
        balanceBefore: String?,
        balanceAfter: String?,
        balanceDelta: String?,
        currencyCode: String,
        transactionDay: Int,
        note: String?,
        savedAt: Date
    ) {
        self.id = id
        self.accountID = accountID
        self.type = type
        self.category = category
        self.amount = amount
        self.title = title
        self.balanceBefore = balanceBefore
        self.balanceAfter = balanceAfter
        self.balanceDelta = balanceDelta
        self.currencyCode = currencyCode
        self.transactionDay = transactionDay
        self.note = note
        self.savedAt = savedAt
    }

    /// 从备份 JSON 解码流水快照。
    ///
    /// 身份与账户绑定字段严格解码；内容字段在旧文件缺少时使用安全默认值。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        accountID = try container.decode(UUID.self, forKey: .accountID)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        category = try container.decodeIfPresent(String.self, forKey: .category)
        amount = try container.decodeIfPresent(String.self, forKey: .amount)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        balanceBefore = try container.decodeIfPresent(String.self, forKey: .balanceBefore)
        balanceAfter = try container.decodeIfPresent(String.self, forKey: .balanceAfter)
        balanceDelta = try container.decodeIfPresent(String.self, forKey: .balanceDelta)
        currencyCode = try container.decodeIfPresent(String.self, forKey: .currencyCode) ?? "CNY"
        transactionDay = try container.decodeIfPresent(Int.self, forKey: .transactionDay) ?? 0
        note = try container.decodeIfPresent(String.self, forKey: .note)
        savedAt = try container.decodeIfPresent(Date.self, forKey: .savedAt) ?? .distantPast
    }
}

/// 备份中的默认记账账户偏好。
///
/// 三种状态通过信封与键值组合表达：信封键缺省表示无偏好记录；
/// 对象内 `defaultAccountID` 为 JSON `null` 表示明确无默认；
/// 有值表示指针原值（含失效指针，由导入端重新解析，不在导出时修复）。
nonisolated struct BackupBookkeepingPreference: Codable, Equatable, Sendable {
    /// 默认账户稳定 UUID；为 `nil` 时编码为显式 JSON `null`。
    let defaultAccountID: UUID?

    /// 成员逐一初始化，供测试构造精确夹具。
    init(defaultAccountID: UUID?) {
        self.defaultAccountID = defaultAccountID
    }

    /// 从备份 JSON 解码偏好；键缺省与显式 `null` 都解析为无默认。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultAccountID = try container.decodeIfPresent(UUID.self, forKey: .defaultAccountID)
    }

    /// 编码偏好；`defaultAccountID` 为 `nil` 时写出显式 JSON `null`。
    ///
    /// 不能使用合成编码：合成的可选编码会省略键，导致“明确无默认”
    /// 与“键缺失”两种状态在文件中不可区分。
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            defaultAccountID?.backupJSONString,
            forKey: .defaultAccountID
        )
    }
}

extension BackupFile {
    /// 信封的稳定 JSON 键名。
    enum CodingKeys: String, CodingKey {
        case formatVersion
        case exportedAt
        case appVersion
        case appBuild
        case accounts
        case transactions
        case bookkeepingPreference
    }
}

extension BackupAccount {
    /// 账户快照的稳定 JSON 键名。
    enum CodingKeys: String, CodingKey {
        case id
        case type
        case templateID
        case name
        case note
        case lastFourDigits
        case balance
        case currencyCode
        case createdAt
        case updatedAt
        case deactivatedAt
    }
}

extension BackupTransaction {
    /// 流水快照的稳定 JSON 键名。
    enum CodingKeys: String, CodingKey {
        case id
        case accountID
        case type
        case category
        case amount
        case title
        case balanceBefore
        case balanceAfter
        case balanceDelta
        case currencyCode
        case transactionDay
        case note
        case savedAt
    }
}

extension BackupBookkeepingPreference {
    /// 偏好快照的稳定 JSON 键名。
    enum CodingKeys: String, CodingKey {
        case defaultAccountID
    }
}
