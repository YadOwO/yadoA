import SwiftData
import SwiftUI
import UIKit

/// 记账页底部的语音记账区域：麦克风按钮和它上方唯一的会话卡片，并负责登录、权限提示与详情、手动记账弹层。
///
/// 只有按住说话一种输入方式，没有轻点和打字。会话在离开记账页、关闭卡片或闲置约 2 分钟后结束。
struct VoiceBookkeepingDock: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AuthStore.self) private var authStore
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    /// 麦克风按钮（含上下留白）占用的高度变化时回调，首页据此给列表末尾留白。
    let onButtonHeightChange: (CGFloat) -> Void

    @State private var session: VoiceSession?
    @State private var input = VoiceInputController()
    @State private var presentedTransaction: VoicePresentedTransaction?
    @State private var manualEntryNote: VoiceManualEntryNote?

    /// 识别时优先识别的账户名、分类名；进入记账页时读一次，按下时不再查库，避免卡住按下后的第一帧。
    @State private var contextualStrings: [String] = []

    var body: some View {
        VStack(spacing: 10) {
            if isCardVisible {
                VoiceSessionCard(
                    session: session,
                    input: input,
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
                onText: send,
                onAccessibilityToggle: toggleRecording
            )
            // 没识别到话或刚授权时的提示：麦克风正上方的一个小标签，不撑开卡片、不影响布局
            .overlay(alignment: .top) {
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
            .padding(.vertical, 12)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                onButtonHeightChange(height)
            }
        }
        .padding(.horizontal, 16)
        .animation(.easeOut(duration: 0.2), value: isCardVisible)
        .animation(.easeOut(duration: 0.2), value: input.isRecording)
        .animation(.easeOut(duration: 0.2), value: session?.latestTurn)
        .animation(.easeOut(duration: 0.2), value: input.transientHint)
        .task {
            if session == nil {
                session = VoiceSession(
                    container: modelContext.container,
                    api: VoiceSessionAPI { [authStore] in try await authStore.accessTokenForAIService() },
                    locale: locale,
                    calendar: calendar
                )
            }
            // 账户、分类只能在别的页面修改，回到记账页时会重新执行这里
            contextualStrings = session?.currentContext().contextualStrings ?? []
        }
        .onChange(of: locale) { _, newValue in session?.locale = newValue }
        .onChange(of: calendar) { _, newValue in session?.calendar = newValue }
        // 一次性提示展示一会儿后自动消失；换了新提示时重新计时
        .task(id: input.transientHint) {
            guard let hint = input.transientHint else { return }
            UIAccessibility.post(notification: .announcement, argument: hint)
            do {
                try await Task.sleep(for: .seconds(Self.hintDuration))
            } catch {
                return
            }
            input.transientHint = nil
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

    /// 是否显示会话卡片：正在说，或本次会话已经有内容。
    private var isCardVisible: Bool {
        input.isRecording || input.isFinishing || session?.isActive == true
    }

    // MARK: - 动作

    /// 按下麦克风：未登录时松手后提示登录，已登录时开始收音。
    private func beginPress() {
        input.pressBegan(
            isSignedIn: authStore.isAuthenticated,
            locale: locale,
            contextualStrings: { contextualStrings }
        )
    }

    /// 无障碍模式下切换收音。
    private func toggleRecording() {
        input.toggleRecording(
            isSignedIn: authStore.isAuthenticated,
            locale: locale,
            contextualStrings: { contextualStrings },
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

    /// 登录；成功后按住麦克风即可继续。
    private func signIn() {
        Task { await authStore.signIn() }
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

/// 按住说话时的提示：登录、权限、识别不可用。
private struct VoiceInputAlertModifier: ViewModifier {
    @Environment(\.locale) private var locale

    /// 按住说话的交互逻辑，提示来自它的 `alert`。
    let input: VoiceInputController

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
