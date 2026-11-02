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

    /// AI 点数不足。
    case insufficientPoints

    /// 本轮已失效（例如处理时间过长），需要重说一遍。
    case turnInvalid

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

        /// 用户说的话（或点选的候选项文字）；只发图片时为空。
        let userText: String

        /// 这一轮附带的图片文件名，文件保存在 `AIChatImageStore`。
        var imageFileNames: [String] = []

        /// 用户发出这一轮的时刻。
        var createdAt: Date = .now

        /// 处理结果。
        var outcome: Outcome = .processing

        /// 本轮成功写入的改动（收支流水与账户相关），按执行顺序排列。
        var changes: [VoiceChange] = []

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

    /// 超过该时长没有新的一轮，首页的会话卡片收起；对话段不结束，接着说还能引用刚才的内容。
    static let cardIdleTimeout: TimeInterval = 120

    /// 超过该时长没有新的一轮，当前对话段结束，模型上下文和撤销都清掉；对话记录保留在聊天页。
    static let contextIdleTimeout: TimeInterval = 30 * 60

    /// 一轮最多发送的请求数，防止服务端异常时无限循环。
    static let maxRequestsPerTurn = 10

    /// 当前对话段的全部轮次，包括已撤销和失败的，按时间顺序排列。
    private(set) var turns: [Turn] = []

    /// 首页卡片从第几轮开始显示；卡片收起时推到末尾，之前的轮次只在聊天页显示。
    private var cardStartIndex = 0

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
    /// 读取语音记账要用的模型档位；每句开始时取一次，为 nil 时由服务端按默认档位处理。
    private let modelTier: () -> AIModelTier?
    private let highlight: HomeRecentEntryHighlight
    private let now: () -> Date
    /// 写入「语音耗时」的记录；未启用语音耗时（`VoiceTimingFeature.isEnabled`）时为空，不保存耗时。
    private let timingStore: VoiceTimingStore?

    /// 对话记录；每轮结束和撤销时写入。测试和预览可以不提供。
    let history: AIChatHistoryStore?

    /// 界面语言，决定分类名称、结果提示和 AI 回复的语言。
    var locale: Locale

    /// 记账日换算使用的日历。
    var calendar: Calendar

    /// 创建会话。
    ///
    /// - Parameters:
    ///   - container: 应用持有的本地财务容器。
    ///   - api: 会话接口。
    ///   - modelTier: 读取模型档位的动作，通常是 `AIPointsStore.requestTier`；默认不带档位。
    ///   - locale: 界面语言。
    ///   - calendar: 记账日使用的日历。
    ///   - highlight: 首页变更提示通道。
    ///   - timingStore: 耗时记录；为空时启用了语音耗时则使用 App 共用的记录，否则不保存。
    ///   - history: 对话记录；为空时不保存。
    ///   - now: 时间源。
    init(
        container: ModelContainer,
        api: VoiceSessionTurnSending,
        modelTier: @escaping () -> AIModelTier? = { nil },
        locale: Locale = .current,
        calendar: Calendar = .current,
        highlight: HomeRecentEntryHighlight = .shared,
        timingStore: VoiceTimingStore? = nil,
        history: AIChatHistoryStore? = nil,
        now: @escaping () -> Date = { .now }
    ) {
        self.container = container
        self.api = api
        self.modelTier = modelTier
        self.locale = locale
        self.calendar = calendar
        self.highlight = highlight
        // 默认参数在非隔离上下文中求值，碰不到主线程隔离的共用记录，所以在初始化体内取默认值
        self.timingStore = timingStore ?? (VoiceTimingFeature.isEnabled ? .shared : nil)
        self.history = history
        self.now = now
    }

    /// 首页卡片要显示的轮次。
    var cardTurns: ArraySlice<Turn> { turns[min(cardStartIndex, turns.count)...] }

    /// 会话卡片是否有内容需要展示。
    var isActive: Bool { !cardTurns.isEmpty }

    /// 最近的一轮。
    var latestTurn: Turn? { turns.last }

    /// 可以撤销的一轮：仍在会话记录中的最后一轮，且有写入。
    var undoableTurn: Turn? {
        guard !isProcessing, let turn = turns.last(where: \.isInContext), !turn.changes.isEmpty else { return nil }
        return turn
    }

    /// 本会话中仍然有效的改动（不含已撤销的轮次）。
    var activeChanges: [VoiceChange] {
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
    ///   - images: 随这句话发送的图片；有图片时文字可以为空。
    func send(
        _ rawText: String,
        selectedOption: VoiceAskOption? = nil,
        speechFinalizeDuration: Duration? = nil,
        images: [VoiceImageUpload] = []
    ) async {
        let text = String(
            rawText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(VoiceSessionLimits.maxUserTextLength)
        )
        guard !isProcessing, !text.isEmpty || !images.isEmpty else { return }
        endIfIdle()
        // 事件多了就悄悄开新段，不让用户看到“对话太长”；正在等回答的追问要接着答完，不能丢上下文
        if events.count >= VoiceSessionLimits.segmentEventLimit, !isAwaitingAnswer {
            end()
        }
        // 一次请求带的图片有上限，新发图片时不再保留上一轮追问留下的图片
        if !images.isEmpty {
            removeImagesFromEvents()
        }

        let turnGeneration = generation
        let turnID = appendTurn(Turn(
            userText: text,
            imageFileNames: images.map(\.fileName),
            createdAt: now(),
            eventStartIndex: events.count
        ))
        // 追加用户这句话后，还要给服务端的追问或工具调用留出空间
        guard events.count + 2 <= VoiceSessionLimits.maxEvents else {
            finishTurn(turnID, failure: .sessionTooLong)
            saveToHistory(turnID)
            return
        }
        isProcessing = true
        defer {
            if turnGeneration == generation {
                isProcessing = false
                lastActivityAt = now()
                // 追问时模型还要看图片才能接着处理，等回答之后再去掉；回答失败、可以重发时也留着
                if !isAwaitingAnswer, latestTurn?.isInContext == true {
                    removeImagesFromEvents()
                }
                saveToHistory(turnID)
            }
        }
        turnCount += 1
        let turnIndex = turnCount
        // 一句话一个计费轮次：这句的续步沿用，用户下一句（包括回答追问）重新生成
        let billingTurnID = UUID()
        // 档位与计费轮次一起在这句开始时确定：处理期间用户换了档位，续步仍沿用，否则服务端会判为不一致
        let tier = modelTier()
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
        events.append(userEvent(text: text, selectedOption: selectedOption, images: images))

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
                    response = try await api.send(request, turnID: billingTurnID, tier: tier, trace: trace)
                } catch {
                    signposter.endInterval("VoiceRequest", requestSignpost)
                    requestTimings.append(Self.requestTiming(trace, outcome: .failed, buildMs: buildMs, startedAt: requestStartedAt))
                    throw error
                }
                signposter.endInterval("VoiceRequest", requestSignpost)
                requestTimings.append(Self.requestTiming(
                    trace, outcome: response.timingOutcome, buildMs: buildMs, startedAt: requestStartedAt
                ))
                // 等待期间会话已结束（例如关闭卡片或进入二级页面），结果不再展示
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
                            // 余额调整、转账与账户改动不在首页明细中展示，只有收支流水需要提示
                            if let entryHighlight = change.entryChange?.highlight {
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
        saveToHistory(turn.id)
    }

    /// 用户关闭卡片（点关闭、点卡片外或进入二级页面）：只收起卡片，对话段不结束；
    /// 这一轮还在处理时才结束对话段，放弃这一轮的结果。
    func closeCard() {
        if isProcessing {
            end()
        } else {
            cardStartIndex = turns.count
        }
    }

    /// 让已结束的轮次不再显示在卡片上；还在处理的一轮保留，它的结果仍要出现。
    ///
    /// 用于卡片闲置，以及从聊天页回到一级页面：这些轮次都能在聊天页看到。
    func hideFinishedCardTurns() {
        cardStartIndex = isProcessing ? max(turns.count - 1, 0) : turns.count
    }

    /// 结束当前对话段：清空上下文和撤销。等待中的请求返回后会被丢弃，已写入的流水和对话记录保留。
    func end() {
        generation += 1
        sessionID = UUID()
        turnCount = 0
        turns = []
        cardStartIndex = 0
        events = []
        isProcessing = false
        lastActivityAt = nil
        hasUndoFailure = false
    }

    /// 闲置超过 `cardIdleTimeout` 时收起首页卡片。
    func hideCardIfIdle() {
        guard !isProcessing, let lastActivityAt, now().timeIntervalSince(lastActivityAt) >= Self.cardIdleTimeout
        else { return }
        cardStartIndex = turns.count
    }

    /// 闲置超过 `contextIdleTimeout` 时结束当前对话段。
    func endIfIdle() {
        guard !isProcessing, let lastActivityAt, now().timeIntervalSince(lastActivityAt) >= Self.contextIdleTimeout
        else { return }
        end()
    }

    // MARK: - 私有方法

    /// 最近一轮是否是还没回答的追问。
    private var isAwaitingAnswer: Bool {
        if case .ask = latestTurn?.outcome { return true }
        return false
    }

    /// 生成用户这句话的事件；只发图片时用一句默认说明，服务端要求文字不能为空。
    private func userEvent(text: String, selectedOption: VoiceAskOption?, images: [VoiceImageUpload]) -> VoiceSessionEvent {
        guard !images.isEmpty else { return .user(text: text, selectedOptionId: selectedOption?.id) }
        return .userWithImages(
            text: text.isEmpty ? AccountLocalization.string("voice.chat.image.prompt", locale: locale) : text,
            images: images.map {
                VoiceSessionImage(data: $0.data.base64EncodedString(), mediaType: VoiceImageUpload.mediaType)
            }
        )
    }

    /// 把事件里的图片去掉，只留文字和一句说明：服务端不保存会话，留着的话每一轮都要重发图片。
    private func removeImagesFromEvents() {
        let note = AccountLocalization.string("voice.chat.image.contextNote", locale: locale)
        events = events.map { event in
            guard case let .userWithImages(text, _) = event else { return event }
            let maxTextLength = VoiceSessionLimits.maxUserTextLength - note.count
            return .user(text: String(text.prefix(maxTextLength)) + note, selectedOptionId: nil)
        }
    }

    /// 把一轮写入对话记录。
    private func saveToHistory(_ id: UUID) {
        guard let turn = turns.first(where: { $0.id == id }) else { return }
        history?.save(turn, locale: locale)
    }

    /// 生成本步请求。
    private func makeRequest() -> VoiceSessionTurnRequest {
        let context = currentContext()
        return VoiceSessionTurnRequest(
            locale: VoiceSessionContext.localeCode(for: locale),
            capabilities: VoiceSessionCapability.declared,
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
        case .insufficientPoints: .insufficientPoints
        case .turnInvalid: .turnInvalid
        case .network: .network
        case .serviceUnavailable, .timeout, .invalidContract, nil: .serviceUnavailable
        }
    }
}

/// 随一句话发送的一张图片：压缩好的内容和它在本机的文件名。
struct VoiceImageUpload: Equatable {
    /// 压缩后的图片类型。
    static let mediaType = "image/jpeg"

    /// 本机文件名，记录里据此显示图片。
    let fileName: String

    /// 压缩好的 JPEG。
    let data: Data
}

/// 在本地生成一轮的结果提示，例如「已记 2 笔：午饭 ¥28.00、打车 ¥35.00」。
enum VoiceSessionSummary {
    /// 生成结果提示：先按新增、修改、删除分段说明收支流水，再逐句说明账户相关的改动。
    ///
    /// - Parameters:
    ///   - changes: 本轮的改动，按执行顺序排列。
    ///   - locale: 文案使用的语言环境。
    /// - Returns: 本地化提示；没有改动时为「这句话我没能处理」一类的兜底文案。
    static func text(for changes: [VoiceChange], locale: Locale) -> String {
        let entries = changes.compactMap(\.entryChange)
        let accountSentences = changes.compactMap { change -> String? in
            guard case let .account(accountChange) = change else { return nil }
            return accountChange.summary
        }
        guard !accountSentences.isEmpty else {
            return text(forItems: entries.map { Item($0) }, locale: locale)
        }
        let entryText = entries.isEmpty ? [] : [text(forItems: entries.map { Item($0) }, locale: locale)]
        return (entryText + accountSentences)
            .joined(separator: AccountLocalization.string("voice.summary.separator", locale: locale))
    }

    /// 结果提示里的一笔变更：只需要类型、称呼和金额，首次引导的演示也用它生成同样的提示。
    struct Item: Equatable {
        /// 变更类型。
        let kind: VoiceEntryChange.Kind

        /// 称呼这笔流水的文字，例如「午饭」。
        let label: String

        /// 不带正负号的本地化金额。
        let formattedAmount: String
    }

    /// 按变更摘要生成结果提示。
    ///
    /// - Parameters:
    ///   - changes: 本轮的变更摘要，按执行顺序排列。
    ///   - locale: 文案使用的语言环境。
    /// - Returns: 本地化提示；没有变更时为兜底文案。
    static func text(forItems changes: [Item], locale: Locale) -> String {
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

extension VoiceSessionSummary.Item {
    /// 由一笔收支流水的改动生成摘要。
    fileprivate init(_ change: VoiceEntryChange) {
        self.init(kind: change.kind, label: change.label, formattedAmount: change.formattedAmount)
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
