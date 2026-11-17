import SwiftUI

/// 锁屏：纸色底、品牌标记、标题和一个「解锁」按钮。
///
/// 不显示任何金额或账本内容；验证被取消或失败后停在这里，用户点按钮重新发起系统验证。
/// 浅色和深色外观都用 Asset 里的动态色。
struct AppLockScreen: View {
    @Environment(\.locale) private var locale

    /// 应用锁状态机；解锁按钮通过它发起验证。
    let controller: AppLockController

    var body: some View {
        ZStack {
            Color(.paperBackground)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Image(.brandMark)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)

                Text(text("app_lock.locked.title"))
                    .font(.system(.title3, design: .serif, weight: .semibold))
                    .multilineTextAlignment(.center)

                Button {
                    Task { await controller.unlock() }
                } label: {
                    Label(text("app_lock.unlock"), systemImage: "lock.open")
                        .font(.body.weight(.medium))
                        .frame(minWidth: 140)
                        .onAccentForeground()
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(controller.isAuthenticating)
                .accessibilityIdentifier("app-lock-unlock")
            }
            .padding(24)
        }
        // 用 contain 让根视图成为独立的无障碍容器：既有自己的标识，又不挡住里面的按钮
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("app-lock-screen")
    }

    /// 按应用当前语言取文案。
    ///
    /// - Parameter key: 本地化键。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// App 切换器遮挡：开了应用锁、App 进入非活跃或后台时盖住界面，系统截图里看不到金额。
///
/// 品牌色打底加品牌图标，不显示任何账本内容；颜色用 Asset 里的动态色，浅色和深色外观都适用。
struct AppPrivacyCover: View {
    @Environment(\.locale) private var locale

    var body: some View {
        ZStack {
            Color.accentColor
                .ignoresSafeArea()

            Image(.brandMark)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .onAccentForeground()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AccountLocalization.string("app_lock.privacy_cover.label", locale: locale))
        .accessibilityIdentifier("app-privacy-cover")
    }
}

#Preview("锁屏") {
    AppLockScreen(
        controller: AppLockController(
            authenticator: PreviewAuthenticator(),
            localizedReason: { "Unlock" }
        )
    )
}

#Preview("遮挡") {
    AppPrivacyCover()
}

/// 仅供预览使用的验证器：恒可用、恒通过。
private struct PreviewAuthenticator: AppLockAuthenticating {
    func availability() -> AppLockAvailability { .available }

    func authenticate(localizedReason: String) async -> AppLockAuthenticationResult { .success }
}
