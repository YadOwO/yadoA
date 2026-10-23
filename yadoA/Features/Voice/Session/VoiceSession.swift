import Foundation
import Observation
import os
import SwiftData

/// 一轮无法完成时的原因，界面据此给出提示和后续操作。
enum VoiceSessionFailure: Equatable {
    /// 需要先登录。
    case signInRequired

    /// 登录已失效，需要重新登录。
    case sessionExpired

    /// 超过调用限额；`isDaily` 为真表示当天的次数已用完。
    case rateLimited(isDaily: Bool)

    /// 会话内容过长，需要结束后重新开始。
    case sessionTooLong

    /// AI 服务暂时不可用或请求超时。
    case serviceUnavailable

    /// 网络不可用。
    case network
}

/// 一次语音记账会话：维护发给 AI 服务的事件记录，在本地执行工具调用，并支持逐轮撤销。
///
/// 规则见 `docs/rules/voice-bookkeeping-session-rules.md`。服务端不保存会话，每一步都发送全部事件。
@MainActor
@Observable
final class VoiceSession {
    /// 一轮对话：用户说的一句话，以及它带来的结果与流水变更。
    struct Turn: Identifiable, Equatable {
        /// 一轮的处理结果。
        enum Outcome: Equatable {
            /// 正在处理。
            case processing

            /// 本轮回复。
            case reply(String)

            /// 追问，等待用户回答；可能带候选项。
            case ask(question: String, options: [VoiceAskOption])

            /// 本轮没有完成。
            case failed(VoiceSessionFailure)
        }

        /// 稳定标识。
        let id = UUID()

        /// 用户说的话（或点选的候选项文字）。
        let userText: String

        /// 处理结果。
        var outcome: Outcome = .processing

        /// 本轮成功写入的流水变更，按执行顺序排列。
        var changes: [VoiceEntryChange] = []

        /// 本轮是否已被撤销。
        var isUndone = false

        /// 本轮的事件是否仍在会话记录中；失败且没有写入的轮次、已撤销的轮次会被移出。
        var isInContext = true

        /// 本轮第一条事件在会话记录中的位置。
        let eventStartIndex: Int

        /// 本轮的耗时；处理结束后才有。
        var timing: VoiceTurnTiming?

        /// 本轮最终展示给用户的文字：回复、追问或空。
        var displayText: String? {
            switch outcome {
            case let .reply(text): text
            case let .ask(question, _): question
            case .processing, .failed: nil
            }
        }
    }

    /// 超过该时长没有新的一轮，会话自动结束。
    static let idleTimeout: TimeInterval = 120

    /// 一轮最多发送的请求数，防止服务端异常时无限循环。
    static let maxRequestsPerTurn = 10

    /// 本次会话的全部轮次，包括已撤销和失败的，按时间顺序排列。
    private(set) var turns: [Turn] = []

    /// 发给 AI 服务的事件记录。
    private(set) var events: [VoiceSessionEvent] = []

    /// 是否正在处理一轮。
    private(set) var isProcessing = false

    /// 最近一轮结束的时间，用于判断会话是否已闲置。
    private(set) var lastActivityAt: Date?

    /// 最近一次撤销失败；界面展示提示后清除。
    var hasUndoFailure = false

    /// 每次结束会话递增；等待网络期间会话被结束时，用它丢弃过期的结果。
    private var generation = 0

    /// 会话标识，随请求头发给服务端，服务端日志据此把同一会话的请求串起来；结束会话后重新生成。
    private var sessionID = UUID()

    /// 本会话已经处理的句数，作为句序号随请求头发给服务端。
    private var turnCount = 0

    private let container: ModelContainer
    private let api: VoiceSessionTurnSending
    private let highlight: HomeRecentEntryHighlight
    private let now: () -> Date
    /// 写入「语音耗时」的记录；非本地开发包为空，不保存耗时。
    private let timingStore: VoiceTimingStore?

    /// 界面语言，决定分类名称、结果提示和 AI 回复的语言。
    var locale: Locale

    /// 记账日换算使用的日历。
    var calendar: Calendar

    /// 创建会话。
    ///
    /// - Parameters:
    ///   - container: 应用持有的本地财务容器。
    ///   - api: 会话接口。
    ///   - locale: 界面语言。
    ///   - calendar: 记账日使用的日历。
    ///   - highlight: 首页变更提示通道。
    ///   - timingStore: 耗时记录；为空时本地开发包使用 App 共用的记录，其他包不保存。
    ///   - now: 时间源。
    init(
        container: ModelContainer,
        api: VoiceSessionTurnSending,
        locale: Locale = .current,
        calendar: Calendar = .current,
        highlight: HomeRecentEntryHighlight = .shared,
        timingStore: VoiceTimingStore? = nil,
        now: @escaping () -> Date = { .now }
    ) {
        self.container = container
        self.api = api
        self.locale = locale
        self.calendar = calendar
        self.highlight = highlight
        // 默认参数在非隔离上下文中求值，碰不到主线程隔离的共用记录，所以在初始化体内取默认值
        self.timingStore = timingStore ?? (VoiceTimingFeature.isEnabled ? .shared : nil)
        self.now = now
    }

    /// 会话是否有内容（会话卡片需要展示）。
    var isActive: Bool { !turns.isEmpty }

    /// 最近的一轮。
    var latestTurn: Turn? { turns.last }

    /// 可以撤销的一轮：仍在会话记录中的最后一轮，且有写入。
    var undoableTurn: Turn? {
        guard !isProcessing, let turn = turns.last(where: \.isInContext), !turn.changes.isEmpty else { return nil }
        return turn
    }

    /// 本会话中仍然有效的流水变更（不含已撤销的轮次）。
    var activeChanges: [VoiceEntryChange] {
        turns.filter { !$0.isUndone }.flatMap(\.changes)
    }

    /// 读取当前上下文，供语音识别取专有名词。
    func currentContext() -> VoiceSessionContext {
        VoiceSessionContext.make(container: container, locale: locale)
    }

    /// 发送用户的一句话并处理到本轮结束。
    ///
    /// - Parameters:
    ///   - rawText: 语音转写或输入的文字；去掉首尾空白后为空时忽略。
    ///   - selectedOption: 回答追问时点选的候选项。
    ///   - speechFinalizeDuration: 松手到拿到最终识别文字的耗时，计入本轮耗时；点选候选项时为空。
    func send(
        _ rawText: String,
        selectedOption: VoiceAskOption? = nil,
        speechFinalizeDuration: Duration? = nil
    ) async {
        let text = String(
            rawText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(VoiceSessionLimits.maxUserTextLength)
        )
        guard !isProcessing, !text.isEmpty else { return }
        endIfIdle()

        let turnGeneration = generation
        let turnID = appendTurn(Turn(userText: text, eventStartIndex: events.count))
        // 追加用户这句话后，还要给服务端的追问或工具调用留出空间
        guard events.count + 2 <= VoiceSessionLimits.maxEvents else {
            finishTurn(turnID, failure: .sessionTooLong)
            return
        }
        isProcessing = true
        defer {
            if turnGeneration == generation {
                isProcessing = false
                lastActivityAt = now()
            }
        }
        turnCount += 1
        let turnIndex = turnCount
        let turnStartedAt = VoiceTimingClock.now
        let signposter = VoiceTimingLog.signposter
        let turnSignpost = signposter.beginInterval("VoiceTurn", id: signposter.makeSignpostID(), "turn \(turnIndex)")
        var requestTimings: [VoiceRequestTiming] = []
        // 每个返回点都要记下本轮耗时；会话已结束的不再记
        defer {
            signposter.endInterval("VoiceTurn", turnSignpost)
            if turnGeneration == generation {
                recordTiming(
                    turnID,
                    turnIndex: turnIndex,
                    speechFinalizeDuration: speechFinalizeDuration,
                    processingMs: VoiceTimingClock.milliseconds(since: turnStartedAt),
                    requests: requestTimings
                )
            }
        }
        events.append(.user(text: text, selectedOptionId: selectedOption?.id))

        let executor = VoiceToolExecutor(container: container, locale: locale, calendar: calendar, now: now)
        do {
            for requestIndex in 1...Self.maxRequestsPerTurn {
                let requestStartedAt = VoiceTimingClock.now
                let request = makeRequest()
                let buildMs = VoiceTimingClock.milliseconds(since: requestStartedAt)
                let trace = VoiceRequestTrace(sessionID: sessionID.uuidString, turn: turnIndex, request: requestIndex)
                let requestSignpost = signposter.beginInterval(
                    "VoiceRequest", id: signposter.makeSignpostID(), "request \(requestIndex)"
                )
                let response: VoiceSessionTurnResponse
                do {
                    response = try await api.send(request, trace: trace)
                } catch {
                    signposter.endInterval("VoiceRequest", requestSignpost)
                    requestTimings.append(Self.requestTiming(trace, outcome: .failed, buildMs: buildMs, startedAt: requestStartedAt))
                    throw error
                }
                signposter.endInterval("VoiceRequest", requestSignpost)
                requestTimings.append(Self.requestTiming(
                    trace, outcome: response.timingOutcome, buildMs: buildMs, startedAt: requestStartedAt
                ))
                // 等待期间会话已结束（例如离开记账页），结果不再展示
                guard turnGeneration == generation else { return }
                switch response {
                case let .toolCalls(calls, canFinishLocally, followUpAsk):
                    let executionStartedAt = VoiceTimingClock.now
                    let executionSignpost = signposter.beginInterval("VoiceExecute", id: signposter.makeSignpostID())
                    var isAllSucceeded = true
                    for call in calls {
                        let execution = executor.execute(call)
                        events.append(.toolCall(call))
                        events.append(.toolResult(execution.result))
                        isAllSucceeded = isAllSucceeded && execution.result.output.isSuccess
                        if let change = execution.change {
                            updateTurn(turnID) { $0.changes.append(change) }
                            if let entryHighlight = change.highlight {
                                highlight.mark(entryHighlight)
                            }
                        }
                    }
                    signposter.endInterval("VoiceExecute", executionSignpost)
                    requestTimings[requestTimings.count - 1].toolCallCount = calls.count
                    requestTimings[requestTimings.count - 1].executionMs = VoiceTimingClock.milliseconds(since: executionStartedAt)
                    // 随调用下发的追问：全部成功时直接显示，不必为同一个问题再请求一次
                    if let followUpAsk, isAllSucceeded {
                        askUser(turnID, question: followUpAsk.question, options: followUpAsk.options)
                        return
                    }
                    if canFinishLocally, isAllSucceeded {
                        finishTurnLocally(turnID)
                        return
                    }
                case let .ask(question, options):
                    askUser(turnID, question: question, options: options)
                    return
                case let .reply(text):
                    events.append(.assistant(text: String(text.prefix(VoiceSessionLimits.maxAssistantTextLength))))
                    updateTurn(turnID) { $0.outcome = .reply(text) }
                    return
                }
            }
            finishTurn(turnID, failure: .serviceUnavailable)
        } catch {
            guard turnGeneration == generation else { return }
            finishTurn(turnID, failure: Self.failure(for: error))
        }
    }

    /// 撤销最近一轮的全部写入，并把这一轮移出会话记录，模型不会再引用已撤销的流水。
    ///
    /// 失败时数据保持撤销前的状态，`hasUndoFailure` 置为真。
    func undoLatestTurn() {
        guard let turn = undoableTurn else { return }
        let executor = VoiceToolExecutor(container: container, locale: locale, calendar: calendar, now: now)
        do {
            let highlights = try executor.revert(turn.changes)
            for entryHighlight in highlights {
                highlight.mark(entryHighlight)
            }
        } catch {
            hasUndoFailure = true
            return
        }
        events.removeSubrange(turn.eventStartIndex...)
        updateTurn(turn.id) {
            $0.isUndone = true
            $0.isInContext = false
        }
        lastActivityAt = now()
    }

    /// 结束会话：清空记录。等待中的请求返回后会被丢弃，已写入的流水保留。
    func end() {
        generation += 1
        sessionID = UUID()
        turnCount = 0
        turns = []
        events = []
        isProcessing = false
        lastActivityAt = nil
        hasUndoFailure = false
    }

    /// 闲置超过 `idleTimeout` 时结束会话。
    func endIfIdle() {
        guard !isProcessing, let lastActivityAt, now().timeIntervalSince(lastActivityAt) >= Self.idleTimeout
        else { return }
        end()
    }

    // MARK: - 私有方法

    /// 生成本步请求。
    private func makeRequest() -> VoiceSessionTurnRequest {
        let context = currentContext()
        return VoiceSessionTurnRequest(
            locale: VoiceSessionContext.localeCode(for: locale),
            now: VoiceSessionContext.timestamp(now(), timeZone: calendar.timeZone),
            defaultAccountId: context.defaultAccountID,
            accounts: context.accounts,
            categories: context.categories,
            events: events
        )
    }

    /// 由追踪信息生成一次请求的耗时。
    ///
    /// - Parameters:
    ///   - trace: 网络层填回的耗时。
    ///   - outcome: 这次请求的结果。
    ///   - buildMs: 组装请求的耗时。
    ///   - startedAt: 开始组装请求的时刻。
    /// - Returns: 一次请求的耗时。
    private static func requestTiming(
        _ trace: VoiceRequestTrace,
        outcome: VoiceRequestTiming.Outcome,
        buildMs: Double,
        startedAt: ContinuousClock.Instant
    ) -> VoiceRequestTiming {
        VoiceRequestTiming(
            index: trace.request,
            durationMs: VoiceTimingClock.milliseconds(since: startedAt),
            buildMs: buildMs,
            tokenMs: trace.tokenMs,
            transportMs: trace.transportMs,
            network: trace.network,
            server: trace.server,
            requestID: trace.requestID,
            statusCode: trace.statusCode,
            outcome: outcome
        )
    }

    /// 记下本轮耗时：挂到这一轮上供卡片显示，写系统日志，可见时存入耗时记录。
    ///
    /// - Parameters:
    ///   - id: 本轮标识。
    ///   - turnIndex: 会话中的第几句。
    ///   - speechFinalizeDuration: 松手到拿到最终识别文字的耗时。
    ///   - processingMs: 开始处理到本轮结束的耗时。
    ///   - requests: 本轮的全部请求。
    private func recordTiming(
        _ id: UUID,
        turnIndex: Int,
        speechFinalizeDuration: Duration?,
        processingMs: Double,
        requests: [VoiceRequestTiming]
    ) {
        guard let turn = turns.first(where: { $0.id == id }) else { return }
        let outcome: VoiceTurnTiming.Outcome = switch turn.outcome {
        case .ask: .ask
        case .failed: .failed
        case .reply, .processing: .reply
        }
        let timing = VoiceTurnTiming(
            id: id,
            recordedAt: now(),
            sessionID: sessionID.uuidString,
            turnIndex: turnIndex,
            speechFinalizeMs: speechFinalizeDuration.map { VoiceTimingClock.milliseconds($0) },
            processingMs: processingMs,
            requests: requests,
            outcome: outcome
        )
        updateTurn(id) { $0.timing = timing }
        VoiceTimingLog.log(timing)
        timingStore?.append(timing)
    }

    private func appendTurn(_ turn: Turn) -> UUID {
        turns.append(turn)
        return turn.id
    }

    private func updateTurn(_ id: UUID, _ mutation: (inout Turn) -> Void) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        mutation(&turns[index])
    }

    /// 以追问结束本轮：问题追加为 assistant 事件，等待用户下一轮回答。
    ///
    /// - Parameters:
    ///   - id: 本轮标识。
    ///   - question: 要问用户的问题。
    ///   - options: 供用户点选的候选项。
    private func askUser(_ id: UUID, question: String, options: [VoiceAskOption]) {
        events.append(.assistant(text: String(question.prefix(VoiceSessionLimits.maxAssistantTextLength))))
        updateTurn(id) { $0.outcome = .ask(question: question, options: options) }
    }

    /// 本步全部写入成功且服务端允许时，在本地生成结果提示并结束本轮，省去一次请求。
    private func finishTurnLocally(_ id: UUID) {
        guard let turn = turns.first(where: { $0.id == id }) else { return }
        let summary = VoiceSessionSummary.text(for: turn.changes, locale: locale)
        events.append(.assistant(text: String(summary.prefix(VoiceSessionLimits.maxAssistantTextLength))))
        updateTurn(id) { $0.outcome = .reply(summary) }
    }

    /// 本轮无法完成：还没写入时把本轮移出会话记录，可以重说；已经写入时保留写入并按已执行的内容提示。
    private func finishTurn(_ id: UUID, failure: VoiceSessionFailure) {
        guard let turn = turns.first(where: { $0.id == id }) else { return }
        if turn.changes.isEmpty {
            if events.count > turn.eventStartIndex {
                events.removeSubrange(turn.eventStartIndex...)
            }
            updateTurn(id) {
                $0.outcome = .failed(failure)
                $0.isInContext = false
            }
        } else {
            finishTurnLocally(id)
        }
    }

    /// 把接口错误映射为界面提示。
    private static func failure(for error: Error) -> VoiceSessionFailure {
        switch error as? VoiceSessionAPIError {
        case .notSignedIn: .signInRequired
        case .sessionExpired, .unauthorized: .sessionExpired
        case let .rateLimited(isDaily): .rateLimited(isDaily: isDaily)
        case .sessionTooLong: .sessionTooLong
        case .network: .network
        case .serviceUnavailable, .timeout, .invalidContract, nil: .serviceUnavailable
        }
    }
}

/// 在本地生成一轮的结果提示，例如「已记 2 笔：午饭 ¥28.00、打车 ¥35.00」。
enum VoiceSessionSummary {
    /// 生成结果提示。
    ///
    /// - Parameters:
    ///   - changes: 本轮的流水变更，按执行顺序排列。
    ///   - locale: 文案使用的语言环境。
    /// - Returns: 本地化提示；没有变更时为「这句话我没能处理」一类的兜底文案。
    static func text(for changes: [VoiceEntryChange], locale: Locale) -> String {
        let listFormatter = ListFormatter()
        listFormatter.locale = locale
        func items(_ kind: VoiceEntryChange.Kind) -> [String] {
            changes.filter { $0.kind == kind }.map { "\($0.label) \($0.formattedAmount)" }
        }
        func list(_ items: [String]) -> String {
            listFormatter.string(from: items) ?? items.joined(separator: ", ")
        }
        var parts: [String] = []
        let created = items(.created)
        if !created.isEmpty {
            parts.append(String(
                format: AccountLocalization.string("voice.summary.created", locale: locale),
                locale: locale,
                created.count,
                list(created)
            ))
        }
        let updated = items(.updated)
        if !updated.isEmpty {
            parts.append(AccountLocalization.formatted("voice.summary.updated", value: list(updated), locale: locale))
        }
        let deleted = items(.deleted)
        if !deleted.isEmpty {
            parts.append(AccountLocalization.formatted("voice.summary.deleted", value: list(deleted), locale: locale))
        }
        guard !parts.isEmpty else { return AccountLocalization.string("voice.summary.none", locale: locale) }
        return parts.joined(separator: AccountLocalization.string("voice.summary.separator", locale: locale))
    }
}

extension VoiceSessionTurnResponse {
    /// 耗时记录中这次请求的结果。
    fileprivate var timingOutcome: VoiceRequestTiming.Outcome {
        switch self {
        case .toolCalls: .toolCalls
        case .ask: .ask
        case .reply: .reply
        }
    }
}
