import SwiftUI

/// 麦克风上方唯一的语音记账卡片：本次会话的每一轮和正在说的这句话的实时转写都在这里。
///
/// 内容超过最大高度时在卡片里滚动，有新内容时自动滚到底部。
struct VoiceSessionCard: View {
    @Environment(\.locale) private var locale

    /// 当前会话；还没创建时只显示实时转写。
    let session: VoiceSession?

    /// 按住说话的交互逻辑，提供实时转写。
    let input: VoiceInputController

    /// 打开一笔流水的详情。
    let onOpenTransaction: (UUID) -> Void

    /// 带着这句话去手动记账。
    let onManualEntry: (String) -> Void

    /// 去登录。
    let onSignIn: () -> Void

    /// 结束会话。
    let onEnd: () -> Void

    /// 滚动区域的最大高度，超出部分在卡片里滚动查看；一般一句话就能记完，不会用满。
    private static let maxScrollHeight: CGFloat = 300

    /// 滚动区域底部的锚点。
    private static let bottomID = "voice-card-bottom"

    /// 卡片内容的实际高度，用来让卡片在最大高度以内贴合内容。
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    content
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { height in
                            contentHeight = height
                        }
                }
                .frame(height: min(contentHeight, Self.maxScrollHeight))
                .scrollBounceBehavior(.basedOnSize)
                // 新的一轮、转写变长或结果出来时内容都会变高，统一据此滚到底部
                .onChange(of: contentHeight) {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
        }
        .padding(.top, 6)
        .voiceFloatingSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// 标题与结束按钮。
    private var header: some View {
        HStack(spacing: 8) {
            Label(text("voice.conversation.title"), systemImage: "waveform")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button(action: onEnd) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(text("voice.session.close.accessibility"))
            .accessibilityIdentifier("voice-card-close")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
    }

    /// 各轮对话与正在说的这句话。
    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let session {
                ForEach(session.turns) { turn in
                    VoiceSessionTurnView(
                        session: session,
                        turn: turn,
                        onOpenTransaction: onOpenTransaction,
                        onManualEntry: onManualEntry,
                        onSignIn: onSignIn
                    )
                    .id(turn.id)
                }
            }
            // 松手后到这句话发出前也保留转写，避免文字闪一下消失
            if input.isRecording || input.isFinishing {
                VoiceLiveTranscript(
                    transcript: input.recognizer.transcript,
                    isRecording: input.isRecording,
                    isCancelArmed: input.isCancelArmed
                )
            }
            Color.clear
                .frame(height: 0)
                .id(Self.bottomID)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 卡片中的一轮：用户的话靠右，结果、写入的流水和操作靠左。
private struct VoiceSessionTurnView: View {
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
        VStack(alignment: .leading, spacing: 8) {
            VoiceUserBubble(text: turn.userText)
                .strikethrough(turn.isUndone)

            if turn.outcome == .processing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(text("voice.processing")).font(.subheadline)
                }
            } else if let result = turn.resultText(locale: locale) {
                Text(result)
                    .font(.subheadline.weight(.medium))
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
                // 删除或撤销后流水已不存在，没有详情可看
                .disabled(change.kind == .deleted || turn.isUndone)
            }
            if isLatest, case let .ask(_, options) = turn.outcome, !options.isEmpty {
                VoiceAskOptionsView(options: options, isEnabled: !session.isProcessing) { option in
                    Task { await session.send(option.label, selectedOption: option) }
                }
            }
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 是否为最近一轮；追问候选项、登录和手动记账只对最近一轮有意义。
    private var isLatest: Bool {
        session.latestTurn?.id == turn.id
    }

    /// 本轮可用的操作。
    @ViewBuilder
    private var actions: some View {
        let isUndoable = session.undoableTurn?.id == turn.id
        let requiresSignIn = isLatest && turn.failure?.requiresSignIn == true
        let offersManualEntry = isLatest && turn.offersManualEntry
        if isUndoable || offersManualEntry || requiresSignIn || turn.isUndone {
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
                } else if offersManualEntry {
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

/// 正在说的这句话：按住时实时显示转写和上滑取消提示，松手后保留到这句话发出。
private struct VoiceLiveTranscript: View {
    @Environment(\.locale) private var locale

    /// 截至目前的转写文字。
    let transcript: String

    /// 手指是否还按着；松手后不再显示取消提示。
    let isRecording: Bool

    /// 是否已上滑到取消区域。
    let isCancelArmed: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            VoiceUserBubble(
                text: transcript.isEmpty ? text("voice.recording.listening") : transcript,
                isPlaceholder: transcript.isEmpty
            )
            .opacity(isCancelArmed ? 0.45 : 1)
            .contentTransition(.interpolate)
            if isRecording {
                Text(text(isCancelArmed ? "voice.recording.releaseToCancel" : "voice.recording.cancelHint"))
                    .font(.footnote.weight(isCancelArmed ? .semibold : .regular))
                    .foregroundStyle(isCancelArmed ? Color(.ledgerRed) : Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("voice-transcript")
    }

    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 用户说的一句话，靠右的气泡。
private struct VoiceUserBubble: View {
    /// 气泡文字。
    let text: String

    /// 是否为「正在听…」这类占位文字，占位时用次要颜色。
    var isPlaceholder = false

    var body: some View {
        Text(text)
            .font(.body)
            .foregroundStyle(isPlaceholder ? Color.secondary : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
