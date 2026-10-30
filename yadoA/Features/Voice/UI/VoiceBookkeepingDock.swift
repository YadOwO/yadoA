import SwiftData
import SwiftUI
import UIKit

/// 一级页面底部的语音记账区域：唯一的会话卡片、悬浮麦克风和一次性提示。
///
/// 主要靠按住说话，不方便出声时可以点旁边的键盘改为打字（见 `VoiceTextInputSheet`）。四个一级页面各挂一份，共用根导航持有的同一个会话，切换 Tab 时卡片跟过去；
/// 会话在当前页面往下进入二级页面、关闭卡片或闲置约 2 分钟后结束；切到停在二级页面的 Tab 时会话保留，卡片随页面收起。创建会话、计时、播报和弹层只需要一份，由 `voiceBookkeepingHost(_:)` 挂在根导航上。
/// 麦克风放进 Tab Bar 附属栏时（见 `VoiceMicPlacement`），这里只显示卡片和提示，麦克风由 `VoiceMicAccessory` 显示。
struct VoiceBookkeepingDock: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SignInPresentation.self) private var signInPresentation
    @Environment(AuthStore.self) private var authStore
    @Environment(VoiceBookkeepingState.self) private var voice
    @Environment(\.locale) private var locale

    /// 麦克风按钮（含上下留白）占用的高度变化时回调，页面据此给列表末尾留白；麦克风在附属栏里时为 0。
    let onButtonHeightChange: (CGFloat) -> Void

    /// 语音区域（铺满页面内容区）底边在窗口中的位置，用来算它与附属栏的重叠。
    @State private var dockMaxY: CGFloat?

    /// 麦克风是否放在 Tab Bar 附属栏里，而不是悬浮在这里。
    private let isMicInAccessory = VoiceMicPlacement.usesTabBarAccessory

    private var session: VoiceSession? { voice.session }
    private var input: VoiceInputController { voice.input }

    var body: some View {
        VStack(spacing: 10) {
            // 提示参与布局；短按时没有卡片和悬浮按钮，也要保留完整高度，避免空栈上的 overlay 落入附属栏。
            transientHint

            if isCardVisible {
                VoiceSessionCard(
                    session: session,
                    input: input,
                    onLocateChange: { voice.pendingLocate = $0 },
                    onOpenTransaction: { voice.presentedTransaction = VoicePresentedTransaction(id: $0) },
                    onOpenAccount: { voice.presentedAccount = VoicePresentedAccount(id: $0) },
                    onManualEntry: { voice.manualEntryNote = VoiceManualEntryNote(text: $0) },
                    onSignIn: { signInPresentation.present(reason: .voiceBookkeeping) },
                    onSwitchModelTier: { voice.isModelTierPresented = true },
                    onEnd: { voice.endSession() }
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if !isMicInAccessory {
                VStack(spacing: 8) {
                    // 麦克风上方轮换示例说法；卡片或一次性提示出现时只隐藏不移除，列表底部留白不跟着跳
                    floatingSpeakingPrompt
                    HStack(spacing: 12) {
                        // 与右侧打字按钮等宽的占位，让麦克风保持居中；不接收触摸，点到这里仍是下面的列表
                        Color.clear
                            .frame(width: VoiceTextInputButton.size, height: VoiceTextInputButton.size)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        VoiceMicButton(
                            controller: input,
                            isProcessing: voice.isProcessing,
                            onPressBegan: { voice.beginPress(isSignedIn: authStore.isAuthenticated, locale: locale) },
                            onText: { voice.send($0) },
                            onAccessibilityToggle: {
                                voice.toggleRecording(isSignedIn: authStore.isAuthenticated, locale: locale)
                            }
                        )
                        VoiceTextInputButton(voice: voice)
                    }
                }
                .padding(.vertical, 12)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    onButtonHeightChange(height)
                }
            }
        }
        // 附属栏不在内容区的安全区里，按实际重叠量抬到附属栏上方
        .padding(.bottom, isMicInAccessory ? Self.accessorySpacing + accessoryOverlap : 0)
        .padding(.horizontal, 16)
        // 铺满页面内容区，卡片外的空白处才能接住点击；空白处本身不参与命中，卡片不显示时不影响列表
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        // 量的是铺满后的外框，不受上面抬高的影响，不会来回触发
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .global).maxY
        } action: { maxY in
            dockMaxY = maxY
        }
        .animation(.easeOut(duration: 0.2), value: accessoryOverlap)
        .background {
            if isOutsideTapDismissEnabled {
                // 卡片外的任何触摸只用来关闭卡片：松手即关，列表不会被点开或滚动
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { _ in voice.endSession() })
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("voice-card-dismiss-area")
            }
        }
        .animation(.easeOut(duration: 0.2), value: isCardVisible)
        .animation(.easeOut(duration: 0.2), value: input.isRecording)
        .animation(.easeOut(duration: 0.2), value: input.transientHint)
        .task {
            if isMicInAccessory {
                // 附属栏计入列表的底部安全区，列表不用再额外留白
                onButtonHeightChange(0)
            }
            // 账户、分类可能在别的页面改过，每次回到一级页面重新读一次
            voice.contextualStrings = VoiceSessionContext.make(
                container: modelContext.container,
                locale: locale
            ).contextualStrings
            input.prepareRecognizer(locale: locale, contextualStrings: voice.contextualStrings)
        }
    }

    /// 麦克风在附属栏里时，卡片和提示与附属栏顶边的间距。
    private static let accessorySpacing: CGFloat = 10

    /// 短按或刚授权时的一次性提示：作为语音区域首项，完整排在卡片或麦克风上方。
    @ViewBuilder
    private var transientHint: some View {
        if let hint = input.transientHint {
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .voiceFloatingSurface(in: Capsule())
                .allowsHitTesting(false)
                .transition(.opacity)
                .accessibilityHidden(true)
        }
    }

    /// 语音区域底边伸到附属栏后面的距离。
    ///
    /// 页面内容区的底部安全区只算 Tab Bar、不算附属栏，按安全区排版的卡片和提示会压在附属栏后面，
    /// 这里用两者在窗口中的实际位置算出重叠部分，整体抬上去；Tab Bar 收起、附属栏下移时随之变化。
    private var accessoryOverlap: CGFloat {
        guard isMicInAccessory, let accessoryMinY = voice.accessoryMinY, let dockMaxY else { return 0 }
        return max(0, dockMaxY - accessoryMinY)
    }

    /// 悬浮麦克风上方的示例说法，告诉用户按住后可以怎么说；会话卡片或一次性提示出现时隐藏。
    private var floatingSpeakingPrompt: some View {
        let isShown = !isCardVisible && input.transientHint == nil
        return VoiceRotatingHoldPrompt(isRotating: isShown && !input.isPressing)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .voiceFloatingSurface(in: Capsule())
            .opacity(isShown ? 1 : 0)
            .allowsHitTesting(false)
            // 麦克风自身的无障碍提示已说明操作方式，示例只做视觉引导
            .accessibilityHidden(true)
    }

    /// 是否显示会话卡片：正在说，或本次会话已经有内容。
    private var isCardVisible: Bool {
        input.isRecording || input.isFinishing || session?.isActive == true
    }

    /// 点卡片外是否关闭卡片：卡片显示且手指没按着麦克风时生效，避免按住说话时另一根手指误触关掉会话。
    private var isOutsideTapDismissEnabled: Bool {
        isCardVisible && !input.isPressing
    }
}

/// 给没有自己留白逻辑的一级页面挂上语音区域：悬浮麦克风的高度计入底部安全区，滚动内容末尾能滚到麦克风上方。
private struct VoiceBookkeepingDockModifier: ViewModifier {
    /// 悬浮麦克风（含上下留白）的高度；麦克风在附属栏里时为 0。
    @State private var micClearance: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: micClearance)
            }
            // 挂在留白外面：卡片和麦克风按原本的安全区贴着 Tab Bar 摆放
            .overlay(alignment: .bottom) {
                VoiceBookkeepingDock { height in
                    micClearance = height
                }
            }
    }
}

extension View {
    /// 在一级页面底部挂上语音记账区域，并给悬浮麦克风留出底部空间。
    ///
    /// 记账页的明细有自己的底部留白，直接使用 `VoiceBookkeepingDock`；其他一级页面用这个修饰符。
    func voiceBookkeepingDock() -> some View {
        modifier(VoiceBookkeepingDockModifier())
    }

    /// 在根导航上挂上语音记账只需要一份的部分，并把语音状态放进环境。
    ///
    /// - Parameter voice: 根导航持有的语音状态。
    func voiceBookkeepingHost(_ voice: VoiceBookkeepingState) -> some View {
        modifier(VoiceBookkeepingHost(voice: voice))
    }
}

/// 语音记账在根导航上只需要一份的部分：创建会话，闲置与提示计时、结果播报与触感，以及卡片打开的弹层和各类提示。
///
/// 会话卡片在每个一级页面各挂一份，这些副作用若跟着卡片走，没显示的 Tab 里也会重复执行，因此统一挂在根导航上。
/// 详情、手动记账和模型选择以弹层盖在当前页面上，不离开一级页面，关掉后会话卡片还在，可以接着说。
private struct VoiceBookkeepingHost: ViewModifier {
    @Environment(\.modelContext) private var modelContext
    @Environment(AuthStore.self) private var authStore
    @Environment(SignInPresentation.self) private var signInPresentation
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    /// 当前账号的 AI 点数；每句话结算后用服务端带回的余额就地更新，每句开始时从这里取模型档位。预览中没有注入时为 nil。
    @Environment(AIPointsStore.self) private var aiPoints: AIPointsStore?

    /// 根导航持有的语音状态。
    @Bindable var voice: VoiceBookkeepingState

    private var session: VoiceSession? { voice.session }

    func body(content: Content) -> some View {
        content
            .environment(voice)
            .task {
                guard voice.session == nil else { return }
                voice.session = VoiceSession(
                    container: modelContext.container,
                    api: VoiceSessionAPI(
                        pointsReporter: { [aiPoints] in aiPoints?.balanceReporter() ?? { _ in } },
                        isTraceConsented: { [aiPoints] in aiPoints?.isTraceConsented ?? false }
                    ) { [authStore] in
                        try await authStore.accessTokenForAIService()
                    },
                    modelTier: { [aiPoints] in aiPoints?.requestTier },
                    locale: locale,
                    calendar: calendar
                )
            }
            .onChange(of: locale) { _, newValue in
                voice.session?.locale = newValue
                voice.input.prepareRecognizer(locale: newValue, contextualStrings: voice.contextualStrings)
            }
            .onChange(of: calendar) { _, newValue in voice.session?.calendar = newValue }
            // 一次性提示展示一会儿后自动消失；换了新提示时重新计时
            .task(id: voice.input.transientHint) {
                guard let hint = voice.input.transientHint else { return }
                UIAccessibility.post(notification: .announcement, argument: hint)
                do {
                    try await Task.sleep(for: .seconds(Self.hintDuration))
                } catch {
                    return
                }
                voice.input.transientHint = nil
            }
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
            .appHaptic(trigger: session?.latestTurn?.outcome) { _, outcome -> AppHaptic? in
                switch outcome {
                case .reply?, .ask?: .success
                case .failed?: .error
                case .processing?, nil: nil
                }
            }
            .sheet(item: $voice.presentedTransaction) { item in
                NavigationStack {
                    BookkeepingTransactionDetailView(transactionID: item.id)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(text("common.done")) { voice.presentedTransaction = nil }
                            }
                        }
                }
            }
            .sheet(item: $voice.presentedAccount) { item in
                NavigationStack {
                    AccountDetailView(accountID: item.id)
                        .toolbar {
                            // 账户详情右侧已有编辑和更多菜单，完成放在左侧
                            ToolbarItem(placement: .topBarLeading) {
                                Button(text("common.done")) { voice.presentedAccount = nil }
                            }
                        }
                }
            }
            .sheet(item: $voice.manualEntryNote) { item in
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
                            Button(text("common.cancel")) { voice.manualEntryNote = nil }
                        }
                    }
                }
            }
            .sheet(isPresented: $voice.isTextInputPresented) {
                VoiceTextInputSheet { voice.send($0) }
            }
            .sheet(isPresented: $voice.isModelTierPresented) {
                NavigationStack {
                    AIModelTierView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(text("common.done")) { voice.isModelTierPresented = false }
                            }
                        }
                }
            }
            .voiceInputAlerts(voice.input) {
                signInPresentation.present(reason: .voiceBookkeeping)
            }
            .alert(text("voice.undo.failed"), isPresented: undoFailureBinding) {
                Button(text("common.close"), role: .cancel) {}
            }
    }

    /// 一次性提示的展示时长（秒）。
    private static let hintDuration: Double = 1.5

    /// VoiceOver 播报本轮结果。
    private func announce(_ outcome: VoiceSession.Turn.Outcome?) {
        guard let turn = session?.latestTurn, outcome != .processing, let text = turn.resultText(locale: locale)
        else { return }
        UIAccessibility.post(notification: .announcement, argument: text)
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

/// 按住说话时的提示：未登录询问是否去登录，以及权限、识别不可用。
private struct VoiceInputAlertModifier: ViewModifier {
    @Environment(\.locale) private var locale

    /// 按住说话的交互逻辑，提示来自它的 `alert`。
    let input: VoiceInputController

    /// 用户在未登录弹窗里选择去登录。
    let onSignIn: () -> Void

    func body(content: Content) -> some View {
        content
            .alert(
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
            get: { input.alert != nil },
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
    ///   - onSignIn: 用户在未登录弹窗里选择去登录。
    func voiceInputAlerts(_ input: VoiceInputController, onSignIn: @escaping () -> Void) -> some View {
        modifier(VoiceInputAlertModifier(input: input, onSignIn: onSignIn))
    }
}

/// 从会话卡片打开详情的流水。
struct VoicePresentedTransaction: Identifiable {
    /// 流水 UUID。
    let id: UUID
}

/// 从会话卡片打开详情的账户。
struct VoicePresentedAccount: Identifiable {
    /// 账户 UUID。
    let id: UUID
}

/// 带着这句话去手动记账时预填的备注。
struct VoiceManualEntryNote: Identifiable {
    /// 稳定标识。
    let id = UUID()

    /// 预填的备注文字。
    let text: String
}
