import SwiftData
import SwiftUI
import UIKit

/// 记账页底部的语音记账区域：唯一的会话卡片和麦克风按钮，并负责登录、权限提示与详情、手动记账弹层。
///
/// 只有按住说话一种输入方式，没有轻点和打字。会话在离开记账页、关闭卡片或闲置约 2 分钟后结束。
/// 麦克风放进 Tab Bar 附属栏时（见 `VoiceMicPlacement`），这里只显示卡片和提示，麦克风由 `VoiceMicAccessory` 显示。
struct VoiceBookkeepingDock: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AuthStore.self) private var authStore
    @Environment(SignInPresentation.self) private var signInPresentation
    @Environment(VoiceBookkeepingState.self) private var voice
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    /// 点选卡片上的一笔流水时回调，由首页切到对应月份并滚过去。
    let onLocateChange: (VoiceEntryChange) -> Void

    /// 麦克风按钮（含上下留白）占用的高度变化时回调，首页据此给列表末尾留白；麦克风在附属栏里时为 0。
    let onButtonHeightChange: (CGFloat) -> Void

    @State private var presentedTransaction: VoicePresentedTransaction?
    @State private var manualEntryNote: VoiceManualEntryNote?

    /// 麦克风是否放在 Tab Bar 附属栏里，而不是悬浮在这里。
    private let isMicInAccessory = VoiceMicPlacement.usesTabBarAccessory

    private var session: VoiceSession? { voice.session }
    private var input: VoiceInputController { voice.input }

    var body: some View {
        VStack(spacing: 10) {
            if isCardVisible {
                VoiceSessionCard(
                    session: session,
                    input: input,
                    onLocateChange: onLocateChange,
                    onOpenTransaction: { presentedTransaction = VoicePresentedTransaction(id: $0) },
                    onManualEntry: { manualEntryNote = VoiceManualEntryNote(text: $0) },
                    onSignIn: signIn,
                    onEnd: endSession
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if !isMicInAccessory {
                VStack(spacing: 8) {
                    // 麦克风上方轮换示例说法；卡片或一次性提示出现时只隐藏不移除，列表底部留白不跟着跳
                    floatingSpeakingPrompt
                    VoiceMicButton(
                        controller: input,
                        isProcessing: voice.isProcessing,
                        onPressBegan: beginPress,
                        onText: { voice.send($0) },
                        onAccessibilityToggle: toggleRecording
                    )
                    // 没识别到话或刚授权时的提示：麦克风正上方的一个小标签，不撑开卡片、不影响布局
                    .overlay(alignment: .top) {
                        transientHint
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
        // 麦克风在附属栏里时，提示挂在卡片上方；没有卡片时就在附属栏正上方
        .overlay(alignment: .top) {
            if isMicInAccessory {
                transientHint
            }
        }
        .padding(.bottom, isMicInAccessory ? 10 : 0)
        .padding(.horizontal, 16)
        // 铺满首页内容区，卡片外的空白处才能接住点击；空白处本身不参与命中，卡片不显示时不影响列表
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background {
            if isOutsideTapDismissEnabled {
                // 卡片外的任何触摸只用来关闭卡片：松手即关，列表不会被点开或滚动
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { _ in endSession() })
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
            if voice.session == nil {
                voice.session = VoiceSession(
                    container: modelContext.container,
                    api: VoiceSessionAPI { [authStore] in try await authStore.accessTokenForAIService() },
                    locale: locale,
                    calendar: calendar
                )
            }
            // 账户、分类只能在别的页面修改，回到记账页时会重新执行这里
            voice.contextualStrings = session?.currentContext().contextualStrings ?? []
            input.prepareRecognizer(locale: locale, contextualStrings: voice.contextualStrings)
        }
        .onChange(of: locale) { _, newValue in
            voice.session?.locale = newValue
            input.prepareRecognizer(locale: newValue, contextualStrings: voice.contextualStrings)
        }
        .onChange(of: calendar) { _, newValue in voice.session?.calendar = newValue }
        // 一次性提示展示一会儿后自动消失；换了新提示时重新计时
        .task(id: input.transientHint) {
            guard let hint = input.transientHint else { return }
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
        .sensoryFeedback(trigger: session?.latestTurn?.outcome) { _, outcome in
            switch outcome {
            case .reply?, .ask?: .success
            case .failed?: .error
            case .processing?, nil: nil
            }
        }
        .onDisappear {
            // 离开记账页即结束会话；详情与手动记账都是盖在首页上的弹层，不会触发这里
            endSession()
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
        .voiceInputAlerts(input, onSignIn: signIn)
        .alert(text("voice.undo.failed"), isPresented: undoFailureBinding) {
            Button(text("common.close"), role: .cancel) {}
        }
    }

    /// 一次性提示的展示时长（秒）。
    private static let hintDuration: Double = 1.5

    /// 没识别到话或刚授权时的一次性提示：贴在所在视图正上方的小标签，不参与布局。
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
                .alignmentGuide(.top) { $0[.bottom] + 8 }
                .allowsHitTesting(false)
                .transition(.opacity)
                .accessibilityHidden(true)
        }
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

    // MARK: - 动作

    /// 按下麦克风：未登录时松手后打开登录页，已登录时开始收音。
    private func beginPress() {
        voice.beginPress(isSignedIn: authStore.isAuthenticated, locale: locale)
    }

    /// 无障碍模式下切换收音。
    private func toggleRecording() {
        voice.toggleRecording(isSignedIn: authStore.isAuthenticated, locale: locale)
    }

    /// 结束会话，同时作废还在收尾的语音输入。
    private func endSession() {
        voice.endSession()
    }

    /// 打开整屏登录页并说明语音记账为什么要登录；登录成功回到记账页后按住麦克风即可继续。
    private func signIn() {
        signInPresentation.present(reason: .voiceBookkeeping)
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
            set: { if !$0 { voice.session?.hasUndoFailure = false } }
        )
    }

    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 按住说话时的提示：权限、识别不可用；未登录时不弹提示，直接打开登录页。
private struct VoiceInputAlertModifier: ViewModifier {
    @Environment(\.locale) private var locale

    /// 按住说话的交互逻辑，提示来自它的 `alert`。
    let input: VoiceInputController

    /// 去登录。
    let onSignIn: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: input.isSignInRequested) { _, isRequested in
                guard isRequested else { return }
                input.isSignInRequested = false
                onSignIn()
            }
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
        case .permissionDenied: text("voice.permission.title")
        case .unsupported: text("voice.error.unsupported")
        case .microphoneUnavailable: text("voice.error.microphoneUnavailable")
        }
    }

    private func alertMessage(for alert: VoiceInputAlert) -> String? {
        switch alert {
        case .permissionDenied: text("voice.permission.message")
        case .unsupported, .microphoneUnavailable: nil
        }
    }

    @ViewBuilder
    private func alertActions(for alert: VoiceInputAlert) -> some View {
        switch alert {
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
    ///   - onSignIn: 去登录。
    func voiceInputAlerts(_ input: VoiceInputController, onSignIn: @escaping () -> Void) -> some View {
        modifier(VoiceInputAlertModifier(input: input, onSignIn: onSignIn))
    }
}

/// 从会话卡片打开详情的流水。
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
