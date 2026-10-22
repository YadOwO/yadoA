import Observation
import SwiftUI

/// 打开登录页的原因；有原因时登录页在标语下多一行说明，告诉用户为什么要登录。
enum SignInReason: Equatable {
    /// 未登录时使用语音记账。
    case voiceBookkeeping

    /// 登录页上的说明文案键。
    var messageLocalizationKey: String {
        switch self {
        case .voiceBookkeeping:
            "voice.signIn.message"
        }
    }
}

/// 登录页的展示状态：任何页面需要登录时调用 `present(reason:)`，由应用根视图统一盖上登录页。
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

    /// 打开登录页。
    ///
    /// - Parameter reason: 打开原因，用于在登录页上说明为什么需要登录。
    func present(reason: SignInReason? = nil) {
        self.reason = reason
        isPresented = true
    }

    /// 关闭登录页，回到打开前的界面。
    func dismiss() {
        isPresented = false
    }
}

/// 在应用根视图上整屏盖上登录页，淡入淡出，不带 sheet 的卡片外观。
private struct SignInPageHost: ViewModifier {
    @Environment(SignInPresentation.self) private var presentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        ZStack {
            content
                // 登录页盖住时，底下的界面不再响应 VoiceOver
                .accessibilityHidden(presentation.isPresented)

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
}

extension View {
    /// 挂上整屏登录页；只在应用根视图调用一次。
    func signInPageHost() -> some View {
        modifier(SignInPageHost())
    }
}
