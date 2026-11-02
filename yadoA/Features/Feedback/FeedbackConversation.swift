import Foundation
import Observation

/// 反馈页的对话状态：已保存的消息、还没发出去的消息、加载与已读。
///
/// 每次打开反馈页新建一份，只属于打开时的账号。消息以服务端为准，按序号从旧到新排列；
/// 自己刚发的消息先放在 `outgoing` 里显示，服务端确认后并入 `messages`。
@Observable
final class FeedbackConversation {
    /// 一条还没被服务端确认的消息。
    struct OutgoingMessage: Identifiable, Equatable {
        /// 消息 ID；重发时沿用，服务端据此去重。
        let id: UUID

        /// 去掉首尾空白后的正文。
        let content: String

        /// 在本机点发送的时间。
        let createdAt: Date

        /// 是否发送失败，等用户重发或删除。
        var isFailed: Bool
    }

    /// 首屏加载状态。
    enum LoadState: Equatable {
        /// 还没开始加载。
        case idle

        /// 正在加载第一页。
        case loading

        /// 已加载过；之后的轮询失败不改变这个状态。
        case loaded

        /// 第一页加载失败，界面显示重试。
        case failed(FeedbackAPIError)
    }

    /// 已保存的消息，按序号从旧到新。
    private(set) var messages: [FeedbackMessage] = []

    /// 还没被服务端确认的消息，按发送顺序。
    private(set) var outgoing: [OutgoingMessage] = []

    /// 首屏加载状态。
    private(set) var loadState: LoadState = .idle

    /// 服务端是否还有更早的消息。
    private(set) var hasOlder = false

    /// 是否正在加载更早的消息。
    private(set) var isLoadingOlder = false

    /// 最近一次发送失败的原因；界面提示后调用 `dismissSendFailure()` 清除。
    private(set) var sendFailure: FeedbackAPIError?

    /// 已经上报给服务端的已读位置。
    private var reportedReadSeq: Int64 = 0

    /// 意见反馈接口。
    private let api: FeedbackServing

    /// 对话所属的账号。
    private let userID: String

    /// 全局未读状态；标记已读后同步更新角标。预览中为 nil。
    private let store: FeedbackStore?

    /// 创建对话状态。
    ///
    /// - Parameters:
    ///   - api: 意见反馈接口。
    ///   - userID: 对话所属的账号。
    ///   - store: 全局未读状态。
    init(api: FeedbackServing, userID: String, store: FeedbackStore?) {
        self.api = api
        self.userID = userID
        self.store = store
    }

    /// 拉取最新一页并合并，随后把看到的团队回复标记为已读。首次进入和轮询都调用它。
    ///
    /// 第一页失败时显示重试；已经有消息后轮询失败不打扰用户，等下次轮询。
    func refresh() async {
        if loadState != .loaded {
            loadState = .loading
        }
        let page: FeedbackMessagePage
        do {
            page = try await api.fetchMessages(before: nil)
        } catch {
            if loadState != .loaded {
                loadState = .failed(error as? FeedbackAPIError ?? .network)
            }
            return
        }
        mergeLatest(page)
        loadState = .loaded
        await markReadIfNeeded()
    }

    /// 加载更早的一页，接在最前面。
    func loadOlder() async {
        guard hasOlder, !isLoadingOlder, let oldest = messages.first?.seq else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        guard let page = try? await api.fetchMessages(before: oldest) else { return }
        merge(page.messages)
        hasOlder = page.nextBefore != nil
    }

    /// 发送一条消息：先显示在对话末尾，服务端确认后并入已保存的消息；失败时留在原处等用户重发或删除。
    ///
    /// - Parameters:
    ///   - text: 输入框里的原文；去掉首尾空白后为空或超出上限时不发送。
    ///   - clientInfo: 发送时的设备信息。
    func send(_ text: String, clientInfo: FeedbackClientInfo) async {
        guard FeedbackComposer.canSend(text) else { return }
        let message = OutgoingMessage(id: UUID(), content: FeedbackComposer.content(from: text), createdAt: .now, isFailed: false)
        outgoing.append(message)
        await deliver(message.id, clientInfo: clientInfo)
    }

    /// 重发一条失败的消息，沿用原来的 ID，服务端已经收到过时不会重复保存。
    ///
    /// - Parameters:
    ///   - id: 失败消息的 ID。
    ///   - clientInfo: 重发时的设备信息。
    func retry(_ id: UUID, clientInfo: FeedbackClientInfo) async {
        await deliver(id, clientInfo: clientInfo)
    }

    /// 删除一条发送失败的消息。
    ///
    /// - Parameter id: 失败消息的 ID。
    func discard(_ id: UUID) {
        outgoing.removeAll { $0.id == id && $0.isFailed }
    }

    /// 清除发送失败的提示。
    func dismissSendFailure() {
        sendFailure = nil
    }

    /// 对话里最后一条的 ID，用于有新消息时滚到底部。
    var lastItemID: UUID? {
        outgoing.last?.id ?? messages.last?.id
    }

    // MARK: - 私有方法

    /// 发出一条待确认的消息。
    ///
    /// - Parameters:
    ///   - id: 待确认消息的 ID。
    ///   - clientInfo: 设备信息。
    private func deliver(_ id: UUID, clientInfo: FeedbackClientInfo) async {
        guard let index = outgoing.firstIndex(where: { $0.id == id }) else { return }
        outgoing[index].isFailed = false
        let message = outgoing[index]
        do {
            let saved = try await api.send(FeedbackSendRequest(id: message.id, content: message.content, clientInfo: clientInfo))
            merge([saved])
        } catch {
            if let failedIndex = outgoing.firstIndex(where: { $0.id == id }) {
                outgoing[failedIndex].isFailed = true
            }
            sendFailure = error as? FeedbackAPIError ?? .network
        }
    }

    /// 合并最新一页。
    ///
    /// 第一次加载，或两次刷新之间新消息超过一页、和已有消息接不上时，以这一页为准并标记还有更早的消息；
    /// 否则按序号合并去重。
    ///
    /// - Parameter page: 最新一页。
    private func mergeLatest(_ page: FeedbackMessagePage) {
        let fetched = page.messages.sorted { $0.seq < $1.seq }
        guard let oldestFetched = fetched.first?.seq else {
            if messages.isEmpty {
                hasOlder = false
            }
            return
        }
        let newestLocal = messages.last?.seq ?? 0
        if messages.isEmpty || (page.nextBefore != nil && oldestFetched > newestLocal) {
            messages = fetched
            hasOlder = page.nextBefore != nil
            removeConfirmedOutgoing()
        } else {
            merge(fetched)
        }
    }

    /// 按序号合并消息并去重，同时移除已被服务端确认的待发消息。
    ///
    /// - Parameter incoming: 新取到的消息。
    private func merge(_ incoming: [FeedbackMessage]) {
        var bySeq = Dictionary(messages.map { ($0.seq, $0) }, uniquingKeysWith: { _, latest in latest })
        for message in incoming {
            bySeq[message.seq] = message
        }
        messages = bySeq.values.sorted { $0.seq < $1.seq }
        removeConfirmedOutgoing()
    }

    /// 服务端已经保存的消息不再作为待发消息显示。
    private func removeConfirmedOutgoing() {
        let savedIDs = Set(messages.map(\.id))
        outgoing.removeAll { savedIDs.contains($0.id) }
    }

    /// 有比已上报位置更新的团队回复时，把已读位置推进到最新一条，并用服务端带回的未读数更新角标。
    private func markReadIfNeeded() async {
        guard let latestSeq = messages.last?.seq, latestSeq > reportedReadSeq else { return }
        let hasNewReply = messages.contains { $0.sender == .team && $0.seq > reportedReadSeq }
        guard hasNewReply || (store?.unreadCount ?? 0) > 0 else {
            reportedReadSeq = latestSeq
            return
        }
        guard let unreadCount = try? await api.markRead(upTo: latestSeq) else { return }
        reportedReadSeq = max(reportedReadSeq, latestSeq)
        store?.applyUnreadCount(unreadCount, for: userID)
    }
}

// MARK: - 时间线

/// 对话页的一行：时间分隔、已保存的消息或待确认的消息。
enum FeedbackTimelineRow: Identifiable, Equatable {
    /// 两条消息间隔较久时插入的时间。
    case time(Date)

    /// 已保存的消息。
    case message(FeedbackMessage)

    /// 待确认的消息。
    case outgoing(FeedbackConversation.OutgoingMessage)

    /// 稳定标识；时间分隔用紧随其后那条消息的 ID 派生。
    var id: String {
        switch self {
        case let .time(date): "time-\(date.timeIntervalSince1970)"
        case let .message(message): message.id.uuidString
        case let .outgoing(message): message.id.uuidString
        }
    }
}

/// 把消息排成对话页的行，在需要的地方插入时间。
enum FeedbackTimeline {
    /// 相邻两条消息相隔超过这么久时，在后一条前面显示时间。
    static let timeGap: TimeInterval = 5 * 60

    /// 生成对话页的行：已保存的消息在前，待确认的消息接在末尾；第一条前面和间隔较久的消息前面插入时间。
    ///
    /// - Parameters:
    ///   - messages: 已保存的消息，按序号从旧到新。
    ///   - outgoing: 待确认的消息，按发送顺序。
    /// - Returns: 对话页的行。
    static func rows(messages: [FeedbackMessage], outgoing: [FeedbackConversation.OutgoingMessage]) -> [FeedbackTimelineRow] {
        let items: [(date: Date, row: FeedbackTimelineRow)] =
            messages.map { ($0.createdAt, .message($0)) } + outgoing.map { ($0.createdAt, .outgoing($0)) }
        var rows: [FeedbackTimelineRow] = []
        var previousDate: Date?
        for item in items {
            if previousDate.map({ item.date.timeIntervalSince($0) > timeGap }) ?? true {
                rows.append(.time(item.date))
            }
            rows.append(item.row)
            previousDate = item.date
        }
        return rows
    }
}
