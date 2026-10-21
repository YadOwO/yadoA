import SwiftUI

// MARK: - 悬浮层材质

/// 悬浮在明细上的语音控件底色：iOS 26 用 Liquid Glass，iOS 18 用材质底加投影表达层级。
private struct VoiceFloatingSurface<SurfaceShape: Shape>: ViewModifier {
    /// 底色形状。
    let shape: SurfaceShape

    /// 是否可交互；按钮使用交互玻璃，按下时有系统反馈。
    let isInteractive: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(isInteractive ? .regular.interactive() : .regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
        }
    }
}

extension View {
    /// 给语音悬浮控件加上玻璃或材质底色。
    ///
    /// - Parameters:
    ///   - shape: 底色形状。
    ///   - isInteractive: 是否使用可交互的玻璃效果。
    func voiceFloatingSurface<SurfaceShape: Shape>(in shape: SurfaceShape, isInteractive: Bool = false) -> some View {
        modifier(VoiceFloatingSurface(shape: shape, isInteractive: isInteractive))
    }
}

// MARK: - 麦克风按钮

/// 语音记账的麦克风按钮：按住说话、松手发送、上滑取消，轻点打开对话面板。
struct VoiceMicButton: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 按住说话的交互逻辑。
    let controller: VoiceInputController

    /// 会话是否正在处理上一句；处理中不响应按下。
    let isProcessing: Bool

    /// 按钮直径。
    var diameter: CGFloat = 64

    /// 手指按下、确定要开始收音时调用，由外层决定登录态和识别专有名词。
    let onPressBegan: () -> Void

    /// 轻点。
    let onTap: () -> Void

    /// 识别出文字。
    let onText: (String) -> Void

    /// 无障碍「开始说话 / 结束说话」。
    let onAccessibilityToggle: () -> Void

    /// 本次手势按下时按钮正忙（会话处理中或上一句还在收尾），整次手势都不响应；
    /// 否则中途空闲下来会在手指仍按着时突然开始收音。
    @State private var isIgnoringGesture = false

    /// 是否不接受新的按下。
    private var isBusy: Bool {
        isProcessing || controller.isFinishing
    }

    var body: some View {
        ZStack {
            if controller.isRecording {
                Circle()
                    .fill(controller.isCancelArmed ? Color(.ledgerRed) : Color.accentColor)
            }
            if isBusy {
                ProgressView()
            } else {
                Image(systemName: controller.isCancelArmed ? "xmark" : "mic.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(controller.isRecording ? Color(.onAccent) : Color.primary)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .frame(width: diameter, height: diameter)
        .voiceFloatingSurface(in: Circle(), isInteractive: true)
        .scaleEffect(controller.isRecording && !reduceMotion ? 1.12 : 1)
        .animation(reduceMotion ? nil : .spring(duration: 0.25), value: controller.isRecording)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard !isIgnoringGesture else { return }
                    if !controller.isPressing {
                        guard !isBusy else {
                            isIgnoringGesture = true
                            return
                        }
                        onPressBegan()
                    }
                    controller.pressMoved(verticalTranslation: value.translation.height)
                }
                .onEnded { _ in
                    guard !isIgnoringGesture else {
                        isIgnoringGesture = false
                        return
                    }
                    controller.pressEnded(onTap: onTap, onText: onText)
                }
        )
        .sensoryFeedback(.impact(weight: .medium), trigger: controller.isRecording) { _, isRecording in isRecording }
        .sensoryFeedback(.selection, trigger: controller.isCancelArmed)
        .accessibilityElement()
        .accessibilityLabel(text("voice.mic.label"))
        .accessibilityHint(text("voice.mic.hint"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default) { onTap() }
        .accessibilityAction(named: text(controller.isPressing ? "voice.mic.action.stop" : "voice.mic.action.start")) {
            onAccessibilityToggle()
        }
        .accessibilityIdentifier("voice-mic")
    }

    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

// MARK: - 收音气泡

/// 按住说话时按钮上方的实时转写气泡。
struct VoiceTranscriptBubble: View {
    @Environment(\.locale) private var locale

    /// 截至目前的转写文字。
    let transcript: String

    /// 是否已上滑到取消区域。
    let isCancelArmed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(transcript.isEmpty ? text("voice.recording.listening") : transcript)
                .font(.body)
                .foregroundStyle(transcript.isEmpty ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.interpolate)
            Text(text(isCancelArmed ? "voice.recording.releaseToCancel" : "voice.recording.cancelHint"))
                .font(.footnote.weight(isCancelArmed ? .semibold : .regular))
                .foregroundStyle(isCancelArmed ? Color(.ledgerRed) : Color.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .voiceFloatingSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("voice-transcript")
    }

    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

// MARK: - 结果展示

/// 一轮中写入的一笔流水：分类图标、名称、金额、账户与待确认字段。
struct VoiceEntryChangeRow: View {
    @Environment(\.locale) private var locale

    /// 流水变更。
    let change: VoiceEntryChange

    /// 所在轮次是否已撤销；已撤销时整行划掉、变淡。
    var isUndone = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: change.row?.symbolName ?? "questionmark")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.08), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(kindText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(change.kind == .deleted ? Color(.ledgerRed) : Color.secondary)
                    Text(change.label)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                }
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(change.formattedAmount)
                .font(.system(.subheadline, design: .serif).monospacedDigit())
                .lineLimit(1)
        }
        .strikethrough(isUndone)
        .opacity(isUndone ? 0.45 : 1)
        .accessibilityElement(children: .combine)
    }

    /// 变更类型文字：新增、已修改、已删除。
    private var kindText: String {
        switch change.kind {
        case .created: text("voice.change.created")
        case .updated: text("voice.change.updated")
        case .deleted: text("voice.change.deleted")
        }
    }

    /// 账户与待确认字段，例如「微信钱包 · 待确认：账户」。
    private var detail: String? {
        var parts: [String] = []
        if let accountName = change.accountName {
            parts.append(accountName)
        }
        if !change.inferredFields.isEmpty {
            let fields = change.inferredFields.map { text("voice.inferred.\($0.rawValue)") }
            let listFormatter = ListFormatter()
            listFormatter.locale = locale
            parts.append(AccountLocalization.formatted(
                "voice.change.inferred",
                value: listFormatter.string(from: fields) ?? fields.joined(separator: ", "),
                locale: locale
            ))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

extension VoiceSessionFailure {
    /// 失败时展示给用户的提示。
    ///
    /// - Parameter locale: 文案使用的语言环境。
    func message(locale: Locale) -> String {
        let key = switch self {
        case .signInRequired: "voice.failure.signIn"
        case .sessionExpired: "voice.failure.sessionExpired"
        case let .rateLimited(isDaily): isDaily ? "voice.failure.rateLimitedDaily" : "voice.failure.rateLimited"
        case .sessionTooLong: "voice.failure.sessionTooLong"
        case .serviceUnavailable: "voice.failure.serviceUnavailable"
        case .network: "voice.failure.network"
        }
        return AccountLocalization.string(key, locale: locale)
    }

    /// 是否需要（重新）登录。
    var requiresSignIn: Bool {
        self == .signInRequired || self == .sessionExpired
    }
}

extension VoiceSession.Turn {
    /// 本轮结果文字：回复、追问或失败原因；处理中为 `nil`。
    ///
    /// - Parameter locale: 失败提示使用的语言环境。
    func resultText(locale: Locale) -> String? {
        if case let .failed(failure) = outcome {
            return failure.message(locale: locale)
        }
        return displayText
    }

    /// 本轮没能完成的原因；其他结果为 `nil`。
    var failure: VoiceSessionFailure? {
        if case let .failed(failure) = outcome { return failure }
        return nil
    }

    /// 是否可以带上这句话去手动记账：追问还没回答，或本轮没能完成。
    var offersManualEntry: Bool {
        switch outcome {
        case .ask, .failed: true
        case .processing, .reply: false
        }
    }
}

/// 追问的候选项：点选后作为下一句回答发送。
struct VoiceAskOptionsView: View {
    /// 候选项。
    let options: [VoiceAskOption]

    /// 是否可以点选。
    let isEnabled: Bool

    /// 点选候选项。
    let onSelect: (VoiceAskOption) -> Void

    var body: some View {
        LedgerFlowLayout(spacing: 8) {
            ForEach(options) { option in
                Button(option.label) {
                    onSelect(option)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .disabled(!isEnabled)
            }
        }
    }
}
