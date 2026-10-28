import Foundation
import SwiftData
import Testing
@testable import yadoA

/// 用假接口驱动语音记账会话循环：本地结束本轮、追问、失败处理、撤销与闲置结束。
@Suite("语音记账会话", .serialized)
@MainActor
struct VoiceSessionTests {
    @Test("canFinishLocally 且全部成功时只请求一次，在本地生成结果并追加为 assistant 事件")
    func finishesLocallyWithSingleRequest() async throws {
        let fixture = try Fixture()
        fixture.api.responses = [.success(.toolCalls([fixture.createCall("c1", amount: "28", note: "午饭")], canFinishLocally: true))]
        _ = HomeRecentEntryHighlight.shared.consume()
        // 用户正看着首页时语音记账才登记首页提示
        HomeRecentEntryHighlight.shared.homeDidAppear()
        defer { HomeRecentEntryHighlight.shared.homeDidDisappear() }

        await fixture.session.send("  午饭 28  ")

        #expect(fixture.api.requests.count == 1)
        let request = try #require(fixture.api.requests.first)
        #expect(request.locale == "zh-Hans")
        #expect(request.events == [.user(text: "午饭 28", selectedOptionId: nil)])
        #expect(request.accounts.map(\.isActive) == [true, false])
        #expect(request.defaultAccountId == nil)

        let turn = try #require(fixture.session.latestTurn)
        guard case let .reply(text) = turn.outcome else {
            Issue.record("应在本地结束本轮")
            return
        }
        #expect(text.contains("午饭"))
        #expect(turn.changes.count == 1)
        #expect(fixture.session.events.count == 4)
        #expect(fixture.session.events.last == .assistant(text: text))
        #expect(!fixture.session.isProcessing)
        #expect(try fixture.balance() == 72)
        #expect(HomeRecentEntryHighlight.shared.consume().count == 1)
    }

    @Test("不能本地结束时带结果继续请求，直到追问")
    func continuesUntilAsk() async throws {
        let fixture = try Fixture()
        fixture.api.responses = [
            .success(.toolCalls([fixture.createCall("c1", amount: "28")], canFinishLocally: false)),
            .success(.ask(question: "打车花了多少钱？", options: [])),
        ]

        await fixture.session.send("午饭 28，还打了车")

        #expect(fixture.api.requests.count == 2)
        let second = try #require(fixture.api.requests.last)
        guard case .toolResult? = second.events.last else {
            Issue.record("第二次请求应以执行结果结尾")
            return
        }
        #expect(fixture.session.latestTurn?.outcome == .ask(question: "打车花了多少钱？", options: []))
        #expect(fixture.session.latestTurn?.offersManualEntry == true)
        #expect(fixture.session.events.last == .assistant(text: "打车花了多少钱？"))
    }

    @Test("随调用下发的追问：全部成功时只请求一次，直接显示追问")
    func followUpAskEndsTurnWithoutRequest() async throws {
        let fixture = try Fixture()
        fixture.api.responses = [.success(.toolCalls(
            [fixture.createCall("c1", amount: "28", note: "午饭")],
            canFinishLocally: false,
            followUpAsk: VoiceFollowUpAsk(question: "打车花了多少钱？")
        ))]

        await fixture.session.send("午饭 28，打车")

        #expect(fixture.api.requests.count == 1)
        let turn = try #require(fixture.session.latestTurn)
        #expect(turn.outcome == .ask(question: "打车花了多少钱？", options: []))
        #expect(turn.changes.count == 1)
        #expect(fixture.session.events.count == 4)
        #expect(fixture.session.events.last == .assistant(text: "打车花了多少钱？"))
        #expect(try fixture.balance() == 72)
        #expect(!fixture.session.isProcessing)
    }

    @Test("随调用下发追问但有调用失败时忽略追问，带结果继续请求")
    func followUpAskIgnoredOnFailure() async throws {
        let fixture = try Fixture()
        let inactiveCall = VoiceToolCall.createTransaction(id: "c1", input: VoiceCreateTransactionInput(
            type: .expense, amount: "28", accountId: fixture.inactiveAccountID.uuidString, categoryId: "dining",
            date: "2026-10-20", note: nil, inferredFields: []
        ))
        fixture.api.responses = [
            .success(.toolCalls(
                [inactiveCall],
                canFinishLocally: false,
                followUpAsk: VoiceFollowUpAsk(question: "打车花了多少钱？")
            )),
            .success(.reply(text: "这个账户已停用")),
        ]

        await fixture.session.send("午饭 28 用旧卡，打车")

        #expect(fixture.api.requests.count == 2)
        #expect(fixture.session.latestTurn?.outcome == .reply("这个账户已停用"))
    }

    @Test("工具执行失败时即使允许本地结束也要继续请求，让模型告知用户")
    func toolFailureRequiresFollowUp() async throws {
        let fixture = try Fixture()
        let inactiveCall = VoiceToolCall.createTransaction(id: "c1", input: VoiceCreateTransactionInput(
            type: .expense, amount: "28", accountId: fixture.inactiveAccountID.uuidString, categoryId: "dining",
            date: "2026-10-20", note: nil, inferredFields: []
        ))
        fixture.api.responses = [
            .success(.toolCalls([inactiveCall], canFinishLocally: true)),
            .success(.reply(text: "这个账户已停用")),
        ]

        await fixture.session.send("午饭 28 用旧卡")

        #expect(fixture.api.requests.count == 2)
        #expect(fixture.session.latestTurn?.outcome == .reply("这个账户已停用"))
        #expect(fixture.session.latestTurn?.changes.isEmpty == true)
    }

    @Test("还没写入就失败时移出本轮事件，可以重说")
    func failureBeforeWriteDropsTurnEvents() async throws {
        let fixture = try Fixture()
        fixture.api.responses = [.failure(.rateLimited(isDaily: true))]

        await fixture.session.send("午饭 28")

        let turn = try #require(fixture.session.latestTurn)
        #expect(turn.outcome == .failed(.rateLimited(isDaily: true)))
        #expect(!turn.isInContext)
        #expect(fixture.session.events.isEmpty)
        #expect(fixture.session.undoableTurn == nil)
    }

    @Test("计费轮次 ID：同一句的续步沿用，回答追问时换新的")
    func reusesBillingTurnIDWithinSentence() async throws {
        let fixture = try Fixture()
        fixture.api.responses = [
            .success(.toolCalls([fixture.createCall("c1", amount: "28")], canFinishLocally: false)),
            .success(.ask(question: "打车花了多少钱？", options: [])),
            .success(.toolCalls([fixture.createCall("c2", amount: "25")], canFinishLocally: true)),
        ]

        await fixture.session.send("午饭 28，还打了车")
        await fixture.session.send("25")

        let turnIDs = fixture.api.turnIDs
        #expect(turnIDs.count == 3)
        #expect(turnIDs[0] == turnIDs[1])
        #expect(turnIDs[2] != turnIDs[0])
    }

    @Test("点数不足时不改动数据，移出本轮事件，可以手动记账或重说")
    func insufficientPointsDropsTurn() async throws {
        let fixture = try Fixture()
        fixture.api.responses = [.failure(.insufficientPoints)]

        await fixture.session.send("午饭 28")

        let turn = try #require(fixture.session.latestTurn)
        #expect(turn.outcome == .failed(.insufficientPoints))
        #expect(turn.offersManualEntry)
        #expect(!turn.isInContext)
        #expect(fixture.session.events.isEmpty)
        #expect(try fixture.balance() == 100)
    }

    @Test("已经写入后请求失败时保留写入，按已执行内容提示结果")
    func failureAfterWriteKeepsChanges() async throws {
        let fixture = try Fixture()
        fixture.api.responses = [
            .success(.toolCalls([fixture.createCall("c1", amount: "28", note: "午饭")], canFinishLocally: false)),
            .failure(.timeout),
        ]

        await fixture.session.send("午饭 28")

        let turn = try #require(fixture.session.latestTurn)
        guard case let .reply(text) = turn.outcome else {
            Issue.record("应按已执行内容提示")
            return
        }
        #expect(text.contains("午饭"))
        #expect(try fixture.balance() == 72)
        #expect(fixture.session.events.last == .assistant(text: text))
        #expect(fixture.session.undoableTurn?.id == turn.id)
    }

    @Test("撤销一轮回滚全部写入，并把本轮事件移出会话记录")
    func undoRevertsTurn() async throws {
        let fixture = try Fixture()
        fixture.api.responses = [.success(.toolCalls([
            fixture.createCall("c1", amount: "28"),
            fixture.createCall("c2", amount: "35"),
        ], canFinishLocally: true))]
        await fixture.session.send("午饭 28，打车 35")
        #expect(try fixture.balance() == 37)

        fixture.session.undoLatestTurn()

        #expect(try fixture.balance() == 100)
        #expect(try ModelContext(fixture.container).fetchCount(FetchDescriptor<AccountTransaction>()) == 0)
        #expect(fixture.session.events.isEmpty)
        #expect(fixture.session.latestTurn?.isUndone == true)
        #expect(fixture.session.undoableTurn == nil)
        #expect(fixture.session.activeChanges.isEmpty)
        #expect(!fixture.session.hasUndoFailure)
    }

    @Test("闲置超过 2 分钟后结束会话；结束后清空记录")
    func endsWhenIdle() async throws {
        let fixture = try Fixture()
        fixture.api.responses = [.success(.reply(text: "我只能帮你记账"))]
        await fixture.session.send("你好")
        #expect(fixture.session.isActive)

        fixture.clock.date = fixture.clock.date.addingTimeInterval(60)
        fixture.session.endIfIdle()
        #expect(fixture.session.isActive)

        fixture.clock.date = fixture.clock.date.addingTimeInterval(VoiceSession.idleTimeout)
        fixture.session.endIfIdle()
        #expect(!fixture.session.isActive)
        #expect(fixture.session.events.isEmpty)
    }

    @Test("空白输入不发送")
    func ignoresBlankInput() async throws {
        let fixture = try Fixture()
        await fixture.session.send("   ")
        #expect(fixture.api.requests.isEmpty)
        #expect(!fixture.session.isActive)
    }

    @Test("本地结果提示按新增、修改、删除分段")
    func summaryText() {
        let locale = Locale(identifier: "zh-Hans")
        func change(_ kind: VoiceEntryChange.Kind, _ label: String) -> VoiceChange {
            .entry(VoiceEntryChange(
                kind: kind, transactionID: UUID(), transactionDay: 20261020, row: nil, accountName: nil, label: label,
                formattedAmount: "¥1.00", inferredFields: [], inverse: .delete(UUID()), highlight: nil
            ))
        }
        let text = VoiceSessionSummary.text(
            for: [change(.created, "午饭"), change(.created, "打车"), change(.deleted, "奶茶")],
            locale: locale
        )
        #expect(text.contains("2"))
        #expect(text.contains("午饭"))
        #expect(text.contains("打车"))
        #expect(text.contains("奶茶"))
        #expect(VoiceSessionSummary.text(for: [], locale: locale).isEmpty == false)
    }

    @Test("每句记录耗时：请求带句序号与请求序号，结束会话后重新编号")
    func recordsTurnTiming() async throws {
        let fixture = try Fixture()
        fixture.api.responses = [
            .success(.toolCalls([fixture.createCall("c1", amount: "28")], canFinishLocally: false)),
            .success(.reply(text: "已记 1 笔")),
            .success(.reply(text: "好的")),
        ]

        await fixture.session.send("午饭 28", speechFinalizeDuration: .milliseconds(180))
        await fixture.session.send("没事了")

        let traces = fixture.api.traces
        #expect(traces.map(\.turn) == [1, 1, 2])
        #expect(traces.map(\.request) == [1, 2, 1])
        #expect(Set(traces.map(\.sessionID)).count == 1)

        let first = try #require(fixture.session.turns.first?.timing)
        #expect(first.turnIndex == 1)
        #expect(first.outcome == .reply)
        #expect(first.speechFinalizeMs == 180)
        #expect(first.requests.map(\.outcome) == [.toolCalls, .reply])
        #expect(first.requests.first?.toolCallCount == 1)
        #expect(first.requests.first?.executionMs != nil)
        #expect(first.requests.last?.executionMs == nil)
        #expect(first.requests.first?.server?.totalMs == 2104)
        #expect(first.requests.first?.requestID == "req-1")
        #expect(first.totalMs >= 180)
        #expect(fixture.session.turns.last?.timing?.speechFinalizeMs == nil)
        #expect(fixture.timingStore.records.map(\.turnIndex) == [1, 2])

        fixture.session.end()
        fixture.api.responses = [.failure(.serviceUnavailable)]
        await fixture.session.send("午饭 28")

        let afterEnd = try #require(fixture.api.traces.last)
        #expect(afterEnd.turn == 1)
        #expect(afterEnd.sessionID != traces[0].sessionID)
        let failed = try #require(fixture.session.latestTurn?.timing)
        #expect(failed.outcome == .failed)
        #expect(failed.requests.map(\.outcome) == [.failed])
    }

    // MARK: - 辅助

    /// 一次测试使用的容器、账户、时钟与假接口。
    @MainActor
    private final class Fixture {
        let container: ModelContainer
        let accountID: UUID
        let inactiveAccountID: UUID
        let api: FakeVoiceSessionAPI
        let clock: TestClock
        let timingStore = VoiceTimingStore(fileURL: nil)
        let session: VoiceSession

        init() throws {
            container = try AccountDataContainer.inMemory().modelContainer
            let context = ModelContext(container)
            let active = Account(
                id: UUID(), typeRawValue: AccountType.cash.rawValue, templateID: nil, name: "现金",
                note: nil, lastFourDigits: nil, balance: 100, currencyCode: "CNY",
                createdAt: Date(timeIntervalSince1970: 1), updatedAt: .now
            )
            let inactive = Account(
                id: UUID(), typeRawValue: AccountType.cash.rawValue, templateID: nil, name: "旧卡",
                note: nil, lastFourDigits: nil, balance: 0, currencyCode: "CNY",
                createdAt: Date(timeIntervalSince1970: 0), updatedAt: .now, deactivatedAt: .now
            )
            context.insert(active)
            context.insert(inactive)
            try context.save()
            accountID = active.id
            inactiveAccountID = inactive.id

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let api = FakeVoiceSessionAPI()
            let clock = TestClock()
            self.api = api
            self.clock = clock
            session = VoiceSession(
                container: container,
                api: api,
                locale: Locale(identifier: "zh-Hans"),
                calendar: calendar,
                timingStore: timingStore,
                now: { clock.date }
            )
        }

        func createCall(_ id: String, amount: String, note: String? = nil) -> VoiceToolCall {
            .createTransaction(id: id, input: VoiceCreateTransactionInput(
                type: .expense, amount: amount, accountId: accountID.uuidString, categoryId: "dining",
                date: "2026-10-20", note: note, inferredFields: []
            ))
        }

        func balance() throws -> Decimal {
            try #require(ModelContext(container).fetch(FetchDescriptor<Account>()).first { $0.id == accountID }).balance
        }
    }
}

/// 可手动推进的时钟。
@MainActor
private final class TestClock {
    /// 当前时间。
    var date = Date(timeIntervalSince1970: 1_792_470_600)
}

/// 按顺序返回预设响应、记录每次请求的假接口；预设用完后视为服务不可用。
@MainActor
private final class FakeVoiceSessionAPI: VoiceSessionTurnSending {
    /// 依次返回的响应。
    var responses: [Result<VoiceSessionTurnResponse, VoiceSessionAPIError>] = []

    /// 收到的请求。
    private(set) var requests: [VoiceSessionTurnRequest] = []

    /// 每次请求的追踪信息。
    private(set) var traces: [VoiceRequestTrace] = []

    /// 每次请求带的计费轮次 ID。
    private(set) var turnIDs: [UUID] = []

    /// 每次请求填回的服务端耗时，模拟响应头中的 `Server-Timing`。
    var serverTiming = "pre;dur=1.2, prepare;dur=0.4, ttft-1;dur=900, gen-1;dur=1200;desc=\"in=3000 out=96\", check-1;dur=2, total;dur=2104"

    func send(_ request: VoiceSessionTurnRequest, turnID: UUID, trace: VoiceRequestTrace) async throws -> VoiceSessionTurnResponse {
        requests.append(request)
        traces.append(trace)
        turnIDs.append(turnID)
        trace.server = VoiceServerTiming.parse(serverTiming)
        trace.requestID = "req-\(traces.count)"
        guard !responses.isEmpty else { throw VoiceSessionAPIError.serviceUnavailable }
        return try responses.removeFirst().get()
    }
}
