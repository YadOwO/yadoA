import SwiftUI

// 轻提示：操作成功、验证码已发出、暂未开放这类不用用户回应的反馈，浮出一个小胶囊，几秒后自己收起，轻点也能提前收起。
//
// 只说一句话。要用户做决定、或者内容必须读完的（确认删除、撤销后还能保留几天、失败原因要细看）仍用 alert 或页内说明。
// 触感不在这里统一发：同一个动作只震一次，由调用方按 `AppHaptics` 的规则决定要不要震。

/// 一条轻提示。
///
/// 每条都有自己的 `id`：连着弹两条文案相同的提示（如连续重发验证码）时也会重新弹出、重新计时，
/// 自动收起只收掉自己那一条，不会误收后来替换上的新提示。
struct AppToast: Identifiable, Equatable {
    /// 提示的语气，决定图标颜色、文字颜色和停留时长。
    enum Style: Equatable {
        /// 操作成功：墨色图标，正文用主文字色。
        case success
        /// 中性说明：次要色图标，正文用主文字色。
        case info
        /// 操作失败：图标和正文都用账本红，停留更久。
        case error
    }

    /// 区分每一条提示。
    let id = UUID()

    /// 已本地化的提示文字。
    let message: String

    /// 语气。
    let style: Style

    /// 行首的系统图标；nil 时只显示文字。
    let systemImage: String?

    /// 无障碍标识，UI 测试据此定位。
    let accessibilityIdentifier: String

    /// 停留时长：失败的提示通常带原因，多留一会儿；其余 2.5 秒。
    var duration: Duration {
        style == .error ? .seconds(4) : .milliseconds(2500)
    }

    /// 操作成功的提示，默认带对勾。
    ///
    /// - Parameters:
    ///   - message: 已本地化的提示文字。
    ///   - systemImage: 行首图标，默认对勾。
    ///   - accessibilityIdentifier: 无障碍标识，默认 `app-toast`。
    static func success(
        _ message: String,
        systemImage: String = "checkmark.circle.fill",
        accessibilityIdentifier: String = "app-toast"
    ) -> AppToast {
        AppToast(message: message, style: .success, systemImage: systemImage, accessibilityIdentifier: accessibilityIdentifier)
    }

    /// 中性说明，默认不带图标。
    ///
    /// - Parameters:
    ///   - message: 已本地化的提示文字。
    ///   - systemImage: 行首图标；nil 时只显示文字。
    ///   - accessibilityIdentifier: 无障碍标识，默认 `app-toast`。
    static func info(
        _ message: String,
        systemImage: String? = nil,
        accessibilityIdentifier: String = "app-toast"
    ) -> AppToast {
        AppToast(message: message, style: .info, systemImage: systemImage, accessibilityIdentifier: accessibilityIdentifier)
    }

    /// 操作失败的提示，默认带感叹号。
    ///
    /// - Parameters:
    ///   - message: 已本地化的提示文字，可以换行带上原因。
    ///   - systemImage: 行首图标，默认感叹号；nil 时只显示文字。
    ///   - accessibilityIdentifier: 无障碍标识，默认 `app-toast`。
    static func error(
        _ message: String,
        systemImage: String? = "exclamationmark.circle.fill",
        accessibilityIdentifier: String = "app-toast"
    ) -> AppToast {
        AppToast(message: message, style: .error, systemImage: systemImage, accessibilityIdentifier: accessibilityIdentifier)
    }
}

/// 轻提示浮在哪里。
enum AppToastPlacement: Equatable {
    /// 所修饰视图的顶部（通常是导航栏下方），从上方滑入。弹起的键盘挡不住，页面和弹层默认用这个。
    case top

    /// 浮在所修饰视图的上方，底边离它 `spacing`，从下方浮起；用于登录页按钮区这类贴底的操作区。
    case above(spacing: CGFloat)
}

/// 轻提示的胶囊：可选的图标加一句话；底色 iOS 26 用 Liquid Glass，iOS 18 用材质加投影。
struct AppToastView: View {
    /// 要显示的提示。
    let toast: AppToast

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let systemImage = toast.systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(iconStyle)
                    .accessibilityHidden(true)
            }

            Text(toast.message)
                .foregroundStyle(toast.style == .error ? Color(.ledgerRed) : Color.primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .floatingGlassSurface(in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(toast.accessibilityIdentifier)
    }

    /// 图标颜色：成功用墨色强调色，失败用账本红，说明用次要色。
    private var iconStyle: Color {
        switch toast.style {
        case .success: .accentColor
        case .info: .secondary
        case .error: Color(.ledgerRed)
        }
    }
}

/// 在视图上叠一层轻提示：出现时播报给 VoiceOver，停留 `AppToast.duration` 后自动收起，轻点提前收起。
private struct AppToastPresenter: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 当前的提示；收起时置为 nil。
    @Binding var toast: AppToast?

    /// 浮在哪里。
    let placement: AppToastPlacement

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                ZStack {
                    if let toast {
                        AppToastView(toast: toast)
                            .onTapGesture { dismiss(toast) }
                            .id(toast.id)
                            .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : entryOffset)))
                    }
                }
                // 顶部的离屏幕边缘留出余量；按钮区上方的最宽和按钮区对齐
                .padding(.horizontal, placement == .top ? 24 : 0)
                .padding(.top, placement == .top ? 8 : 0)
                .alignmentGuide(.top) { dimensions in
                    if case let .above(spacing) = placement {
                        return dimensions[.bottom] + spacing
                    }
                    return dimensions[.top]
                }
                .animation(.spring(duration: 0.35, bounce: 0.25), value: toast?.id)
            }
            .task(id: toast?.id) {
                guard let toast else { return }
                AccessibilityNotification.Announcement(toast.message).post()
                try? await Task.sleep(for: toast.duration)
                guard !Task.isCancelled else { return }
                dismiss(toast)
            }
    }

    /// 出现时的位移方向：顶部的从上方滑下，按钮区上方的从下方浮起。
    private var entryOffset: CGFloat {
        placement == .top ? -8 : 8
    }

    /// 收起这一条；已经被新提示替换时不动。
    ///
    /// - Parameter shown: 要收起的提示。
    private func dismiss(_ shown: AppToast) {
        guard toast?.id == shown.id else { return }
        toast = nil
    }
}

extension View {
    /// 在这个视图上显示轻提示：把 `toast` 设为一条新提示就会弹出，到时自动收起并把它置回 nil。
    ///
    /// 页面里加在 `ScrollView` / `List` 这一层（导航栏之内），提示就出现在导航栏下方。
    ///
    /// - Parameters:
    ///   - toast: 当前的提示。
    ///   - placement: 浮在哪里，默认视图顶部。
    func appToast(_ toast: Binding<AppToast?>, placement: AppToastPlacement = .top) -> some View {
        modifier(AppToastPresenter(toast: toast, placement: placement))
    }
}

#Preview("轻提示") {
    @Previewable @State var toast: AppToast?

    NavigationStack {
        VStack(spacing: 16) {
            Button("成功") { toast = .success("身份已验证") }
            Button("说明") { toast = .info("该登录方式即将上线") }
            Button("失败") { toast = .error("登录失败\n网络连接已中断") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .paperPage()
        .navigationTitle("轻提示")
        .navigationBarTitleDisplayMode(.inline)
        .appToast($toast)
    }
}
