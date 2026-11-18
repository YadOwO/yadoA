import Observation
import SwiftUI

/// 打开登录页的原因；有原因时登录页在标语下多一行说明，告诉用户为什么要登录。
enum SignInReason: Equatable {
    /// 未登录时使用语音记账。
    case voiceBookkeeping

    /// 未登录时点「意见反馈」：反馈对话跟着账号走，换设备也能看到回复。
    case feedback

    /// 未登录时点「我的」页的签到。
    case checkIn

    /// 登录页上的说明文案键。
    var messageLocalizationKey: String {
        switch self {
        case .voiceBookkeeping:
            "voice.signIn.message"
        case .feedback:
            "feedback.signIn.message"
        case .checkIn:
            "checkIn.signIn.message"
        }
    }

    /// 「要不要去登录」弹窗的标题文案键；弹窗正文沿用 `messageLocalizationKey`。
    var promptTitleLocalizationKey: String {
        switch self {
        case .voiceBookkeeping:
            "voice.signIn.title"
        case .feedback:
            "feedback.signIn.title"
        case .checkIn:
            "checkIn.signIn.title"
        }
    }
}

/// 登录页的展示状态，由应用根视图统一盖上登录页。
///
/// - 用户点的是功能（签到、意见反馈等）而本身未登录时，调用 `requestSignIn(reason:)`：先弹「登录后才能…」的确认弹窗，
///   用户点「登录」才打开登录页，点「取消」留在原处；与按住说话未登录时的弹窗是同一种交互。
/// - 用户点的本来就是「登录」按钮时，直接调用 `present(reason:)`。
///
/// 登录页既不推入某个 Tab 的导航栈，也不用 sheet 弹出，而是在 Tab 界面之上整屏显示；
/// 底下的 Tab 和各导航栈原样保留，关闭或登录成功后回到原来的位置。
@MainActor
@Observable
final class SignInPresentation {
    /// 是否正在显示登录页。
    private(set) var isPresented = false

    /// 本次打开登录页的原因；从“我的”主动登录时为 nil。
    private(set) var reason: SignInReason?

    /// 正在询问是否去登录的原因；非 nil 时根视图弹出确认弹窗。
    private(set) var pendingPromptReason: SignInReason?

    /// 未登录时点了需要登录的功能：先弹窗询问是否去登录，用户确认后再打开登录页。
    ///
    /// - Parameter reason: 需要登录的原因，决定弹窗文案和登录页上的说明。
    func requestSignIn(reason: SignInReason) {
        pendingPromptReason = reason
    }

    /// 关掉询问弹窗，不打开登录页。
    func cancelSignInPrompt() {
        pendingPromptReason = nil
    }

    /// 打开登录页。
    ///
    /// - Parameter reason: 打开原因，用于在登录页上说明为什么需要登录。
    func present(reason: SignInReason? = nil) {
        pendingPromptReason = nil
        self.reason = reason
        isPresented = true
    }

    /// 关闭登录页，回到打开前的界面。
    func dismiss() {
        isPresented = false
    }
}

/// 在应用根视图上整屏盖上登录页，淡入淡出，不带 sheet 的卡片外观；同时负责「要不要去登录」的确认弹窗。
private struct SignInPageHost: ViewModifier {
    @Environment(SignInPresentation.self) private var presentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale

    func body(content: Content) -> some View {
        ZStack {
            content
                // 登录页盖住时，底下的界面不再响应 VoiceOver
                .accessibilityHidden(presentation.isPresented)
                .alert(
                    presentation.pendingPromptReason.map { text($0.promptTitleLocalizationKey) } ?? "",
                    isPresented: promptBinding,
                    presenting: presentation.pendingPromptReason
                ) { reason in
                    Button(text("voice.signIn.action")) {
                        presentation.present(reason: reason)
                    }
                    Button(text("common.cancel"), role: .cancel) {}
                } message: { reason in
                    Text(text(reason.messageLocalizationKey))
                }

            if presentation.isPresented {
                NavigationStack {
                    SignInView(reason: presentation.reason)
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 1.02)))
                .zIndex(1)
                .accessibilityAddTraits(.isModal)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: presentation.isPresented)
    }

    /// 确认弹窗是否显示；系统关掉弹窗（含点「取消」）时清掉待询问的原因。
    private var promptBinding: Binding<Bool> {
        Binding(
            get: { presentation.pendingPromptReason != nil },
            set: { if !$0 { presentation.cancelSignInPrompt() } }
        )
    }

    /// 按当前语言取文案。
    ///
    /// - Parameter key: 本地化键。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

extension View {
    /// 挂上整屏登录页；只在应用根视图调用一次。
    func signInPageHost() -> some View {
        modifier(SignInPageHost())
    }
}
