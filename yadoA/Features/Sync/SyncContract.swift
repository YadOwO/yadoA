import Foundation

// 与 yadoA_be `src/modules/sync/schemas.ts` 一一对应的同步接口契约。
// 类型都是 nonisolated + Sendable：同步引擎在后台 actor 中编解码和应用大批记录，不占用主线程。

/// 同步契约中的数量上限，与服务端 `MAX_PUSH_CHANGES`、`MAX_PAYLOAD_BYTES` 保持一致。
nonisolated enum SyncContractLimits {
    /// 单次推送最多的变更条数，客户端按此分批。
    static let maxPushChanges = 250

    /// 单条同步内容按 UTF-8 JSON 计算的最大字节数；超过的记录服务端整批拒绝，客户端应跳过并提示。
    ///
    /// 本地 `SyncPayloadCoder` 的输出会转义 `/`，比服务端按 `JSON.stringify` 计算的结果略大，
    /// 用本地字节数判断只会更保守，不会漏判。
    static let maxPayloadBytes = 16 * 1024
}

/// 任意 JSON 值；同步内容对服务端不透明，客户端原样收发。
///
/// 同步内容里的金额都是字符串（`Decimal.description`），数字只有排序号这类整数，
/// 所以用 `Double` 承载小数不会损失精度。
nonisolated enum SyncJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([SyncJSONValue])
    case object([String: SyncJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([SyncJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: SyncJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    /// 从同步内容的 JSON 字节解析；顶层必须是对象。
    ///
    /// - Parameter payload: `SyncPayloadCoder` 生成的 JSON。
    /// - Throws: JSON 不合法或顶层不是对象时抛出 `DecodingError`。
    init(payload: Data) throws {
        let value = try JSONDecoder().decode(SyncJSONValue.self, from: payload)
        guard case .object = value else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [], debugDescription: "同步内容必须是 JSON 对象")
            )
        }
        self = value
    }

    /// 编码为按键排序的 JSON，供备份 DTO 的解码器读取。
    ///
    /// - Returns: JSON 字节。
    /// - Throws: 编码失败时抛出底层错误（如 NaN）。
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// 推送的一条本地变更：新增、修改或删除（墓碑）。
nonisolated struct SyncChange: Encodable, Equatable, Sendable {
    /// 记录类型。
    let entityType: SyncEntityType

    /// 业务记录 UUID。
    let recordID: UUID

    /// 本地裁决时钟；没改过的预置记录为 `distantPast`，编码时按 1970-01-01 发送（与服务端钳制一致）。
    let modifiedAt: Date

    /// 同步内容；删除时为 nil。
    let payload: SyncJSONValue?

    /// 是否为删除。由 `payload` 是否为空决定，保证不会出现「删除却带内容」的非法组合。
    var isDeleted: Bool { payload == nil }

    /// 创建一条新增或修改。
    ///
    /// - Parameters:
    ///   - entityType: 记录类型。
    ///   - recordID: 业务记录 UUID。
    ///   - modifiedAt: 本地裁决时钟。
    ///   - payload: `SyncPayloadCoder` 生成的 JSON 对象。
    /// - Throws: payload 不是 JSON 对象时抛出 `DecodingError`。
    static func upsert(entityType: SyncEntityType, recordID: UUID, modifiedAt: Date, payload: Data) throws -> SyncChange {
        SyncChange(entityType: entityType, recordID: recordID, modifiedAt: modifiedAt, payload: try SyncJSONValue(payload: payload))
    }

    /// 创建一条删除。
    ///
    /// - Parameters:
    ///   - entityType: 记录类型。
    ///   - recordID: 业务记录 UUID。
    ///   - modifiedAt: 删除时间，作为裁决时钟。
    static func deletion(entityType: SyncEntityType, recordID: UUID, modifiedAt: Date) -> SyncChange {
        SyncChange(entityType: entityType, recordID: recordID, modifiedAt: modifiedAt, payload: nil)
    }

    private enum CodingKeys: String, CodingKey {
        case entityType, recordId, modifiedAt, isDeleted, payload
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entityType.rawValue, forKey: .entityType)
        try container.encode(recordID.uuidString.lowercased(), forKey: .recordId)
        // 公元 1 年附近的日期按日历规则格式化结果不稳定，且服务端本就钳制到 1970，这里先钳制
        try container.encode(max(modifiedAt, SyncCoding.minimumModifiedAt), forKey: .modifiedAt)
        try container.encode(isDeleted, forKey: .isDeleted)
        // 删除时必须显式发送 null，服务端不接受缺省
        try container.encode(payload ?? .null, forKey: .payload)
    }
}

/// 服务端保存的一条记录：拉取的变更，或推送被判为 stale 时带回的服务端版本。
nonisolated struct SyncRemoteRecord: Decodable, Equatable, Sendable {
    /// 记录类型的原始值；保留原值是为了让旧版本客户端遇到新类型时只跳过这一条，而不是整页解码失败。
    let entityTypeRawValue: String

    /// 业务记录 UUID。
    let recordID: UUID

    /// 服务端记录的裁决时钟（已钳制）。
    let modifiedAt: Date

    /// 是否为墓碑。
    let isDeleted: Bool

    /// 同步内容；墓碑为 nil。
    let payload: SyncJSONValue?

    /// 用户内单调递增的变更序号。
    let serverVersion: Int64

    /// 解析后的记录类型；本版本不认识的类型为 nil，应用时跳过。
    var entityType: SyncEntityType? {
        SyncEntityType(rawValue: entityTypeRawValue)
    }

    private enum CodingKeys: String, CodingKey {
        case entityType, recordId, modifiedAt, isDeleted, payload, serverVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entityTypeRawValue = try container.decode(String.self, forKey: .entityType)
        recordID = try container.decode(UUID.self, forKey: .recordId)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        isDeleted = try container.decode(Bool.self, forKey: .isDeleted)
        let payload = try container.decodeIfPresent(SyncJSONValue.self, forKey: .payload)
        self.payload = payload == .null ? nil : payload
        serverVersion = try container.decode(Int64.self, forKey: .serverVersion)
    }

    /// 测试与预览用的成员初始化。
    init(
        entityTypeRawValue: String,
        recordID: UUID,
        modifiedAt: Date,
        isDeleted: Bool,
        payload: SyncJSONValue?,
        serverVersion: Int64
    ) {
        self.entityTypeRawValue = entityTypeRawValue
        self.recordID = recordID
        self.modifiedAt = modifiedAt
        self.isDeleted = isDeleted
        self.payload = payload
        self.serverVersion = serverVersion
    }
}

/// 单条变更的推送结果，与请求中的变更一一对应、顺序一致。
nonisolated struct SyncPushResult: Decodable, Equatable, Sendable {
    /// 裁决结果。
    nonisolated enum Status: String, Decodable, Sendable {
        /// 已写入服务端并分配新序号。
        case applied

        /// 服务端已有同样新或更新的版本，本次被忽略；`current` 为服务端版本。
        case stale
    }

    /// 记录类型的原始值。
    let entityTypeRawValue: String

    /// 业务记录 UUID。
    let recordID: UUID

    /// 裁决结果。
    let status: Status

    /// applied 时为新分配的序号；stale 时为服务端现有版本的序号。
    let serverVersion: Int64

    /// applied 时为钳制后的修改时间，应以它更新本地裁决时钟；stale 时为服务端现有版本的时间。
    let modifiedAt: Date

    /// 仅 stale 时有值：服务端当前版本，客户端直接用它覆盖本地。
    let current: SyncRemoteRecord?

    /// 解析后的记录类型。
    var entityType: SyncEntityType? {
        SyncEntityType(rawValue: entityTypeRawValue)
    }

    private enum CodingKeys: String, CodingKey {
        case entityType, recordId, status, serverVersion, modifiedAt, current
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entityTypeRawValue = try container.decode(String.self, forKey: .entityType)
        recordID = try container.decode(UUID.self, forKey: .recordId)
        status = try container.decode(Status.self, forKey: .status)
        serverVersion = try container.decode(Int64.self, forKey: .serverVersion)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        current = try container.decodeIfPresent(SyncRemoteRecord.self, forKey: .current)
    }

    /// 测试用的成员初始化。
    init(
        entityTypeRawValue: String,
        recordID: UUID,
        status: Status,
        serverVersion: Int64,
        modifiedAt: Date,
        current: SyncRemoteRecord?
    ) {
        self.entityTypeRawValue = entityTypeRawValue
        self.recordID = recordID
        self.status = status
        self.serverVersion = serverVersion
        self.modifiedAt = modifiedAt
        self.current = current
    }
}

/// 推送响应。
nonisolated struct SyncPushResponse: Decodable, Equatable, Sendable {
    /// 每条变更的结果；`resetRequired` 时为空。
    let results: [SyncPushResult]

    /// 本机进度早于墓碑清理边界或超出服务端进度，本批未写入任何记录；
    /// 需先完成一轮全量拉取，再用其最后一页的 `nextSince` 重新推送。
    let resetRequired: Bool
}

/// 一页拉取结果。
nonisolated struct SyncPullPage: Decodable, Equatable, Sendable {
    /// 按 `serverVersion` 升序的变更，包含墓碑。
    let changes: [SyncRemoteRecord]

    /// `hasMore` 时是下一页的 `since`；最后一页时是服务端当前序号，保存为本机进度并用于之后的推送。
    let nextSince: Int64

    /// 是否还有下一页。
    let hasMore: Bool

    /// 本机进度已早于墓碑清理边界或超出服务端进度，`changes` 为空；需改从 `since = 0` 做一轮全量拉取。
    let resetRequired: Bool
}

/// 服务端同步状态。
nonisolated struct SyncServerState: Decodable, Equatable, Sendable {
    /// 当前数据代次；删除云端数据后加 1。
    let epoch: Int
}

/// 推送请求体。
nonisolated struct SyncPushRequest: Encodable, Sendable {
    /// 本机设备标识。
    let deviceID: UUID

    /// 本机记录的数据代次。
    let epoch: Int

    /// 本机已拉取到的序号（最近一轮拉取最后一页的 `nextSince`）。
    let since: Int64

    /// 本批变更，1...`SyncContractLimits.maxPushChanges` 条。
    let changes: [SyncChange]

    private enum CodingKeys: String, CodingKey {
        case deviceId, epoch, since, changes
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deviceID.uuidString.lowercased(), forKey: .deviceId)
        try container.encode(epoch, forKey: .epoch)
        try container.encode(since, forKey: .since)
        try container.encode(changes, forKey: .changes)
    }
}

/// 服务端统一错误响应 `{ code, message, details? }` 中需要读取的部分。
nonisolated struct SyncErrorBody: Decodable, Sendable {
    /// 错误详情。
    nonisolated struct Details: Decodable, Sendable {
        /// `EPOCH_MISMATCH` 时为服务端当前代次。
        let epoch: Int?
    }

    /// 错误码，如 `EPOCH_MISMATCH`。
    let code: String

    /// 错误详情。
    let details: Details?
}

/// 同步接口的 JSON 编解码约定：日期为 UTC ISO 8601，带毫秒。
nonisolated enum SyncCoding {
    /// 服务端接受的最早裁决时钟（1970-01-01），更早的值服务端按它记录。
    static let minimumModifiedAt = Date(timeIntervalSince1970: 0)

    /// 编码格式：与服务端 `toISOString()` 输出一致，如 `2026-10-22T08:30:00.000Z`。
    private static let fractionalStyle = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true,
        timeZone: TimeZone(secondsFromGMT: 0) ?? .current
    )

    /// 不带毫秒的格式，仅用于解码时兜底。
    private static let wholeSecondStyle = Date.ISO8601FormatStyle(timeZone: TimeZone(secondsFromGMT: 0) ?? .current)

    /// 创建请求体编码器。
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(fractionalStyle))
        }
        return encoder
    }

    /// 创建响应解码器。
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            if let date = (try? fractionalStyle.parse(rawValue)) ?? (try? wholeSecondStyle.parse(rawValue)) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "同步日期不是 ISO 8601 格式: \(rawValue)"
            )
        }
        return decoder
    }
}
