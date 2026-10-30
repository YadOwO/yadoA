import SwiftUI

/// 麦克风旁的打字入口：不方便出声时改为打字，打出来的一句话和说出来的走同一个会话。
struct VoiceTextInputButton: View {
    @Environment(\.locale) private var locale
    @Environment(AuthStore.self) private var authStore

    /// 按钮的边长；悬浮麦克风左侧按它留出等宽占位，让麦克风保持居中。
    static let size: CGFloat = 44

    /// 与麦克风、会话卡片共享的语音状态。
    let voice: VoiceBookkeepingState

    /// 是否画悬浮底色；附属栏的玻璃底由系统绘制，不再叠一层。
    var isFloating = true

    /// 是否不接受点击：正在说话、等待识别结果或处理上一句。
    private var isBusy: Bool {
        voice.isProcessing || voice.input.isPressing || voice.input.isFinishing
    }

    var body: some View {
        Button {
            voice.beginTextInput(isSignedIn: authStore.isAuthenticated)
        } label: {
            Image(systemName: "keyboard")
                .font(.body.weight(.semibold))
                .foregroundStyle(isBusy ? Color.secondary : Color.primary)
                .frame(width: Self.size, height: Self.size)
                .modifier(VoiceTextInputButtonSurface(isFloating: isFloating))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        // 按住说话时让位给麦克风，避免手指滑过时误以为还能点
        .opacity(voice.input.isPressing ? 0 : 1)
        .accessibilityLabel(AccountLocalization.string("voice.text.entry", locale: locale))
        .accessibilityIdentifier("voice-text-input")
    }
}

/// 打字入口的底色：悬浮时与麦克风同样的玻璃或材质，放在附属栏里时没有底色。
private struct VoiceTextInputButtonSurface: ViewModifier {
    /// 是否画悬浮底色。
    let isFloating: Bool

    func body(content: Content) -> some View {
        if isFloating {
            content.voiceFloatingSurface(in: Circle())
        } else {
            content
        }
    }
}

/// 打字输入弹层：一行输入框和发送按钮，贴在键盘上方；发送后关闭，结果出现在会话卡片里。
struct VoiceTextInputSheet: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    /// 输入中的文字。
    @State private var text = ""

    /// 内容的实际高度，弹层据此贴合内容，大字号下也不会被裁掉。
    @State private var contentHeight: CGFloat = 84

    /// 发送一句话。
    let onSend: (String) -> Void

    /// 去掉首尾空白后的文字；为空时不能发送。
    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(spacing: 10) {
            // 只用单行输入框：多行输入框的回车是换行，发送键不起作用
            TextField(
                AccountLocalization.string("voice.text.placeholder", locale: locale),
                text: Binding(
                    get: { text },
                    set: { text = String($0.prefix(VoiceSessionLimits.maxUserTextLength)) }
                )
            )
            .focused($isFocused)
            .submitLabel(.send)
            .onSubmit { send() }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .accessibilityIdentifier("voice-text-field")

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(trimmedText.isEmpty ? Color.secondary : Color(.onAccent))
                    .frame(width: 44, height: 44)
                    .background(
                        trimmedText.isEmpty ? Color.primary.opacity(0.06) : Color.accentColor,
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .disabled(trimmedText.isEmpty)
            .accessibilityLabel(AccountLocalization.string("voice.text.send", locale: locale))
            .accessibilityIdentifier("voice-text-send")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            contentHeight = height
        }
        .presentationDetents([.height(contentHeight)])
        .presentationDragIndicator(.hidden)
        .task {
            isFocused = true
        }
    }

    /// 发送输入的文字并关闭弹层；没有内容时只把键盘留住。
    private func send() {
        guard !trimmedText.isEmpty else {
            isFocused = true
            return
        }
        AppHaptics.play(.commit)
        onSend(trimmedText)
        dismiss()
    }
}
