import Foundation
import UIKit

// 与 yado_hub `/v1/feedback/{product}/*`（意见反馈用户端）对应的数据契约，结构以服务端 openapi.json 为准。
//
// 每个用户在每个产品下只有一个对话。消息序号 seq 是服务端自增的整数，越新越大，同时用作分页游标和已读位置。

// MARK: - 消息

/// 反馈消息的发送方。
nonisolated enum FeedbackSender: Decodable, Equatable {
    /// 用户自己。
    case user

    /// 芽豆团队。
    case team

    /// 服务端的 `user` 是用户，其余都按团队一侧显示；以后新增的发送方（如系统消息）也不会让整页解码失败。
    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = rawValue == "user" ? .user : .team
    }
}

/// 对话中一条已保存的消息。
nonisolated struct FeedbackMessage: Decodable, Equatable, Identifiable {
    /// 消息 ID，由发送方客户端生成。
    let id: UUID

    /// 服务端序号，越新越大。
    let seq: Int64

    /// 发送方。
    let sender: FeedbackSender

    /// 纯文本正文。
    let content: String

    /// 服务端保存的时间。
    let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, seq, sender, content, createdAt
    }

    /// 逐字段创建，供测试使用。
    init(id: UUID = UUID(), seq: Int64, sender: FeedbackSender, content: String, createdAt: Date) {
        self.id = id
        self.seq = seq
        self.sender = sender
        self.content = content
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        seq = try container.decode(Int64.self, forKey: .seq)
        sender = try container.decode(FeedbackSender.self, forKey: .sender)
        content = try container.decode(String.self, forKey: .content)
        let text = try container.decode(String.self, forKey: .createdAt)
        guard let date = AIBillingTimestamp.parse(text) else {
            throw DecodingError.dataCorruptedError(forKey: .createdAt, in: container, debugDescription: "不是 ISO 8601 时间：\(text)")
        }
        createdAt = date
    }
}

/// 一页消息，按序号从新到旧。
nonisolated struct FeedbackMessagePage: Decodable, Equatable {
    /// 本页消息。
    let messages: [FeedbackMessage]

    /// 下一页（更早的消息）的游标；没有更早的消息时为 nil。
    let nextBefore: Int64?
}

/// 未读的团队回复条数。
nonisolated struct FeedbackUnreadCount: Decodable, Equatable {
    /// 未读条数。
    let unreadCount: Int
}

// MARK: - 请求

/// 发消息的请求体。
nonisolated struct FeedbackSendRequest: Encodable, Equatable {
    /// 客户端生成的消息 ID；网络重发时沿用同一个，服务端据此去重。
    let id: UUID

    /// 去掉首尾空白后的正文。
    let content: String

    /// 发送时的设备信息，方便排查问题。
    let clientInfo: FeedbackClientInfo

    private enum CodingKeys: String, CodingKey {
        case id, content, clientInfo
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // 服务端把 ID 统一存为小写，这里也发小写，便于对照日志
        try container.encode(id.uuidString.lowercased(), forKey: .id)
        try container.encode(content, forKey: .content)
        try container.encode(clientInfo, forKey: .clientInfo)
    }
}

/// 标记已读的请求体。
nonisolated struct FeedbackMarkReadRequest: Encodable, Equatable {
    /// 已看到的最新消息序号；服务端只前进不后退。
    let seq: Int64
}

/// 用户发消息时附带的设备信息；只有版本、机型与语言，不含任何账本数据。
nonisolated struct FeedbackClientInfo: Encodable, Equatable {
    /// App 版本与构建号，例如 `1.0 (12)`。
    let appVersion: String

    /// 系统版本，例如 `iOS 27.1`。
    let osVersion: String

    /// 机型标识，例如 `iPhone18,1`。
    let deviceModel: String

    /// App 当前使用的语言，例如 `zh-Hans`。
    let locale: String

    /// 服务端各字段的长度上限；超出时截断，为空时填 `unknown`，避免整条消息因为设备信息被拒。
    private static let limits = (appVersion: 32, osVersion: 32, deviceModel: 64, locale: 32)

    /// 逐字段创建；每个字段都按服务端上限截断，空值填 `unknown`。
    init(appVersion: String, osVersion: String, deviceModel: String, locale: String) {
        self.appVersion = Self.normalized(appVersion, limit: Self.limits.appVersion)
        self.osVersion = Self.normalized(osVersion, limit: Self.limits.osVersion)
        self.deviceModel = Self.normalized(deviceModel, limit: Self.limits.deviceModel)
        self.locale = Self.normalized(locale, limit: Self.limits.locale)
    }

    /// 读取当前设备的信息。
    ///
    /// - Parameters:
    ///   - locale: App 当前使用的语言环境。
    ///   - bundle: 读取版本号的资源包。
    /// - Returns: 本机的设备信息。
    @MainActor
    static func current(locale: Locale, bundle: Bundle = .main) -> FeedbackClientInfo {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return FeedbackClientInfo(
            appVersion: build.isEmpty ? version : "\(version) (\(build))",
            osVersion: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            deviceModel: machineIdentifier,
            locale: locale.identifier
        )
    }

    /// 机型标识；模拟器上取它模拟的机型，而不是 Mac 的 `arm64`。
    private static var machineIdentifier: String {
        #if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        #endif
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// 去掉首尾空白并截断到上限；为空时返回 `unknown`。
    private static func normalized(_ value: String, limit: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : String(trimmed.prefix(limit))
    }
}

// MARK: - 正文校验

/// 发送前的正文校验，与服务端规则一致。
enum FeedbackComposer {
    /// 正文上限；服务端按 UTF-16 长度计算（JavaScript 的字符串长度），一个 emoji 可能算两个。
    static let maxContentLength = 1000

    /// 去掉首尾空白后的正文。
    ///
    /// - Parameter text: 输入框里的原文。
    /// - Returns: 实际会发送的正文。
    static func content(from text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 正文超出上限的长度；没有超出时为 0。
    ///
    /// - Parameter text: 输入框里的原文。
    /// - Returns: 超出的长度，按服务端的计法。
    static func overflow(of text: String) -> Int {
        max(content(from: text).utf16.count - maxContentLength, 0)
    }

    /// 能否发送：去掉首尾空白后不为空，且没有超出上限。
    ///
    /// - Parameter text: 输入框里的原文。
    /// - Returns: 是否可以发送。
    static func canSend(_ text: String) -> Bool {
        !content(from: text).isEmpty && overflow(of: text) == 0
    }
}
