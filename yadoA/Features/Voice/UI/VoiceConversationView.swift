import SwiftUI

/// 语音记账的对话面板：本次会话的完整对话与写入的流水，可以打字输入，也可以按住麦克风说话。
struct VoiceConversationView: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss

    /// 当前会话。
    let session: VoiceSession

    /// 按住说话的交互逻辑，与记账页的悬浮按钮共用。
    let input: VoiceInputController

    /// 按下麦克风。
    let onPressBegan: () -> Void

    /// 发送一句话。
    let onSend: (String) -> Void

    /// 无障碍切换收音。
    let onAccessibilityToggle: () -> Void

    /// 带着这句话去手动记账。
    let onManualEntry: (String) -> Void

    /// 去登录。
    let onSignIn: () -> Void

    /// 结束会话。
    let onEnd: () -> Void

    @State private var draft = ""
    @State private var presentedTransaction: VoicePresentedTransaction?
    @FocusState private var isInputFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if session.turns.isEmpty {
                        Text(text("voice.conversation.empty"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 24)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(session.turns) { turn in
                        VoiceConversationTurnView(
                            session: session,
                            turn: turn,
                            onOpenTransaction: { presentedTransaction = VoicePresentedTransaction(id: $0) },
                            onManualEntry: onManualEntry,
                            onSignIn: onSignIn
                        )
                        .id(turn.id)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .paperPage()
                .onChange(of: session.turns.last) { _, turn in
                    guard let turn else { return }
                    withAnimation { proxy.scrollTo(turn.id, anchor: .bottom) }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                inputBar
            }
            .navigationTitle(text("voice.conversation.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(text("voice.session.end")) {
                        onEnd()
                        dismiss()
                    }
                    .disabled(session.turns.isEmpty)
                    .accessibilityIdentifier("voice-conversation-end")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(text("common.done")) { dismiss() }
                }
            }
        }
        .voiceInputAlerts(input, onSignIn: onSignIn)
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
    }

    /// 底部输入栏：收音气泡、文字输入与麦克风。
    private var inputBar: some View {
        VStack(spacing: 8) {
            if input.isRecording {
                VoiceTranscriptBubble(transcript: input.recognizer.transcript, isCancelArmed: input.isCancelArmed)
            }
            HStack(spacing: 10) {
                TextField(text("voice.conversation.placeholder"), text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($isInputFocused)
                    .submitLabel(.send)
                    .onSubmit(sendDraft)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityIdentifier("voice-conversation-input")
                if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VoiceMicButton(
                        controller: input,
                        isProcessing: session.isProcessing,
                        diameter: 44,
                        onPressBegan: onPressBegan,
                        // 面板里轻点麦克风不需要再打开面板，改为提示按住说话
                        onTap: {},
                        onText: onSend,
                        onAccessibilityToggle: onAccessibilityToggle
                    )
                } else {
                    Button(action: sendDraft) {
                        Image(systemName: "arrow.up")
                            .font(.headline)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .onAccentForeground()
                    .disabled(session.isProcessing)
                    .accessibilityLabel(text("voice.conversation.send"))
                    .accessibilityIdentifier("voice-conversation-send")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !session.isProcessing else { return }
        draft = ""
        onSend(text)
    }

    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 对话面板中的一轮：用户的话靠右，结果、写入的流水和操作靠左。
private struct VoiceConversationTurnView: View {
    @Environment(\.locale) private var locale

    /// 当前会话。
    let session: VoiceSession

    /// 这一轮。
    let turn: VoiceSession.Turn

    /// 打开一笔流水的详情。
    let onOpenTransaction: (UUID) -> Void

    /// 带着这句话去手动记账。
    let onManualEntry: (String) -> Void

    /// 去登录。
    let onSignIn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(turn.userText)
                .font(.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .strikethrough(turn.isUndone)

            VStack(alignment: .leading, spacing: 8) {
                if turn.outcome == .processing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(text("voice.processing")).font(.subheadline)
                    }
                } else if let result = turn.resultText(locale: locale) {
                    Text(result)
                        .font(.subheadline)
                        .foregroundStyle(turn.failure == nil ? Color.primary : Color(.ledgerRed))
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(turn.changes) { change in
                    Button {
                        onOpenTransaction(change.transactionID)
                    } label: {
                        VoiceEntryChangeRow(change: change, isUndone: turn.isUndone)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(change.kind == .deleted || turn.isUndone)
                }
                if case let .ask(_, options) = turn.outcome, !options.isEmpty, session.latestTurn?.id == turn.id {
                    VoiceAskOptionsView(options: options, isEnabled: !session.isProcessing) { option in
                        Task { await session.send(option.label, selectedOption: option) }
                    }
                }
                actions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var actions: some View {
        let isLatest = session.latestTurn?.id == turn.id
        let isUndoable = session.undoableTurn?.id == turn.id
        HStack(spacing: 12) {
            if turn.isUndone {
                Label(text("voice.turn.undone"), systemImage: "arrow.uturn.backward")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if isLatest, turn.failure?.requiresSignIn == true {
                Button(text("voice.signIn.action"), action: onSignIn)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else if isLatest, turn.offersManualEntry {
                Button(text("voice.turn.manualEntry")) { onManualEntry(turn.userText) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            if isUndoable {
                Button(text("voice.turn.undo")) { session.undoLatestTurn() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}
