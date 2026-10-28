import SwiftUI

/// 麦克风上方唯一的语音记账卡片：本次会话的每一轮和正在说的这句话的实时转写都在这里。
///
/// 内容超过最大高度时在卡片里滚动，有新内容时自动滚到底部；用户正在拖动或惯性滚动时不抢，停下后再滚。
struct VoiceSessionCard: View {
    @Environment(\.locale) private var locale

    /// 当前会话；还没创建时只显示实时转写。
    let session: VoiceSession?

    /// 按住说话的交互逻辑，提供实时转写。
    let input: VoiceInputController

    /// 在记账页明细里定位一笔流水；不在记账页时先切过去。
    let onLocateChange: (VoiceEntryChange) -> Void

    /// 打开一笔流水的详情。
    let onOpenTransaction: (UUID) -> Void

    /// 打开一个账户的详情。
    let onOpenAccount: (UUID) -> Void

    /// 带着这句话去手动记账。
    let onManualEntry: (String) -> Void

    /// 去登录。
    let onSignIn: () -> Void

    /// 结束会话。
    let onEnd: () -> Void

    /// 滚动区域的最大高度，超出部分在卡片里滚动查看；一般一句话就能记完，不会用满。
    private static let maxScrollHeight: CGFloat = 300

    /// 卡片内容的实际高度，用来让卡片在最大高度以内贴合内容。
    @State private var contentHeight: CGFloat = 0

    /// 最近一次完成布局的真实滚动几何，用来确认最新内容确实已完整露出。
    @State private var scrollGeometry = VoiceCardScrollGeometry()

    /// 用户是否正在拖动卡片内容或内容还在惯性滚动；期间不自动滚动，避免和手指抢位置。
    @State private var isUserScrolling = false

    /// 是否跟随最新内容；手动翻阅时暂停，任何内容或布局更新都会恢复，拖动期间等停手再执行。
    @State private var followsLatestContent = true

    /// 内容末尾的稳定锚点，放在明细、操作按钮和底部留白之后。
    private enum ScrollTarget: Hashable {
        case bottom
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        content
                        Color.clear
                            .frame(height: 1)
                            .id(ScrollTarget.bottom)
                            .accessibilityHidden(true)
                    }
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        contentHeight = height
                    }
                }
                .frame(height: min(contentHeight, Self.maxScrollHeight))
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .onScrollGeometryChange(for: VoiceCardScrollGeometry.self) { geometry in
                    VoiceCardScrollGeometry(
                        contentHeight: geometry.contentSize.height,
                        containerHeight: geometry.containerSize.height,
                        offsetY: geometry.contentOffset.y,
                        topInset: geometry.contentInsets.top,
                        bottomInset: geometry.contentInsets.bottom
                    )
                } action: { old, new in
                    scrollGeometry = new
                    if new.hasDifferentLayout(from: old) {
                        followsLatestContent = true
                    }
                    // 同时检查真实偏移；系统后续布局若又改变了位置，会再次校正，而不是把发出请求当成完成。
                    scrollToBottom(using: proxy, geometry: new)
                }
                // 文字或状态替换未必改变高度，仍需恢复跟随最新内容。
                .onChange(of: scrollContent, initial: true) { _, _ in
                    followsLatestContent = true
                    scrollToBottom(using: proxy, geometry: scrollGeometry)
                }
                .onScrollPhaseChange { _, phase in
                    let wasUserScrolling = isUserScrolling
                    isUserScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                    if isUserScrolling, !wasUserScrolling {
                        followsLatestContent = false
                    } else if !isUserScrolling {
                        scrollToBottom(using: proxy, geometry: scrollGeometry)
                    }
                }
                // 对话的内容高度和滚动位置必须在同一次布局中落定，不能继承外层显隐、录音或结果动画。
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
        }
        .padding(.top, 6)
        .voiceFloatingSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// 布局完成后滚到真正的内容末尾；已经贴底就不再发出请求，避免滚动反馈循环。
    ///
    /// - Parameters:
    ///   - proxy: 当前滚动区域的命令入口，每次调用都定位末尾锚点。
    ///   - geometry: 当前已生效的内容尺寸、可视高度和偏移。
    private func scrollToBottom(using proxy: ScrollViewProxy, geometry: VoiceCardScrollGeometry) {
        guard followsLatestContent, !isUserScrolling, geometry.containerHeight > 0, !geometry.isAtBottom else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(ScrollTarget.bottom, anchor: .bottom)
        }
    }

    /// 完整的显示内容；任何一轮、实时转写或交互状态更新，都统一请求贴底。
    private var scrollContent: VoiceCardScrollContent {
        VoiceCardScrollContent(
            turns: session?.turns ?? [],
            isProcessing: session?.isProcessing == true,
            transcript: input.recognizer.transcript,
            isRecording: input.isRecording,
            isFinishing: input.isFinishing,
            isCancelArmed: input.isCancelArmed,
            locale: locale
        )
    }

    /// 标题与结束按钮。
    private var header: some View {
        HStack(spacing: 8) {
            Label(text("voice.conversation.title"), systemImage: "waveform")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            #if DEBUG
            // 连本地 AI 服务时标出来，免得把本地结果当成线上
            if AIServiceEnvironment.current == .local {
                Text(text("debug.aiService.local"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15), in: Capsule())
            }
            #endif
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
                        onLocateChange: onLocateChange,
                        onOpenTransaction: onOpenTransaction,
                        onOpenAccount: onOpenAccount,
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
                    isCancelArmed: input.isCancelArmed,
                    // 只在会话第一句给示例；后续轮次多是回答追问或接着改，示例反而打岔
                    showsExamples: session?.isActive != true
                )
            }
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

    /// 在记账页明细里定位一笔流水；不在记账页时先切过去。
    let onLocateChange: (VoiceEntryChange) -> Void

    /// 打开一笔流水的详情。
    let onOpenTransaction: (UUID) -> Void

    /// 打开一个账户的详情。
    let onOpenAccount: (UUID) -> Void

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
                switch change {
                case let .entry(entryChange):
                    entryRow(entryChange)
                case let .account(accountChange):
                    accountRow(accountChange)
                }
            }
            // DEBUG 包与 TestFlight 包显示这句话的耗时，点开看每一步
            if VoiceTimingFeature.isEnabled, let timing = turn.timing {
                VoiceTurnTimingView(timing: timing)
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

    /// 一笔收支流水的改动：点行在记账页明细里定位它（不在记账页时先切过去），行尾打开详情。
    private func entryRow(_ change: VoiceEntryChange) -> some View {
        // 删除或撤销后流水已不存在，既无法定位也没有详情可看
        let isAvailable = change.kind != .deleted && !turn.isUndone
        return HStack(spacing: 2) {
            // 点一笔就在记账页明细里定位它，卡片跟着过去；一句话改了好几笔时逐笔点着看
            Button {
                onLocateChange(change)
            } label: {
                VoiceEntryChangeRow(change: change, isUndone: turn.isUndone)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isAvailable)
            .accessibilityHint(isAvailable ? Text(text("voice.change.locate.hint")) : Text(verbatim: ""))

            // 卡片外的点击会关闭会话，详情入口放在行尾；不可用时保留占位，各行金额仍然对齐
            Button {
                onOpenTransaction(change.transactionID)
            } label: {
                Image(systemName: "info.circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isAvailable)
            .opacity(isAvailable ? 1 : 0)
            .accessibilityHidden(!isAvailable)
            .accessibilityLabel(AccountLocalization.formatted(
                "voice.change.detail.accessibility", value: change.label, locale: locale
            ))
        }
    }

    /// 一次账户相关的改动：余额调整、转账与账户改动不在记账页明细里，点整行以弹层打开账户详情，转账时打开转出账户。
    private func accountRow(_ change: VoiceAccountChange) -> some View {
        // 删除或撤销后账户可能已不存在，不再打开详情
        let accountID = turn.isUndone ? nil : change.accountIDs.first
        return Button {
            if let accountID {
                onOpenAccount(accountID)
            }
        } label: {
            HStack(spacing: 2) {
                VoiceAccountChangeRow(change: change, isUndone: turn.isUndone)
                // 与流水行尾的详情按钮同宽同样式；不可用时保留占位，各行金额仍然对齐
                Image(systemName: "info.circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .opacity(accountID == nil ? 0 : 1)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(accountID == nil)
        .accessibilityHint(accountID == nil ? Text(verbatim: "") : Text(text("voice.change.account.hint")))
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

    /// 还没识别到文字时是否列出示例说法。
    var showsExamples = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            VoiceUserBubble(
                text: transcript.isEmpty ? text("voice.recording.listening") : transcript,
                isPlaceholder: transcript.isEmpty
            )
            .opacity(isCancelArmed ? 0.45 : 1)
            .contentTransition(.interpolate)
            if showsExamples, transcript.isEmpty, isRecording, !isCancelArmed {
                VoiceSpeakingExamples()
                    .padding(.top, 4)
            }
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

/// 卡片实际展示的数据快照，补足同高度内容更新时不会触发布局回调的情况。
private struct VoiceCardScrollContent: Equatable {
    /// 全部轮次，包括处理中、回复、追问、失败、流水变更及撤销状态。
    let turns: [VoiceSession.Turn]

    /// 控制候选项与撤销操作是否可用。
    let isProcessing: Bool

    /// 正在识别的文字。
    let transcript: String

    /// 是否正在收音。
    let isRecording: Bool

    /// 是否正在等待最终识别结果。
    let isFinishing: Bool

    /// 是否展示松手取消提示。
    let isCancelArmed: Bool

    /// 提示与结果使用的语言。
    let locale: Locale
}

/// 卡片完成布局后的滚动几何；包含真实偏移，才能验证滚动请求执行后的最终位置。
struct VoiceCardScrollGeometry: Equatable {
    /// 内容高度。
    var contentHeight: CGFloat = 0

    /// 可视高度。
    var containerHeight: CGFloat = 0

    /// 当前纵向偏移。
    var offsetY: CGFloat = 0

    /// 顶部内容边距。
    var topInset: CGFloat = 0

    /// 底部内容边距。
    var bottomInset: CGFloat = 0

    /// 真正的底部偏移；短内容的顶部和底部是同一位置。
    var bottomOffset: CGFloat {
        max(-topInset, contentHeight - containerHeight + bottomInset)
    }

    /// 是否已经完整露出最后一项，允许 1 pt 以内的取整误差。
    var isAtBottom: Bool {
        abs(offsetY - bottomOffset) <= 1
    }

    /// 内容、容器或边距变化时恢复贴底；仅手动改变偏移不会中断历史翻阅。
    func hasDifferentLayout(from other: Self) -> Bool {
        contentHeight != other.contentHeight || containerHeight != other.containerHeight
            || topInset != other.topInset || bottomInset != other.bottomInset
    }
}
