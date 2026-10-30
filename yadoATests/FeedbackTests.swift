import Foundation
import Testing
@testable import yadoA

/// 验证意见反馈：契约编解码、请求构造、正文校验、对话加载与发送、未读数与时间线。
@Suite("意见反馈")
@MainActor
struct FeedbackTests {
    // MARK: - 契约

    @Test("消息解码：时间带不带毫秒都行，user 以外的发送方按团队显示，ID 不区分大小写，时间格式不对整页失败")
    func decodesFeedbackContract() throws {
        let json = """
        {"messages":[
          {"id":"778b5a8f-af42-43eb-82ae-08f3e6452d99","seq":3,"sender":"admin","content":"收到，会修","createdAt":"2026-10-30T03:03:09.000Z"},
          {"id":"FC505970-FFF7-4ABD-907B-F3D66828FC4E","seq":2,"sender":"user","content":"点保存没反应","createdAt":"2026-10-30T03:03:00Z"},
          {"id":"015b7787-dece-4d74-925d-dc6dcf7c2e6b","seq":1,"sender":"system","content":"欢迎","createdAt":"2026-10-30T03:03:00.000Z"}
        ],"nextBefore":1}
        """
        let page = try JSONDecoder().decode(FeedbackMessagePage.self, from: Data(json.utf8))
        #expect(page.messages.map(\.seq) == [3, 2, 1])
        #expect(page.messages.map(\.sender) == [.team, .user, .team])
        #expect(page.messages[0].id == UUID(uuidString: "778B5A8F-AF42-43EB-82AE-08F3E6452D99"))
        #expect(page.messages[0].createdAt == Date(timeIntervalSince1970: 1_793_329_389))
        #expect(page.messages[1].createdAt == Date(timeIntervalSince1970: 1_793_329_380))
        #expect(page.nextBefore == 1)

        let lastPage = try JSONDecoder().decode(FeedbackMessagePage.self, from: Data(#"{"messages":[],"nextBefore":null}"#.utf8))
        #expect(lastPage.messages.isEmpty)
        #expect(lastPage.nextBefore == nil)

        let unread = try JSONDecoder().decode(FeedbackUnreadCount.self, from: Data(#"{"unreadCount":2}"#.utf8))
        #expect(unread.unreadCount == 2)

        let malformed = #"{"messages":[{"id":"015b7787-dece-4d74-925d-dc6dcf7c2e6b","seq":1,"sender":"user","content":"x","createdAt":"yesterday"}],"nextBefore":null}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(FeedbackMessagePage.self, from: Data(malformed.utf8))
        }
    }

    @Test("发消息请求体：ID 发小写；设备信息超长截断，空值填 unknown")
    func encodesSendRequest() throws {
        let info = FeedbackClientInfo(
            appVersion: "  ",
            osVersion: "iOS 27.1",
            deviceModel: String(repeating: "x", count: 80),
            locale: "zh-Hans"
        )
        #expect(info.appVersion == "unknown")
        #expect(info.deviceModel.count == 64)

        let id = try #require(UUID(uuidString: "778B5A8F-AF42-43EB-82AE-08F3E6452D99"))
        let request = FeedbackSendRequest(id: id, content: "点保存没反应", clientInfo: info)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        #expect(object?["id"] as? String == "778b5a8f-af42-43eb-82ae-08f3e6452d99")
        #expect(object?["content"] as? String == "点保存没反应")
        let clientInfo = object?["clientInfo"] as? [String: Any]
        #expect(clientInfo?["osVersion"] as? String == "iOS 27.1")
        #expect(clientInfo?["locale"] as? String == "zh-Hans")
    }

    @Test("请求的方法、路径、产品代号、分页参数、请求体与鉴权头")
    func buildsFeedbackRequests() throws {
        let endpoint = try #require(URL(string: "https://example.invalid"))
        let api = FeedbackAPI(endpoint: endpoint) { "token" }

        let latest = api.makeURLRequest(.messages(before: nil, limit: 30), body: nil, token: "abc")
        #expect(latest.httpMethod == "GET")
        #expect(latest.url?.absoluteString == "https://example.invalid/v1/feedback/yadoa/messages?limit=30")
        #expect(latest.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
        #expect(latest.httpBody == nil)
        #expect(latest.timeoutInterval == FeedbackAPI.requestTimeout)

        let older = api.makeURLRequest(.messages(before: 41, limit: 30), body: nil, token: "abc")
        #expect(older.url?.query() == "limit=30&before=41")

        let body = Data(#"{"seq":3}"#.utf8)
        let send = api.makeURLRequest(.send, body: body, token: "abc")
        #expect(send.httpMethod == "POST")
        #expect(send.url?.path() == "/v1/feedback/yadoa/messages")
        #expect(send.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(send.httpBody == body)

        let read = api.makeURLRequest(.read, body: body, token: "abc")
        #expect(read.httpMethod == "POST")
        #expect(read.url?.path() == "/v1/feedback/yadoa/read")

        let unread = api.makeURLRequest(.unread, body: nil, token: "abc")
        #expect(unread.httpMethod == "GET")
        #expect(unread.url?.absoluteString == "https://example.invalid/v1/feedback/yadoa/unread")
    }

    @Test("错误状态码映射：限流单独区分")
    func mapsFeedbackErrorStatusCodes() {
        #expect(FeedbackAPI.error(statusCode: 401) == .unauthorized)
        #expect(FeedbackAPI.error(statusCode: 429) == .rateLimited)
        #expect(FeedbackAPI.error(statusCode: 503) == .serviceUnavailable)
        #expect(FeedbackAPI.error(statusCode: 400) == .invalidContract)
        #expect(FeedbackAPI.error(statusCode: 409) == .invalidContract)
    }

    @Test("正文校验：去掉首尾空白后为空不能发；上限按 UTF-16 计算，与服务端一致")
    func validatesContent() {
        #expect(!FeedbackComposer.canSend(" \n "))
        #expect(FeedbackComposer.content(from: "  点保存没反应\n") == "点保存没反应")

        let atLimit = String(repeating: "字", count: FeedbackComposer.maxContentLength)
        #expect(FeedbackComposer.overflow(of: atLimit) == 0)
        #expect(FeedbackComposer.canSend(atLimit))
        #expect(FeedbackComposer.overflow(of: atLimit + "字") == 1)
        #expect(!FeedbackComposer.canSend(atLimit + "字"))

        // emoji 在服务端算两个字
        #expect(FeedbackComposer.canSend(String(repeating: "😀", count: 500)))
        #expect(FeedbackComposer.overflow(of: String(repeating: "😀", count: 501)) == 2)
    }

    // MARK: - 对话

    @Test("首次加载：消息按序号从旧到新，有更早消息时可加载；看到团队回复后标记已读并更新角标，没有新回复不再重复标记")
    func loadsLatestAndMarksRead() async {
        let api = FakeFeedbackAPI()
        api.unreadResults = [.success(1)]
        let store = FeedbackStore(api: api) { "user-1" }
        await store.refreshUnread()
        #expect(store.unreadCount == 1)

        api.pages[nil] = .success(FeedbackMessagePage(
            messages: [Self.message(3, sender: .team), Self.message(2)],
            nextBefore: 2
        ))
        api.markReadResult = .success(0)
        let conversation = FeedbackConversation(api: api, userID: "user-1", store: store)
        await conversation.refresh()

        #expect(conversation.loadState == .loaded)
        #expect(conversation.messages.map(\.seq) == [2, 3])
        #expect(conversation.hasOlder)
        #expect(api.markedReadSeqs == [3])
        #expect(store.unreadCount == 0)

        await conversation.refresh()
        #expect(api.markedReadSeqs == [3])
    }

    @Test("首次加载失败显示重试；已有消息后轮询失败保持已加载")
    func reportsFirstLoadFailure() async {
        let api = FakeFeedbackAPI()
        api.pages[nil] = .failure(.network)
        let conversation = FeedbackConversation(api: api, userID: "user-1", store: nil)
        await conversation.refresh()
        #expect(conversation.loadState == .failed(.network))

        api.pages[nil] = .success(FeedbackMessagePage(messages: [Self.message(1)], nextBefore: nil))
        await conversation.refresh()
        #expect(conversation.loadState == .loaded)

        api.pages[nil] = .failure(.timeout)
        await conversation.refresh()
        #expect(conversation.loadState == .loaded)
        #expect(conversation.messages.map(\.seq) == [1])
    }

    @Test("发送成功并入对话；失败留在原处，重发沿用原 ID；删除失败的消息；空白不发送")
    func sendsAndRetries() async throws {
        let api = FakeFeedbackAPI()
        api.pages[nil] = .success(FeedbackMessagePage(messages: [], nextBefore: nil))
        let conversation = FeedbackConversation(api: api, userID: "user-1", store: nil)
        await conversation.refresh()
        #expect(!conversation.hasOlder)

        await conversation.send("  点保存没反应  ", clientInfo: Self.clientInfo)
        #expect(api.sentRequests.first?.content == "点保存没反应")
        #expect(conversation.messages.map(\.content) == ["点保存没反应"])
        #expect(conversation.outgoing.isEmpty)

        api.sendResults = [.failure(.network)]
        await conversation.send("iPhone 上必现", clientInfo: Self.clientInfo)
        let failed = try #require(conversation.outgoing.first)
        #expect(failed.isFailed)
        #expect(conversation.sendFailure == .network)
        #expect(conversation.lastItemID == failed.id)

        await conversation.retry(failed.id, clientInfo: Self.clientInfo)
        #expect(api.sentRequests.last?.id == failed.id)
        #expect(conversation.outgoing.isEmpty)
        #expect(conversation.messages.last?.id == failed.id)

        api.sendResults = [.failure(.rateLimited)]
        await conversation.send("第三条", clientInfo: Self.clientInfo)
        #expect(conversation.sendFailure == .rateLimited)
        conversation.dismissSendFailure()
        #expect(conversation.sendFailure == nil)
        conversation.discard(try #require(conversation.outgoing.first).id)
        #expect(conversation.outgoing.isEmpty)

        await conversation.send("   ", clientInfo: Self.clientInfo)
        #expect(api.sentRequests.count == 4)
    }

    @Test("加载更早的消息接在前面，翻到开头后不再请求")
    func loadsOlderPages() async {
        let api = FakeFeedbackAPI()
        api.pages[nil] = .success(FeedbackMessagePage(messages: [Self.message(5), Self.message(4)], nextBefore: 4))
        api.pages[4] = .success(FeedbackMessagePage(messages: [Self.message(3), Self.message(2)], nextBefore: 2))
        api.pages[2] = .success(FeedbackMessagePage(messages: [Self.message(1)], nextBefore: nil))
        let conversation = FeedbackConversation(api: api, userID: "user-1", store: nil)
        await conversation.refresh()

        await conversation.loadOlder()
        #expect(conversation.messages.map(\.seq) == [2, 3, 4, 5])
        #expect(conversation.hasOlder)

        await conversation.loadOlder()
        #expect(conversation.messages.map(\.seq) == [1, 2, 3, 4, 5])
        #expect(!conversation.hasOlder)

        await conversation.loadOlder()
        #expect(api.requestedBefore == [nil, 4, 2])
    }

    @Test("轮询按序号合并新消息；两次轮询之间新消息超过一页、接不上时以最新一页为准")
    func mergesPolledPages() async {
        let api = FakeFeedbackAPI()
        api.pages[nil] = .success(FeedbackMessagePage(messages: [Self.message(2), Self.message(1)], nextBefore: nil))
        let conversation = FeedbackConversation(api: api, userID: "user-1", store: nil)
        await conversation.refresh()
        #expect(!conversation.hasOlder)

        api.pages[nil] = .success(FeedbackMessagePage(messages: [Self.message(3, sender: .team), Self.message(2)], nextBefore: 2))
        await conversation.refresh()
        #expect(conversation.messages.map(\.seq) == [1, 2, 3])
        #expect(!conversation.hasOlder)

        api.pages[nil] = .success(FeedbackMessagePage(messages: [Self.message(40), Self.message(39)], nextBefore: 39))
        await conversation.refresh()
        #expect(conversation.messages.map(\.seq) == [39, 40])
        #expect(conversation.hasOlder)
    }

    // MARK: - 未读数

    @Test("未读数：未登录清零，换账号先清零，查询失败保留原值")
    func refreshesUnreadPerAccount() async {
        let api = FakeFeedbackAPI()
        let user = UserBox("user-1")
        let store = FeedbackStore(api: api) { user.id }

        api.unreadResults = [.success(2)]
        await store.refreshUnread()
        #expect(store.unreadCount == 2)

        api.unreadResults = [.failure(.network)]
        await store.refreshUnread()
        #expect(store.unreadCount == 2)

        user.id = "user-2"
        await store.refreshUnread()
        #expect(store.unreadCount == 0)

        store.applyUnreadCount(5, for: "user-1")
        #expect(store.unreadCount == 0)

        api.unreadResults = [.success(3)]
        await store.refreshUnread()
        #expect(store.unreadCount == 3)

        user.id = nil
        await store.refreshUnread()
        #expect(store.unreadCount == 0)
    }

    @Test("刷新进行中反馈页标记了已读，晚到的旧刷新结果不再覆盖")
    func staleRefreshDoesNotOverrideMarkRead() async {
        let api = FakeFeedbackAPI()
        let gate = AsyncSaveGate()
        api.unreadGate = gate
        api.unreadResults = [.success(3)]
        let store = FeedbackStore(api: api) { "user-1" }

        let refresh = Task { await store.refreshUnread() }
        while !gate.hasStarted {
            await Task.yield()
        }
        store.applyUnreadCount(0, for: "user-1")
        gate.resume()
        await refresh.value

        #expect(store.unreadCount == 0)
    }

    // MARK: - 时间线与文案

    @Test("时间线：第一条和间隔超过 5 分钟的消息前插入时间，待发消息接在末尾")
    func buildsTimeline() {
        let start = Date(timeIntervalSince1970: 1_793_329_380)
        let first = Self.message(1, sender: .team, at: start)
        let second = Self.message(2, at: start.addingTimeInterval(60))
        let third = Self.message(3, at: start.addingTimeInterval(60 + 301))
        let pending = FeedbackConversation.OutgoingMessage(
            id: UUID(),
            content: "还在吗",
            createdAt: start.addingTimeInterval(60 + 301 + 10),
            isFailed: false
        )

        let rows = FeedbackTimeline.rows(messages: [first, second, third], outgoing: [pending])
        #expect(rows == [
            .time(first.createdAt), .message(first), .message(second),
            .time(third.createdAt), .message(third), .outgoing(pending),
        ])
        #expect(FeedbackTimeline.rows(messages: [], outgoing: []).isEmpty)
    }

    @Test("反馈文案有中英文，登录页说明对应反馈原因")
    func localizesFeedbackStrings() {
        let keys = [
            "feedback.title", "feedback.row.unread", "feedback.signIn.message", "feedback.welcome",
            "feedback.input.placeholder", "feedback.input.overflow", "feedback.send", "feedback.loadOlder",
            "feedback.load.failed", "feedback.retry", "feedback.message.failed", "feedback.message.resend",
            "feedback.message.delete", "feedback.sender.me", "feedback.error.rateLimited", "feedback.error.network",
            "feedback.error.unavailable", "feedback.error.sessionExpired",
        ]
        for locale in [Locale(identifier: "en"), Locale(identifier: "zh-Hans")] {
            for key in keys {
                #expect(AccountLocalization.string(key, locale: locale) != key, "\(locale.identifier) 缺少 \(key)")
            }
        }
        #expect(AccountLocalization.formatted("feedback.row.unread", value: "2", locale: Locale(identifier: "zh-Hans")) == "2 条新回复")
        #expect(SignInReason.feedback.messageLocalizationKey == "feedback.signIn.message")
    }

    // MARK: - 辅助

    /// 测试用的设备信息。
    private static let clientInfo = FeedbackClientInfo(
        appVersion: "1.0 (1)",
        osVersion: "iOS 27.1",
        deviceModel: "iPhone18,1",
        locale: "zh-Hans"
    )

    /// 构造一条已保存的消息；时间默认按序号递增，彼此相隔 1 秒。
    private static func message(_ seq: Int64, sender: FeedbackSender = .user, at date: Date? = nil) -> FeedbackMessage {
        FeedbackMessage(
            seq: seq,
            sender: sender,
            content: "消息 \(seq)",
            createdAt: date ?? Date(timeIntervalSince1970: 1_793_329_380 + Double(seq))
        )
    }
}

/// 可变的当前账号，模拟登录、换账号与退出登录。
@MainActor
private final class UserBox {
    /// 当前登录账号；未登录时为 nil。
    var id: String?

    init(_ id: String?) {
        self.id = id
    }
}

/// 意见反馈接口的假实现。
@MainActor
private final class FakeFeedbackAPI: FeedbackServing {
    /// 按 before 游标返回的消息页；游标为 nil 表示最新一页。
    var pages: [Int64?: Result<FeedbackMessagePage, FeedbackAPIError>] = [:]

    /// 依次返回的发送结果；用完后按请求回显成功，序号递增。
    var sendResults: [Result<FeedbackMessage, FeedbackAPIError>] = []

    /// 标记已读的结果（推进后的未读数）。
    var markReadResult: Result<Int, FeedbackAPIError> = .success(0)

    /// 依次返回的未读数；用完后重复最后一个。
    var unreadResults: [Result<Int, FeedbackAPIError>] = [.success(0)]

    /// 设置后查询未读数时先挂起，直到用例恢复。
    var unreadGate: AsyncSaveGate?

    /// 回显成功时使用的下一个序号。
    private var nextSeq: Int64 = 100

    /// 依次发出的发送请求。
    private(set) var sentRequests: [FeedbackSendRequest] = []

    /// 依次标记已读的位置。
    private(set) var markedReadSeqs: [Int64] = []

    /// 依次请求过的 before 游标。
    private(set) var requestedBefore: [Int64?] = []

    /// 查询未读数的次数。
    private(set) var unreadCalls = 0

    func fetchMessages(before: Int64?) async throws -> FeedbackMessagePage {
        requestedBefore.append(before)
        guard let result = pages[before] else { throw FeedbackAPIError.invalidContract }
        return try result.get()
    }

    func send(_ request: FeedbackSendRequest) async throws -> FeedbackMessage {
        sentRequests.append(request)
        if !sendResults.isEmpty {
            return try sendResults.removeFirst().get()
        }
        nextSeq += 1
        return FeedbackMessage(
            id: request.id,
            seq: nextSeq,
            sender: .user,
            content: request.content,
            createdAt: Date(timeIntervalSince1970: 1_793_329_380 + Double(nextSeq))
        )
    }

    func markRead(upTo seq: Int64) async throws -> Int {
        markedReadSeqs.append(seq)
        return try markReadResult.get()
    }

    func fetchUnreadCount() async throws -> Int {
        let index = min(unreadCalls, unreadResults.count - 1)
        unreadCalls += 1
        if let unreadGate {
            await unreadGate.wait()
        }
        return try unreadResults[index].get()
    }
}
