import SwiftData
import SwiftUI

/// 麦克风旁的聊天入口：打字和发图片都在聊天页里。
struct AIChatEntryButton: View {
    @Environment(\.locale) private var locale
    @Environment(AuthStore.self) private var authStore

    /// 按钮的边长；悬浮麦克风左侧按它留出等宽占位，让麦克风保持居中。
    static let size: CGFloat = 44

    /// 与麦克风、会话卡片共享的语音状态。
    let voice: VoiceBookkeepingState

    /// 是否画悬浮底色；附属栏的玻璃底由系统绘制，不再叠一层。
    var isFloating = true

    /// 是否不接受点击：正在说话或等待识别结果。
    private var isBusy: Bool {
        voice.input.isPressing || voice.input.isFinishing
    }

    var body: some View {
        Button {
            voice.openChat(isSignedIn: authStore.isAuthenticated)
        } label: {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.body.weight(.semibold))
                .foregroundStyle(isBusy ? Color.secondary : Color.primary)
                .frame(width: Self.size, height: Self.size)
                .modifier(AIChatEntryButtonSurface(isFloating: isFloating))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        // 按住说话时让位给麦克风，避免手指滑过时误以为还能点
        .opacity(voice.input.isPressing ? 0 : 1)
        .accessibilityLabel(AccountLocalization.string("voice.chat.entry", locale: locale))
        .accessibilityIdentifier("voice-chat-entry")
    }
}

/// 聊天入口的底色：悬浮时与麦克风同样的玻璃或材质，放在附属栏里时没有底色。
private struct AIChatEntryButtonSurface: ViewModifier {
    /// 是否画悬浮底色。
    let isFloating: Bool

    func body(content: Content) -> some View {
        if isFloating {
            content.voiceFloatingSurface(in: Circle())
        } else {
            content
        }
    }
}

/// 聊天页里能进入的详情。
private enum AIChatRoute: Hashable {
    /// 流水详情。
    case transaction(UUID)

    /// 账户详情。
    case account(UUID)
}

/// 和 AI 的对话页：只有一条连续的记录，上下文按时间自动分段。
///
/// 顶部胶囊显示当前状态和今日支出，结果写成纸条，下一步建议放在输入栏上方。动效只给刚发生的一轮，翻历史时全部静止。
/// 输入栏里选 AI 对话的模型，和一级页面快捷语音的模型分开；本页发出的每一句都用这里选的档位。
/// 结果卡片点开后在本页内看详情，不跳走；手动记账、模型说明以弹层盖在本页上。
/// 规则见 `docs/rules/voice-bookkeeping-session-rules.md`。
struct AIChatView: View {
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(VoiceBookkeepingState.self) private var voice
    @Environment(SignInPresentation.self) private var signInPresentation
    /// 当前账号的 AI 点数，提供档位列表和 AI 对话所选的档位；预览中没有注入时为 nil。
    @Environment(AIPointsStore.self) private var aiPoints: AIPointsStore?

    /// 本页的导航路径。
    @State private var path: [AIChatRoute] = []

    /// 带着这句话去手动记账时预填的备注。
    @State private var manualEntryNote: VoiceManualEntryNote?

    /// 是否打开 AI 对话的模型选择页。
    @State private var isModelTierPresented = false

    /// 因为没有账户没能记上、正在为它新建账户的一轮；建好后接着处理这句话。
    @State private var accountCreationTurn: VoiceSession.Turn?

    /// 当前仍然存在的流水和账户；找不到的卡片置灰，不能点开。
    @State private var existingTargetIDs: Set<UUID> = []

    /// 还要播入场动效的轮次；播完就移出，滚走再滚回来不重播。
    @State private var entranceTurnIDs: Set<UUID> = []

    /// 今天的收支概况，顶部胶囊显示。
    @State private var todaySummary: VoiceTodaySummary?

    /// 每结束一轮加 1，胶囊里的红豆泛开一圈。
    @State private var completionPulse = 0

    private var session: VoiceSession? { voice.session }
    private var input: VoiceInputController { voice.input }
    private var history: AIChatHistoryStore? { session?.history }

    var body: some View {
        NavigationStack(path: $path) {
            messageList
                .background(Color(.paperBackground).ignoresSafeArea())
                .safeAreaInset(edge: .top, spacing: 0) {
                    topBar
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    AIChatComposer(
                        voice: voice,
                        suggestions: suggestions,
                        isAwaitingAnswer: isAwaitingAnswer,
                        onCompareModels: { isModelTierPresented = true }
                    )
                }
                // 标题用作详情页返回按钮的文字；本页的顶部是自己画的胶囊
                .navigationTitle(text("voice.chat.title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: AIChatRoute.self) { route in
                    switch route {
                    case let .transaction(id):
                        BookkeepingTransactionDetailView(transactionID: id)
                    case let .account(id):
                        AccountDetailView(accountID: id)
                    }
                }
        }
        .task {
            history?.loadLatest()
            refreshLedgerState()
            // 这句话是从首页发出来、结果还没回来时打开的，结果也算刚发生的
            if session?.isProcessing == true, let turnID = session?.latestTurn?.id {
                entranceTurnIDs.insert(turnID)
            }
            // 没进过“我的”时还没有档位列表，取一次输入栏里才能选模型；查档位不调用模型、不扣点
            if let aiPoints, aiPoints.tierList == nil {
                await aiPoints.refresh()
            }
        }
        .onChange(of: session?.latestTurn?.id) { _, turnID in
            if let turnID, session?.isProcessing == true {
                entranceTurnIDs.insert(turnID)
            }
        }
        // 从详情返回、手动记账结束或这一轮写入后，流水和账户可能变了
        .onChange(of: path.count) { _, _ in refreshLedgerState() }
        .onChange(of: manualEntryNote == nil) { _, _ in refreshLedgerState() }
        .onChange(of: rows.map(\.snapshot)) { _, _ in refreshLedgerState() }
        .sheet(item: $manualEntryNote) { item in
            NavigationStack {
                DiningExpenseEntryView(
                    draft: DiningExpenseDraft(
                        transactionDay: TransactionDay.encode(.now, calendar: calendar),
                        note: item.text
                    )
                ) { draft in
                    try LocalExpenseRepository(container: modelContext.container).save(draft)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(text("common.cancel")) { manualEntryNote = nil }
                    }
                }
            }
        }
        .sheet(item: $accountCreationTurn) { turn in
            VoiceAccountCreationSheet(turn: turn, voice: voice)
        }
        .sheet(isPresented: $isModelTierPresented) {
            NavigationStack {
                AIModelTierView(scope: .chat)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(text("common.done")) { isModelTierPresented = false }
                        }
                    }
            }
        }
        .voiceInputAlerts(input) { signIn() }
        .alert(text("voice.undo.failed"), isPresented: undoFailureBinding) {
            Button(text("common.close"), role: .cancel) {}
        }
    }

    // MARK: - 顶部

    /// 顶部：左边关闭，中间状态胶囊；内容滚动时从下面淡出。
    private var topBar: some View {
        ZStack {
            AIChatStatusPill(
                status: status,
                text: statusText,
                recognizer: input.recognizer,
                completionPulse: completionPulse
            )
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .voiceFloatingSurface(in: Circle(), isInteractive: true)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(text("common.close"))
                .accessibilityIdentifier("voice-chat-close")
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            LinearGradient(
                stops: [.init(color: Color(.paperBackground), location: 0.7), .init(color: Color(.paperBackground).opacity(0), location: 1)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
        }
    }

    /// 当前状态。
    private var status: AIChatStatus {
        AIChatStatus.resolve(
            isListening: input.isRecording || input.isFinishing,
            processingTurn: session?.isProcessing == true ? session?.latestTurn : nil
        )
    }

    /// 胶囊里的文字：处理中说在做什么，空闲时是今日支出。
    private var statusText: String {
        if let text = status.text(locale: locale) { return text }
        guard let todaySummary, todaySummary.entryCount > 0 else { return text("voice.chat.status.noEntries") }
        return AccountLocalization.formatted(
            "voice.chat.status.todayExpense", value: todaySummary.formattedExpense, locale: locale
        )
    }

    // MARK: - 消息列表

    /// 消息列表：内容少时贴着输入栏，有新内容时滚到底部，打开时直接停在最新一轮。
    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if history?.hasEarlier == true {
                        Button(text("voice.chat.earlier")) { history?.loadEarlier() }
                            .font(.footnote)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("voice-chat-earlier")
                    }
                    if rows.isEmpty, !input.isRecording, !input.isFinishing {
                        emptyState
                            .transition(.opacity)
                    }
                    ForEach(rows) { row in
                        if row.showsTime {
                            timeHeader(row.snapshot.createdAt)
                        }
                        turnView(row)
                            .id(row.id)
                            .transition(
                                reduceMotion ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .offset(y: 24))
                            )
                    }
                    if input.isRecording || input.isFinishing {
                        AIChatLiveBubble(
                            transcript: input.recognizer.transcript,
                            isCancelArmed: input.isCancelArmed
                        )
                        .transition(.opacity)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .animation(reduceMotion ? nil : .spring(duration: 0.42, bounce: 0.2), value: rows.last?.id)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: input.isRecording)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .onChange(of: scrollKey) { _, _ in
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    /// 列表末尾的锚点。
    private static let bottomAnchor = "voice-chat-bottom"

    /// 内容变化时滚到底部的依据：新的一轮、这一轮的结果和实时转写；读取更早的记录不算。
    private var scrollKey: AIChatScrollKey {
        AIChatScrollKey(
            latestTurnID: rows.last?.id,
            latestSnapshot: rows.last?.snapshot,
            transcript: input.recognizer.transcript,
            isRecording: input.isRecording
        )
    }

    /// 还没有记录时：墨线写出一棵芽，一句开场白告诉用户能做什么；聊天框只帮忙记账，不是通用助手。
    private var emptyState: some View {
        VStack(spacing: 6) {
            SproutIllustration(size: 128)
            Text(AIChatCopy.greeting(hour: calendar.component(.hour, from: .now), locale: locale))
                .font(.system(.title2, design: .serif).weight(.semibold))
                .multilineTextAlignment(.center)
            Text(text("voice.chat.empty.detail"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
    }

    /// 时间分隔：第一轮和隔了较久的一轮上方显示。
    private func timeHeader(_ date: Date) -> some View {
        Text(
            BookkeepingDateFormatting.formatter(template: "MMMdjm", locale: locale, calendar: calendar).string(from: date)
        )
        .font(.caption)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
    }

    /// 历史记录和当前对话段合在一起的列表；当前对话段的轮次还能撤销、回答追问。
    private var rows: [AIChatRow] {
        let liveTurns = session?.turns ?? []
        let liveIDs = Set(liveTurns.map(\.id))
        let saved = (history?.turns ?? []).filter { !liveIDs.contains($0.id) }
        var result: [AIChatRow] = []
        var previousDate: Date?
        /// 追加一轮，隔得久时上方带时间。
        func append(_ snapshot: AIChatTurnSnapshot, liveTurn: VoiceSession.Turn?) {
            let showsTime = previousDate.map {
                snapshot.createdAt.timeIntervalSince($0) >= VoiceSession.contextIdleTimeout
            } ?? true
            previousDate = snapshot.createdAt
            result.append(AIChatRow(snapshot: snapshot, liveTurn: liveTurn, showsTime: showsTime))
        }
        for snapshot in saved {
            append(snapshot, liveTurn: nil)
        }
        for turn in liveTurns {
            append(AIChatTurnSnapshot(turn: turn, locale: locale), liveTurn: turn)
        }
        return result
    }

    /// 一轮对话：用户的话和图片靠右，结果和操作靠左。
    private func turnView(_ row: AIChatRow) -> some View {
        let snapshot = row.snapshot
        let isProcessing = row.liveTurn?.outcome == .processing
        return VStack(alignment: .leading, spacing: 10) {
            if !snapshot.imageFileNames.isEmpty {
                AIChatImageGrid(fileNames: snapshot.imageFileNames, isScanning: isProcessing)
            }
            if !snapshot.userText.isEmpty {
                AIChatUserBubble(text: snapshot.userText, isUndone: snapshot.isUndone)
            }
            AIChatTurnResultView(
                snapshot: snapshot,
                isFinished: !isProcessing,
                isQuestion: row.isQuestion,
                animatesEntrance: entranceTurnIDs.contains(row.id),
                existingTargetIDs: existingTargetIDs,
                actions: resultActions(for: row),
                onEntranceFinished: { finishEntrance(of: row) }
            )
            if isProcessing, let status = processingStatus(of: row) {
                AIChatThinkingIndicator(text: status)
            }
            if let turn = row.liveTurn, let session {
                liveControls(turn: turn, session: session)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 处理中这一轮要显示的文字。
    private func processingStatus(of row: AIChatRow) -> String? {
        AIChatStatus.resolve(isListening: false, processingTurn: row.liveTurn).text(locale: locale)
    }

    /// 这一轮的纸条上能做的事：详情都能看，撤销和就地确认账户只有当前对话段才有。
    private func resultActions(for row: AIChatRow) -> AIChatResultActions {
        var actions = AIChatResultActions(open: { open($0) })
        guard let turn = row.liveTurn, let session, !turn.isUndone else { return actions }
        if session.undoableTurn?.id == turn.id {
            actions.undo = { session.undoLatestTurn() }
        }
        if !session.isProcessing {
            actions.confirmAccount = { change, accountID in
                session.confirmInferredAccount(turnID: turn.id, changeID: change.id, accountID: accountID)
            }
            actions.accountOptions = { session.currentContext().accounts }
        }
        return actions
    }

    /// 打开一行改动的详情。
    private func open(_ change: AIChatChangeSnapshot) {
        guard let targetID = change.targetID else { return }
        path.append(change.isEntry ? .transaction(targetID) : .account(targetID))
    }

    /// 入场动效播完：不再重播；有改动时红豆泛开一圈，表示这一轮结束。
    private func finishEntrance(of row: AIChatRow) {
        entranceTurnIDs.remove(row.id)
        if !row.snapshot.changes.isEmpty {
            completionPulse += 1
        }
    }

    /// 当前对话段才有的操作：耗时、追问候选项、手动记账和重新发送；撤销在纸条上。
    @ViewBuilder
    private func liveControls(turn: VoiceSession.Turn, session: VoiceSession) -> some View {
        // DEBUG 包与 TestFlight 包显示这句话的耗时，点开看每一步
        if VoiceTimingFeature.isEnabled, let timing = turn.timing {
            VoiceTurnTimingView(timing: timing)
        }
        if session.latestTurn?.id == turn.id, case let .ask(_, options) = turn.outcome, !options.isEmpty {
            VoiceAskOptionsView(options: options, isEnabled: !session.isProcessing) { option in
                voice.send(option.label, option: option)
            }
        }
        VoiceTurnActions(
            session: session,
            turn: turn,
            onManualEntry: { manualEntryNote = VoiceManualEntryNote(text: $0) },
            onSignIn: { signIn() },
            onSwitchModelTier: { isModelTierPresented = true },
            onCreateAccount: { accountCreationTurn = turn },
            onRetry: { voice.resend(turn) },
            showsUndo: false,
            modelScope: .chat
        )
    }

    // MARK: - 建议

    /// 是否正在等用户回答追问。
    private var isAwaitingAnswer: Bool {
        if case .ask = session?.latestTurn?.outcome { return true }
        return false
    }

    /// 输入栏上方的建议；处理中和说话时不打岔。
    private var suggestions: [AIChatSuggestion] {
        guard session?.isProcessing != true, !input.isRecording, !input.isFinishing else { return [] }
        let latest = rows.last
        return AIChatSuggestions.make(
            latest: latest?.snapshot,
            isLive: latest?.liveTurn != nil,
            isAwaitingAnswer: isAwaitingAnswer,
            canUndo: latest?.liveTurn != nil && session?.undoableTurn?.id == latest?.id,
            locale: locale
        )
    }

    // MARK: - 动作

    /// 重新读取账本里会变的内容：卡片对应的流水和账户是否还在，今天的支出。
    private func refreshLedgerState() {
        if let history {
            existingTargetIDs = history.existingTargetIDs(in: rows.map(\.snapshot))
        }
        if let summary = session?.todaySummary(), summary != todaySummary {
            withAnimation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.2)) {
                todaySummary = summary
            }
        }
    }

    /// 去登录：登录页盖在根导航上，先关掉本页才看得到。
    private func signIn() {
        dismiss()
        signInPresentation.present(reason: .voiceBookkeeping)
    }

    private var undoFailureBinding: Binding<Bool> {
        Binding(
            get: { session?.hasUndoFailure == true },
            set: { if !$0 { voice.session?.hasUndoFailure = false } }
        )
    }

    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 列表中的一轮。
private struct AIChatRow: Identifiable {
    /// 展示内容。
    let snapshot: AIChatTurnSnapshot

    /// 当前对话段的轮次；历史记录为 `nil`。
    let liveTurn: VoiceSession.Turn?

    /// 上方是否显示时间。
    let showsTime: Bool

    /// 稳定标识。
    var id: UUID { snapshot.id }

    /// 这一轮是否是模型的追问。
    var isQuestion: Bool {
        if case .ask = liveTurn?.outcome { return true }
        return false
    }
}

/// 决定是否滚到底部的内容。
private struct AIChatScrollKey: Equatable {
    /// 最新一轮的标识。
    let latestTurnID: UUID?

    /// 最新一轮的内容。
    let latestSnapshot: AIChatTurnSnapshot?

    /// 实时转写。
    let transcript: String

    /// 是否正在收音。
    let isRecording: Bool
}
