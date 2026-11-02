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
/// 结果卡片点开后在本页内看详情，不跳走；手动记账、换模型以弹层盖在本页上。
/// 规则见 `docs/rules/voice-bookkeeping-session-rules.md`。
struct AIChatView: View {
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(VoiceBookkeepingState.self) private var voice
    @Environment(SignInPresentation.self) private var signInPresentation

    /// 本页的导航路径。
    @State private var path: [AIChatRoute] = []

    /// 带着这句话去手动记账时预填的备注。
    @State private var manualEntryNote: VoiceManualEntryNote?

    /// 是否打开模型选择。
    @State private var isModelTierPresented = false

    /// 当前仍然存在的流水和账户；找不到的卡片置灰，不能点开。
    @State private var existingTargetIDs: Set<UUID> = []

    private var session: VoiceSession? { voice.session }
    private var input: VoiceInputController { voice.input }
    private var history: AIChatHistoryStore? { session?.history }

    var body: some View {
        NavigationStack(path: $path) {
            messageList
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    AIChatComposer(voice: voice)
                }
                .navigationTitle(text("voice.chat.title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel(text("common.close"))
                        .accessibilityIdentifier("voice-chat-close")
                    }
                }
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
            refreshExistingTargets()
        }
        // 从详情返回、手动记账结束或这一轮写入后，流水和账户可能变了
        .onChange(of: path.count) { _, _ in refreshExistingTargets() }
        .onChange(of: manualEntryNote == nil) { _, _ in refreshExistingTargets() }
        .onChange(of: rows.map(\.snapshot)) { _, _ in refreshExistingTargets() }
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
        .sheet(isPresented: $isModelTierPresented) {
            NavigationStack {
                AIModelTierView()
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

    // MARK: - 消息列表

    /// 消息列表：有新内容时滚到底部，打开时直接停在最新一轮。
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
                    }
                    ForEach(rows) { row in
                        if row.showsTime {
                            timeHeader(row.snapshot.createdAt)
                        }
                        turnView(row)
                            .id(row.id)
                    }
                    if input.isRecording || input.isFinishing {
                        VoiceLiveTranscript(
                            transcript: input.recognizer.transcript,
                            isRecording: input.isRecording,
                            isCancelArmed: input.isCancelArmed
                        )
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .onChange(of: scrollKey) { _, _ in
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
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

    /// 还没有记录时告诉用户能做什么：聊天框只帮忙记账，不是通用助手。
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text("voice.chat.empty.title"))
                .font(.headline)
            Text(text("voice.chat.empty.detail"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            VoiceSpeakingExamples()
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
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

    /// 一轮对话：用户的话和图片靠右，结果、写入的流水和操作靠左。
    private func turnView(_ row: AIChatRow) -> some View {
        let snapshot = row.snapshot
        return VStack(alignment: .leading, spacing: 8) {
            if !snapshot.imageFileNames.isEmpty {
                AIChatImageGrid(fileNames: snapshot.imageFileNames)
            }
            if !snapshot.userText.isEmpty {
                VoiceUserBubble(text: snapshot.userText)
                    .strikethrough(snapshot.isUndone)
            }
            if row.liveTurn?.outcome == .processing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(text("voice.processing")).font(.subheadline)
                }
            } else if let result = snapshot.resultText {
                Text(result)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(snapshot.isFailed ? Color(.ledgerRed) : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(snapshot.changes) { change in
                changeRow(change, isUndone: snapshot.isUndone)
            }
            if let turn = row.liveTurn, let session {
                liveControls(turn: turn, session: session)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 当前对话段才有的操作：耗时、追问候选项、撤销、手动记账和重新发送。
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
            onRetry: { voice.resend(turn) }
        )
    }

    /// 一行改动：还存在的流水或账户可以点开详情，已删除、已撤销或找不到的置灰。
    private func changeRow(_ change: AIChatChangeSnapshot, isUndone: Bool) -> some View {
        let isAvailable = !isUndone
            && change.kind != .deleted
            && change.targetID.map { existingTargetIDs.contains($0) } == true
        return Button {
            guard let targetID = change.targetID else { return }
            path.append(change.isEntry ? .transaction(targetID) : .account(targetID))
        } label: {
            HStack(spacing: 2) {
                VoiceChangeRowLayout(
                    symbolName: change.symbolName ?? "questionmark",
                    action: action(for: change),
                    actionColor: change.kind == .deleted ? Color(.ledgerRed) : Color.secondary,
                    title: change.title,
                    detail: detail(for: change),
                    amount: change.formattedAmount,
                    isUndone: isUndone,
                    isDimmed: !isAvailable && change.kind != .deleted
                )
                // 不可用时保留占位，各行金额仍然对齐
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 20, height: 32)
                    .opacity(isAvailable ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
    }

    /// 行首的动作文字。
    private func action(for change: AIChatChangeSnapshot) -> String {
        switch change.kind {
        case .created: VoiceEntryChangeText.action(for: .created, locale: locale)
        case .updated: VoiceEntryChangeText.action(for: .updated, locale: locale)
        case .deleted: VoiceEntryChangeText.action(for: .deleted, locale: locale)
        case .account: change.accountAction ?? ""
        }
    }

    /// 行内的说明文字。
    private func detail(for change: AIChatChangeSnapshot) -> String? {
        guard let transactionDay = change.transactionDay else { return change.accountDetail }
        return VoiceEntryChangeText.detail(
            transactionDay: transactionDay,
            accountName: change.accountName,
            inferredFields: change.inferredFields,
            locale: locale,
            calendar: calendar
        )
    }

    // MARK: - 动作

    /// 重新查询卡片对应的流水和账户是否还在。
    private func refreshExistingTargets() {
        guard let history else { return }
        existingTargetIDs = history.existingTargetIDs(in: rows.map(\.snapshot))
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
