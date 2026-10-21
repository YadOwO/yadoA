import SwiftData
import SwiftUI
import UIKit

/// 记账页底部的语音记账区域：麦克风按钮、收音气泡与本次会话的结果条，并负责弹出对话面板、登录提示等。
///
/// 会话在离开记账页、关闭结果条或闲置约 2 分钟后结束。
struct VoiceBookkeepingDock: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AuthStore.self) private var authStore
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    /// 麦克风按钮（含上下留白）占用的高度变化时回调，首页据此给列表末尾留白。
    let onButtonHeightChange: (CGFloat) -> Void

    @State private var session: VoiceSession?
    @State private var input = VoiceInputController()
    @State private var isConversationPresented = false
    @State private var presentedTransaction: VoicePresentedTransaction?
    @State private var manualEntryNote: VoiceManualEntryNote?

    var body: some View {
        VStack(spacing: 10) {
            if input.isRecording {
                VoiceTranscriptBubble(
                    transcript: input.recognizer.transcript,
                    isCancelArmed: input.isCancelArmed
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if let hint = input.transientHint {
                Text(hint)
                    .font(.footnote)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .voiceFloatingSurface(in: Capsule())
                    .transition(.opacity)
            } else if let session, let turn = session.latestTurn {
                VoiceSessionStrip(
                    session: session,
                    turn: turn,
                    onOpenConversation: { isConversationPresented = true },
                    onOpenTransaction: { presentedTransaction = VoicePresentedTransaction(id: $0) },
                    onManualEntry: { manualEntryNote = VoiceManualEntryNote(text: $0) },
                    onSignIn: signIn,
                    onEnd: endSession
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            VoiceMicButton(
                controller: input,
                isProcessing: session?.isProcessing == true,
                onPressBegan: beginPress,
                onTap: { isConversationPresented = true },
                onText: send,
                onAccessibilityToggle: toggleRecording
            )
            .padding(.vertical, 12)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                onButtonHeightChange(height)
            }
        }
        .padding(.horizontal, 16)
        .animation(.easeOut(duration: 0.2), value: input.isRecording)
        .animation(.easeOut(duration: 0.2), value: session?.latestTurn)
        .task {
            if session == nil {
                session = VoiceSession(
                    container: modelContext.container,
                    api: VoiceSessionAPI { [authStore] in try await authStore.accessTokenForAIService() },
                    locale: locale,
                    calendar: calendar
                )
            }
        }
        .onChange(of: locale) { _, newValue in session?.locale = newValue }
        .onChange(of: calendar) { _, newValue in session?.calendar = newValue }
        // 闲置约 2 分钟后自动结束会话；每轮结束都会重新计时
        .task(id: session?.lastActivityAt) {
            guard session?.lastActivityAt != nil else { return }
            try? await Task.sleep(for: .seconds(VoiceSession.idleTimeout))
            session?.endIfIdle()
        }
        // 每轮结束后用触感和 VoiceOver 播报结果
        .onChange(of: session?.latestTurn?.outcome) { _, outcome in
            announce(outcome)
        }
        .sensoryFeedback(trigger: session?.latestTurn?.outcome) { _, outcome in
            switch outcome {
            case .reply?, .ask?: .success
            case .failed?: .error
            case .processing?, nil: nil
            }
        }
        .onDisappear {
            // 离开记账页即结束会话；面板与详情都是盖在首页上的弹层，不会触发这里
            endSession()
        }
        .sheet(isPresented: $isConversationPresented) {
            if let session {
                VoiceConversationView(
                    session: session,
                    input: input,
                    onPressBegan: beginPress,
                    onSend: send,
                    onAccessibilityToggle: toggleRecording,
                    onManualEntry: { text in
                        isConversationPresented = false
                        manualEntryNote = VoiceManualEntryNote(text: text)
                    },
                    onSignIn: signIn,
                    onEnd: endSession
                )
            }
        }
        .sheet(item: $presentedTransaction) { item in
            NavigationStack {
                BookkeepingTransactionDetailView(transactionID: item.id)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(text("common.done")) { presentedTransaction = nil }
                        }
                    }
            }
        }
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
        // 对话面板打开时由面板负责弹出提示，盖在面板下面的首页无法弹出
        .voiceInputAlerts(input, isEnabled: !isConversationPresented, onSignIn: signIn)
        .alert(text("voice.undo.failed"), isPresented: undoFailureBinding) {
            Button(text("common.close"), role: .cancel) {}
        }
    }

    // MARK: - 动作

    /// 按下麦克风：未登录时松手后提示登录，已登录时开始收音。
    private func beginPress() {
        input.pressBegan(
            isSignedIn: authStore.isAuthenticated,
            locale: locale,
            contextualStrings: { session?.currentContext().contextualStrings ?? [] }
        )
    }

    /// 无障碍模式下切换收音。
    private func toggleRecording() {
        input.toggleRecording(
            isSignedIn: authStore.isAuthenticated,
            locale: locale,
            contextualStrings: { session?.currentContext().contextualStrings ?? [] },
            onText: send
        )
    }

    /// 发送一句话。
    private func send(_ text: String) {
        send(text, option: nil)
    }

    /// 发送一句话或点选的候选项。
    private func send(_ text: String, option: VoiceAskOption?) {
        guard let session else { return }
        Task { await session.send(text, selectedOption: option) }
    }

    /// 结束会话，同时作废还在收尾的语音输入，避免它在会话结束后识别完成、又发起新的一轮。
    private func endSession() {
        input.cancel()
        session?.end()
    }

    /// 登录；成功后打开对话面板继续语音操作。
    private func signIn() {
        Task {
            await authStore.signIn()
            if authStore.isAuthenticated {
                isConversationPresented = true
            }
        }
    }

    /// VoiceOver 播报本轮结果。
    private func announce(_ outcome: VoiceSession.Turn.Outcome?) {
        guard let turn = session?.latestTurn, outcome != .processing, let text = turn.resultText(locale: locale)
        else { return }
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    private var undoFailureBinding: Binding<Bool> {
        Binding(
            get: { session?.hasUndoFailure == true },
            set: { if !$0 { session?.hasUndoFailure = false } }
        )
    }

    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 按住说话时的提示：登录、权限、识别不可用。记账页与对话面板各挂一份，同一时间只有一处启用。
private struct VoiceInputAlertModifier: ViewModifier {
    @Environment(\.locale) private var locale

    /// 按住说话的交互逻辑，提示来自它的 `alert`。
    let input: VoiceInputController

    /// 是否由这里负责弹出提示。
    let isEnabled: Bool

    /// 去登录。
    let onSignIn: () -> Void

    func body(content: Content) -> some View {
        content.alert(
            input.alert.map { alertTitle(for: $0) } ?? "",
            isPresented: inputAlertBinding,
            presenting: input.alert
        ) { alert in
            alertActions(for: alert)
        } message: { alert in
            if let message = alertMessage(for: alert) {
                Text(message)
            }
        }
    }

    private var inputAlertBinding: Binding<Bool> {
        Binding(
            get: { isEnabled && input.alert != nil },
            set: { if !$0 { input.alert = nil } }
        )
    }

    private func alertTitle(for alert: VoiceInputAlert) -> String {
        switch alert {
        case .signInRequired: text("voice.signIn.title")
        case .permissionDenied: text("voice.permission.title")
        case .unsupported: text("voice.error.unsupported")
        case .microphoneUnavailable: text("voice.error.microphoneUnavailable")
        }
    }

    private func alertMessage(for alert: VoiceInputAlert) -> String? {
        switch alert {
        case .signInRequired: text("voice.signIn.message")
        case .permissionDenied: text("voice.permission.message")
        case .unsupported, .microphoneUnavailable: nil
        }
    }

    @ViewBuilder
    private func alertActions(for alert: VoiceInputAlert) -> some View {
        switch alert {
        case .signInRequired:
            Button(text("voice.signIn.action"), action: onSignIn)
            Button(text("common.cancel"), role: .cancel) {}
        case .permissionDenied:
            Button(text("voice.permission.settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button(text("common.cancel"), role: .cancel) {}
        case .unsupported, .microphoneUnavailable:
            Button(text("common.close"), role: .cancel) {}
        }
    }

    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

extension View {
    /// 挂上按住说话的提示。
    ///
    /// - Parameters:
    ///   - input: 按住说话的交互逻辑。
    ///   - isEnabled: 是否由这里负责弹出。
    ///   - onSignIn: 去登录。
    func voiceInputAlerts(_ input: VoiceInputController, isEnabled: Bool = true, onSignIn: @escaping () -> Void) -> some View {
        modifier(VoiceInputAlertModifier(input: input, isEnabled: isEnabled, onSignIn: onSignIn))
    }
}

/// 从结果条或对话面板打开详情的流水。
struct VoicePresentedTransaction: Identifiable {
    /// 流水 UUID。
    let id: UUID
}

/// 带着这句话去手动记账时预填的备注。
struct VoiceManualEntryNote: Identifiable {
    /// 稳定标识。
    let id = UUID()

    /// 预填的备注文字。
    let text: String
}

/// 麦克风上方的结果条：最近一轮的回复或追问、本轮写入的流水，以及撤销、手动记账、结束操作。
struct VoiceSessionStrip: View {
    @Environment(\.locale) private var locale

    /// 当前会话。
    let session: VoiceSession

    /// 最近一轮。
    let turn: VoiceSession.Turn

    /// 打开对话面板。
    let onOpenConversation: () -> Void

    /// 打开一笔流水的详情。
    let onOpenTransaction: (UUID) -> Void

    /// 带着这句话去手动记账。
    let onManualEntry: (String) -> Void

    /// 去登录。
    let onSignIn: () -> Void

    /// 结束会话。
    let onEnd: () -> Void

    /// 结果条最多直接列出的流水笔数，其余在对话面板里查看。
    private static let maxVisibleChanges = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Button(action: onOpenConversation) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(turn.userText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if turn.outcome == .processing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(text("voice.processing"))
                                    .font(.subheadline)
                            }
                        } else if let result = turn.resultText(locale: locale) {
                            Text(result)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.primary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("voice-strip")

                Button(action: onEnd) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(text("voice.session.close.accessibility"))
                .accessibilityIdentifier("voice-strip-close")
            }

            if !turn.changes.isEmpty {
                VStack(spacing: 6) {
                    ForEach(turn.changes.prefix(Self.maxVisibleChanges)) { change in
                        Button {
                            onOpenTransaction(change.transactionID)
                        } label: {
                            VoiceEntryChangeRow(change: change, isUndone: turn.isUndone)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        // 删除或撤销后流水已不存在，没有详情可看
                        .disabled(change.kind == .deleted || turn.isUndone)
                    }
                    if turn.changes.count > Self.maxVisibleChanges {
                        Button(action: onOpenConversation) {
                            Text(String(
                                format: text("voice.conversation.more"),
                                locale: locale,
                                turn.changes.count - Self.maxVisibleChanges
                            ))
                            .font(.footnote)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            if case let .ask(_, options) = turn.outcome, !options.isEmpty {
                VoiceAskOptionsView(options: options, isEnabled: !session.isProcessing) { option in
                    Task { await session.send(option.label, selectedOption: option) }
                }
            }

            actions
        }
        .padding(14)
        .voiceFloatingSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// 本轮可用的操作。
    @ViewBuilder
    private var actions: some View {
        let isUndoable = session.undoableTurn?.id == turn.id
        let requiresSignIn = turn.failure?.requiresSignIn == true
        if isUndoable || turn.offersManualEntry || turn.isUndone {
            HStack(spacing: 12) {
                if turn.isUndone {
                    Label(text("voice.turn.undone"), systemImage: "arrow.uturn.backward")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if requiresSignIn {
                    Button(text("voice.signIn.action"), action: onSignIn)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else if turn.offersManualEntry {
                    Button(text("voice.turn.manualEntry")) { onManualEntry(turn.userText) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("voice-manual-entry")
                }
                if isUndoable {
                    Button(text("voice.turn.undo")) { session.undoLatestTurn() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .onAccentForeground()
                        .accessibilityIdentifier("voice-undo")
                }
            }
        }
    }

    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}
