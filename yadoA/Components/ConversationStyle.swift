import SwiftUI

// 对话类页面（意见反馈、AI 对话、语音卡片）共用的气泡底色和正文选中样式。
//
// 强调色是中性的墨色，系统的选中高亮和手柄默认跟随强调色：落在墨色实心或墨色浅底的气泡上几乎分辨不出。
// 因此气泡一律用浅底，选中改用系统蓝；两者在浅色、深色外观下都和气泡、纸面以及红色的失败文字区分得开。

/// 对话气泡属于哪一方，决定气泡底色。
enum ConversationBubbleRole {
    /// 用户自己说的话：强调色浅底，浅色外观下是淡墨灰，深色外观下是淡纸白。
    case user

    /// 对方的回复，如芽豆团队：纸面卡片色加细描边，和页面背景分开。
    case reply
}

/// 对话气泡底色；形状由各页面决定，底色和描边统一在这里。
private struct ConversationBubbleBackground<BubbleShape: InsettableShape>: ViewModifier {
    /// 气泡属于哪一方。
    let role: ConversationBubbleRole

    /// 气泡形状。
    let shape: BubbleShape

    func body(content: Content) -> some View {
        switch role {
        case .user:
            content.background(Color.accentColor.opacity(0.1), in: shape)
        case .reply:
            content
                .background(Color(.paperSurface), in: shape)
                .overlay {
                    shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
        }
    }
}

extension View {
    /// 给对话气泡加上统一的底色。
    ///
    /// - Parameters:
    ///   - role: 气泡属于哪一方。
    ///   - shape: 气泡形状。
    func conversationBubble(_ role: ConversationBubbleRole, in shape: some InsettableShape) -> some View {
        modifier(ConversationBubbleBackground(role: role, shape: shape))
    }

    /// 对话正文允许长按选中拷贝，选中高亮和手柄用系统蓝，不跟随墨色的强调色。
    ///
    /// iOS 27 起长按出现选择手柄，可以选中一段；iOS 18～26 长按弹出系统菜单，拷贝或共享整段。
    /// 只加在 `Text` 上：`tint` 不改变正文颜色，但会影响同一层里的按钮等控件。
    func conversationTextSelection() -> some View {
        textSelection(.enabled)
            .tint(.blue)
    }
}
