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

    /// 打开一笔流水的详情；带着这次改动，详情里还可以去记账页定位它。
    let onOpenTransaction: (VoiceEntryChange) -> Void

    /// 打开一个账户的详情。
    let onOpenAccount: (UUID) -> Void

    /// 带着这句话去手动记账。
    let onManualEntry: (String) -> Void

    /// 去登录。
    let onSignIn: () -> Void

    /// 打开模型选择，换用扣点更少的档位。
    let onSwitchModelTier: () -> Void

    /// 点选的追问候选项交给语音状态发送，好经过 AI 记账说明的同意检查。
    let onSelectOption: (VoiceAskOption) -> Void

    /// 关闭卡片。
    let onEnd: () -> Void

    /// 打开聊天页，查看完整的对话记录。
    var onOpenChat: () -> Void = {}

    /// 这句话因为没有账户没能记上，去新建账户。
    var onCreateAccount: (VoiceSession.Turn) -> Void = { _ in }

    /// 打开周期记账列表，查看语音改过的规则。
    var onOpenRecurringRules: () -> Void = {}

    /// 打开订阅列表，查看语音改过的订阅。
    var onOpenSubscriptions: () -> Void = {}

    /// 用户开始或停止碰卡片时回调：手指按着（点、拖动、长按选字）或内容还在惯性滚动算在碰；碰着时卡片不因闲置收起。
    var onTouchingChange: (Bool) -> Void = { _ in }

    /// 卡片上是否正盖着流水、账户详情或周期记账列表；关掉时重新检查结果行的目标还在不在。
    var isShowingDetail = false

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

    /// 是否有手指按在卡片上，包括按钮、结果行和可选中的文字。
    @State private var isFingerDown = false

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
        .floatingGlassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        // 碰着卡片时闲置计时暂停，松手、滚动停下后重新计时
        .gesture(VoiceCardTouchObserver { isFingerDown = $0 })
        .onChange(of: isFingerDown || isUserScrolling) { _, isTouching in
            onTouchingChange(isTouching)
        }
        // 收起时可能来不及收到松手，按没在碰处理，免得计时一直停着
        .onDisappear { onTouchingChange(false) }
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
            turns: Array(session?.cardTurns ?? []),
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
            Spacer(minLength: 0)
            Button(action: onOpenChat) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(text("voice.chat.view"))
            .accessibilityIdentifier("voice-card-open-chat")
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
                ForEach(session.cardTurns) { turn in
                    VoiceSessionTurnView(
                        session: session,
                        turn: turn,
                        onOpenTransaction: onOpenTransaction,
                        onOpenAccount: onOpenAccount,
                        onManualEntry: onManualEntry,
                        onSignIn: onSignIn,
                        onSwitchModelTier: onSwitchModelTier,
                        onSelectOption: onSelectOption,
                        onCreateAccount: onCreateAccount,
                        onOpenRecurringRules: onOpenRecurringRules,
                        onOpenSubscriptions: onOpenSubscriptions,
                        isShowingDetail: isShowingDetail
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

/// 卡片中的一轮：用户的话靠右，结果、写入的流水和操作靠左；用户的话和结果文字可以长按选中拷贝。
private struct VoiceSessionTurnView: View {
    @Environment(\.locale) private var locale

    /// 当前会话。
    let session: VoiceSession

    /// 这一轮。
    let turn: VoiceSession.Turn

    /// 打开一笔流水的详情；带着这次改动，详情里还可以去记账页定位它。
    let onOpenTransaction: (VoiceEntryChange) -> Void

    /// 打开一个账户的详情。
    let onOpenAccount: (UUID) -> Void

    /// 带着这句话去手动记账。
    let onManualEntry: (String) -> Void

    /// 去登录。
    let onSignIn: () -> Void

    /// 打开模型选择，换用扣点更少的档位。
    let onSwitchModelTier: () -> Void

    /// 点选的追问候选项交给语音状态发送，好经过 AI 记账说明的同意检查。
    let onSelectOption: (VoiceAskOption) -> Void

    /// 这句话因为没有账户没能记上，去新建账户。
    let onCreateAccount: (VoiceSession.Turn) -> Void

    /// 打开周期记账列表。
    let onOpenRecurringRules: () -> Void

    /// 打开订阅列表。
    let onOpenSubscriptions: () -> Void

    /// 卡片上是否正盖着流水、账户详情或周期记账列表；关掉时重新检查结果行的目标还在不在。
    let isShowingDetail: Bool

    /// 「点一下可以查看」的一次性提示状态。
    @State private var tapHint = VoiceResultTapHint.shared

    /// 这一轮涉及的流水、账户和规则里当前仍然存在的那些；`nil` 表示还没查过。
    @State private var existingTargetIDs: Set<UUID>?

    /// 决定何时重新检查结果行目标是否还在的依赖：轮次增减、处理状态、本轮和其他轮次的撤销、详情弹层开关。
    private struct RefreshKey: Equatable {
        let turnCount: Int
        let isProcessing: Bool
        let isUndone: Bool
        /// 会话里已撤销的轮数；撤销后一轮会用原 UUID 把它删掉的记录恢复回来，前面的轮次要重新查。
        let undoneTurnCount: Int
        let isShowingDetail: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 只发图片的一轮没有文字；卡片上不放图片，图片在聊天页看
            VoiceUserBubble(text: turn.userText.isEmpty ? text("voice.chat.image.label") : turn.userText)
                .strikethrough(turn.isUndone)
                .conversationTextSelection()

            if !turn.changes.isEmpty {
                // 有改动时和聊天页用同一张结果纸条：每行带箭头，按下有底色，点行看详情，红色虚线的待确认可以就地改。
                // 卡片的滚动区域关掉了动画，逐行写入的入场动效在这里不播
                let snapshot = AIChatTurnSnapshot(turn: turn, locale: locale)
                AIChatResultSlip(
                    snapshot: snapshot,
                    isFinished: turn.outcome != .processing,
                    animatesEntrance: false,
                    // 还没查过时先当作都在，避免一闪变灰
                    existingTargetIDs: existingTargetIDs ?? Set(snapshot.changes.compactMap(\.targetID)),
                    actions: slipActions,
                    onEntranceFinished: {}
                )
            } else if turn.outcome != .processing, let result = turn.resultText(locale: locale) {
                Text(result)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(turn.failure == nil ? Color.primary : Color(.ledgerRed))
                    .fixedSize(horizontal: false, vertical: true)
                    .conversationTextSelection()
            }
            // 标注是正文的兄弟视图，不放进可选中的文字里；卡片的滚动区域关掉了动画，这里不加过渡
            if showsAIGeneratedLabel {
                AIGeneratedLabel()
            }
            if turn.outcome == .processing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(text("voice.processing")).font(.subheadline)
                }
            }
            // 用户还不知道结果可以点开时，在最新一轮的结果下面写一句；点过一次或看过几次后不再出现
            if showsTapHint {
                Label(text("voice.change.tapHint"), systemImage: "hand.tap")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .onAppear { tapHint.markShown(turnID: turn.id) }
                    .accessibilityIdentifier("voice-change-tap-hint")
            }
            // DEBUG 包显示这句话的耗时；dev 环境点开看每一步，线上环境（DebugProd）只有一行概要
            if VoiceTimingFeature.isEnabled, let timing = turn.timing {
                VoiceTurnTimingView(timing: timing)
            }
            if isLatest, case let .ask(_, options) = turn.outcome, !options.isEmpty {
                VoiceAskOptionsView(options: options, isEnabled: !session.isProcessing) { option in
                    // 会话卡片只在一级页面上，这时语音状态的入口就是快捷语音，点选的回答按快捷语音的模型处理
                    onSelectOption(option)
                }
            }
            VoiceTurnActions(
                session: session,
                turn: turn,
                onManualEntry: onManualEntry,
                onSignIn: onSignIn,
                onSwitchModelTier: onSwitchModelTier,
                onCreateAccount: { onCreateAccount(turn) }
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 后面的轮次或详情弹层里可能删掉这一轮写入的流水、账户或规则，这些时机重新查一次，已不在的行置灰
        .task(
            id: RefreshKey(
                turnCount: session.turns.count,
                isProcessing: session.isProcessing,
                isUndone: turn.isUndone,
                undoneTurnCount: session.turns.lazy.filter(\.isUndone).count,
                isShowingDetail: isShowingDetail
            )
        ) {
            refreshExistingTargets()
        }
    }

    /// 重新查这一轮涉及的流水、账户和规则当前还在不在；没有历史库时（测试、预览）都当作还在。
    private func refreshExistingTargets() {
        guard !turn.changes.isEmpty else { return }
        let snapshot = AIChatTurnSnapshot(turn: turn, locale: locale)
        if let history = session.history {
            existingTargetIDs = history.existingTargetIDs(in: [snapshot])
        } else {
            existingTargetIDs = Set(snapshot.changes.compactMap(\.targetID))
        }
    }

    /// 是否为最近一轮；追问候选项只对最近一轮有意义。
    private var isLatest: Bool {
        session.latestTurn?.id == turn.id
    }

    /// 是否在这一轮结果下面标「由 AI 生成」：已经处理完，并且界面上显示的是模型写的话。
    ///
    /// 失败提示（`isFailed` 来自 `turn.failure`）和用短标题的纸条（含已撤销）不标；判断与聊天页共用 `AIChatCopy.showsModelText`。
    private var showsAIGeneratedLabel: Bool {
        guard turn.outcome != .processing else { return false }
        return AIChatCopy.showsModelText(in: AIChatTurnSnapshot(turn: turn, locale: locale), locale: locale)
    }

    /// 是否在这一轮结果下面提示可以点开：最近一轮、已经处理完、至少有一行能点，并且用户还没学会。
    private var showsTapHint: Bool {
        isLatest && turn.outcome != .processing && hasTappableChange && tapHint.shouldShow(for: turn.id)
    }

    /// 这一轮是否至少有一行结果可以点开；已撤销、只有删除或目标都已不在时没有。
    private var hasTappableChange: Bool {
        guard !turn.isUndone else { return false }
        return turn.changes.contains { change in
            let row = AIChatChangeSnapshot(change: change)
            guard VoiceChangeOpenTarget.resolve(row, in: turn.changes) != nil else { return false }
            // 还没查过存在性时视为存在，和结果纸条一致
            guard let existingTargetIDs else { return true }
            return row.targetID.map { existingTargetIDs.contains($0) } == true
        }
    }

    /// 纸条上能做的事：点行打开详情，就地确认账户。撤销用卡片底部的按钮，纸条上不再放一份。
    private var slipActions: AIChatResultActions {
        var actions = AIChatResultActions(open: { open($0) })
        // 已撤销或正在处理下一句时不能就地改账户，点待确认改为打开详情
        guard !turn.isUndone, !session.isProcessing else { return actions }
        let turnID = turn.id
        actions.confirmAccount = { [session, tapHint] change, accountID in
            tapHint.markLearned()
            return session.confirmInferredAccount(turnID: turnID, changeID: change.id, accountID: accountID)
        }
        actions.accountOptions = { [session] in session.currentContext().accounts }
        return actions
    }

    /// 打开纸条上一行的详情：流水和账户以弹层打开详情，周期记账打开列表；点过一次就不再提示可以点。
    ///
    /// 卡片外的点击会关闭会话，所以详情都以弹层盖在当前页面上，关掉后卡片还在，可以接着说。
    /// - Parameter row: 被点的一行。
    private func open(_ row: AIChatChangeSnapshot) {
        guard let target = VoiceChangeOpenTarget.resolve(row, in: turn.changes) else { return }
        tapHint.markLearned()
        switch target {
        case let .transaction(change): onOpenTransaction(change)
        case let .account(accountID): onOpenAccount(accountID)
        case .recurringRules: onOpenRecurringRules()
        case .subscriptions: onOpenSubscriptions()
        }
    }

    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 一轮可用的操作：撤销、手动记账、登录、换模型、新建账户和重新发送；卡片和聊天页共用。
struct VoiceTurnActions: View {
    @Environment(\.locale) private var locale
    /// 当前账号的 AI 点数，用来判断点数不足时能否换用扣点更少的档位；预览和测试中没有注入时为 nil。
    @Environment(AIPointsStore.self) private var aiPoints: AIPointsStore?

    /// 当前会话。
    let session: VoiceSession

    /// 这一轮。
    let turn: VoiceSession.Turn

    /// 带着这句话去手动记账。
    let onManualEntry: (String) -> Void

    /// 去登录。
    let onSignIn: () -> Void

    /// 打开模型选择，换用扣点更少的档位。
    let onSwitchModelTier: () -> Void

    /// 这句话因为没有账户没能记上，去新建账户。
    let onCreateAccount: () -> Void

    /// 重新发送没能完成的这一轮；只有聊天页提供，打字和图片不重发就没了。
    var onRetry: (() -> Void)?

    /// 是否在这里放撤销按钮；聊天页的撤销在结果纸条上，这里不再重复。
    ///
    /// 撤销后的「已撤销」两边都由结果纸条的标题来写，这里不再放。
    var showsUndo = true

    /// 这里发出的话用哪边的模型：判断点数不够时能否换用更便宜的档位，换模型也打开这一边的选择页。
    var modelScope: AIModelScope = .quickVoice

    /// 是否为最近一轮；登录和手动记账只对最近一轮有意义。
    private var isLatest: Bool {
        session.latestTurn?.id == turn.id
    }

    var body: some View {
        let isUndoable = showsUndo && session.undoableTurn?.id == turn.id
        let requiresSignIn = isLatest && turn.failure?.requiresSignIn == true
        let offersManualEntry = isLatest && turn.offersManualEntry
        // 点数不够所用档位、但够更便宜的档位时，给出换模型的入口；换好后余额够说一句，入口随之消失
        let offersTierSwitch = isLatest && turn.failure == .insufficientPoints
            && aiPoints?.canAffordCheaperTier(for: modelScope) == true
        let offersRetry = isLatest && !session.isProcessing && turn.failure != nil && !requiresSignIn && onRetry != nil
        let offersAccountCreation = isLatest && turn.requiresAccount
        if isUndoable || offersManualEntry || requiresSignIn || offersAccountCreation {
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                if offersAccountCreation {
                    Button(text("voice.turn.createAccount"), action: onCreateAccount)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .onAccentForeground()
                        .disabled(session.isProcessing)
                        .accessibilityIdentifier("voice-create-account")
                } else if requiresSignIn {
                    Button(text("voice.signIn.action"), action: onSignIn)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else if offersManualEntry {
                    if offersTierSwitch {
                        Button(text("voice.turn.switchModelTier"), action: onSwitchModelTier)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityIdentifier("voice-switch-model-tier")
                    }
                    Button(text("voice.turn.manualEntry")) { onManualEntry(turn.userText) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("voice-manual-entry")
                    if offersRetry, let onRetry {
                        Button(text("voice.chat.retry"), action: onRetry)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .onAccentForeground()
                            .accessibilityIdentifier("voice-chat-retry")
                    }
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
struct VoiceLiveTranscript: View {
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
struct VoiceUserBubble: View {
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
            .conversationBubble(.user, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
