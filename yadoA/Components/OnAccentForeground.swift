import SwiftUI

/// 强调色实底上的前景色。
///
/// 强调色是墨色：浅色外观下为深墨、深色外观下为纸白。系统实底按钮默认始终使用白字，
/// 深色外观下会落在纸白底上看不清，因此实底按钮的标签需要显式跟随外观切换。
private struct OnAccentForeground: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        // 禁用态的按钮底色由系统改为灰色，前景同步退回系统的禁用文字色。
        content.foregroundStyle(isEnabled ? Color(.onAccent) : Color(uiColor: .tertiaryLabel))
    }
}

extension View {
    /// 让放在强调色实底上的文字和图标在浅色、深色外观下都保持足够对比度。
    func onAccentForeground() -> some View {
        modifier(OnAccentForeground())
    }
}
