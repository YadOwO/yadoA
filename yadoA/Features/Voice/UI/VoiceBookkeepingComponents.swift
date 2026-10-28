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

/// 语音记账的麦克风按钮：按住说话、松手发送、上滑取消；没有轻点操作。
struct VoiceMicButton: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 按住说话的交互逻辑。
    let controller: VoiceInputController

    /// 会话是否正在处理上一句；处理中不响应按下。
    let isProcessing: Bool

    /// 手指按下、确定要开始收音时调用，由外层决定登录态和识别专有名词。
    let onPressBegan: () -> Void

    /// 识别出文字。
    let onText: (String) -> Void

    /// VoiceOver 下轻点两下：开始说话，再轻点两下结束并发送。
    let onAccessibilityToggle: () -> Void

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
        .frame(width: 64, height: 64)
        // 玻璃只负责外观，触摸由上层 UIKit 控件接收，避免额外的手势识别等待。
        .voiceFloatingSurface(in: Circle())
        .scaleEffect(controller.isRecording && !reduceMotion ? 1.12 : 1)
        .animation(reduceMotion ? nil : .spring(duration: 0.25), value: controller.isRecording)
        .contentShape(Circle())
        .overlay {
            VoiceMicTouchArea(
                onPressBegan: {
                    guard !isBusy, !controller.isPressing else { return false }
                    onPressBegan()
                    return controller.isPressing
                },
                onPressMoved: { controller.pressMoved(verticalTranslation: $0) },
                onPressEnded: { controller.pressEnded(onText: onText) },
                onPressCancelled: { controller.cancel() }
            )
            .accessibilityHidden(true)
        }
        .appHaptic(.selection, trigger: controller.isCancelArmed)
        // 首次引导结束时豆子落到这里
        .voiceEntryBeacon()
        .accessibilityElement()
        .accessibilityLabel(text("voice.mic.label"))
        .accessibilityHint(text("voice.mic.hint"))
        .accessibilityValue(controller.isRecording ? text("voice.recording.listening") : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default) { onAccessibilityToggle() }
        .accessibilityIdentifier("voice-mic")
    }

    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// Tab Bar 附属栏里的麦克风：整条按住说话，跟随 Tab Bar 滚动收起；按下、上滑取消、松手发送与 `VoiceMicButton` 相同。
///
/// 附属栏的玻璃底和形状由系统绘制，这里只画图标和文字；Tab Bar 收起后附属栏与它并排，文字随之变小。
@available(iOS 26.1, *)
struct VoiceMicAccessory: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(AuthStore.self) private var authStore

    /// 与各一级页面会话卡片共享的语音状态。
    let voice: VoiceBookkeepingState

    private var controller: VoiceInputController {
        voice.input
    }

    /// 是否不接受新的按下。
    private var isBusy: Bool {
        voice.isProcessing || controller.isFinishing
    }

    var body: some View {
        HStack(spacing: 8) {
            if isBusy {
                ProgressView()
            } else {
                Image(systemName: symbolName)
                    .symbolEffect(
                        .variableColor.iterative,
                        isActive: controller.isRecording && !controller.isCancelArmed && !reduceMotion
                    )
                    .contentTransition(.symbolEffect(.replace))
            }
            if showsSpeakingPrompt {
                VoiceRotatingHoldPrompt(isRotating: true)
                    .lineLimit(1)
            } else {
                Text(title)
                    .lineLimit(1)
            }
        }
        .font(font)
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 告诉一级页面附属栏顶边在哪，会话卡片和提示据此避开附属栏
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .global).minY
        } action: { minY in
            voice.accessoryMinY = minY
        }
        .onDisappear {
            voice.accessoryMinY = nil
        }
        .contentShape(Rectangle())
        .overlay {
            VoiceMicTouchArea(
                isCircular: false,
                onPressBegan: {
                    guard !isBusy, !controller.isPressing else { return false }
                    voice.beginPress(isSignedIn: authStore.isAuthenticated, locale: locale)
                    return controller.isPressing
                },
                onPressMoved: { controller.pressMoved(verticalTranslation: $0) },
                onPressEnded: { controller.pressEnded(onText: { voice.send($0) }) },
                onPressCancelled: { controller.cancel() }
            )
            .accessibilityHidden(true)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: controller.isRecording)
        .appHaptic(.selection, trigger: controller.isCancelArmed)
        // 首次引导结束时豆子落到这里
        .voiceEntryBeacon()
        .accessibilityElement()
        .accessibilityLabel(text("voice.mic.label"))
        .accessibilityHint(text("voice.mic.hint"))
        .accessibilityValue(controller.isRecording ? text("voice.recording.listening") : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default) {
            voice.toggleRecording(isSignedIn: authStore.isAuthenticated, locale: locale)
        }
        .accessibilityIdentifier("voice-mic")
    }

    /// Tab Bar 收起、附属栏与它并排时空间更窄，文字小一号。
    private var font: Font {
        let base: Font = placement == .inline ? .subheadline : .body
        return base.weight(.semibold)
    }

    /// 空闲是麦克风，说话时是跳动的声波，准备取消时是叉。
    private var symbolName: String {
        if controller.isCancelArmed { return "xmark" }
        return controller.isRecording ? "waveform" : "mic.fill"
    }

    /// 空闲且附属栏展开时轮换示例说法，告诉用户可以怎么说；与 Tab Bar 并排时空间太窄，只写「按住说话」。
    private var showsSpeakingPrompt: Bool {
        !controller.isPressing && !controller.isRecording && !isBusy && placement != .inline
    }

    /// 空闲时提示按住说话，说话时提示松手的结果。
    private var title: String {
        if controller.isCancelArmed { return text("voice.recording.releaseToCancel") }
        return text(controller.isRecording ? "voice.mic.releaseToSend" : "voice.mic.holdHint")
    }

    /// 说话时用强调色，准备取消时用红色，处理中变淡。
    private var tint: Color {
        if controller.isCancelArmed { return Color(.ledgerRed) }
        if controller.isRecording { return .accentColor }
        return isBusy ? .secondary : .primary
    }

    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

// MARK: - 结果展示

/// 一轮中写入的一笔流水：分类图标、名称、金额、日期（不是今天时）、账户与待确认字段。
struct VoiceEntryChangeRow: View {
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

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

    /// 日期、账户与待确认字段，例如「9月28日 · 微信钱包 · 待确认：账户」；日期只在不是今天时显示。
    private var detail: String? {
        var parts: [String] = []
        // 改到别的日期、或者改的是旧账时带上日期，用户点之前就知道首页会跳到哪个月
        let today = TransactionDay.encode(.now, calendar: calendar)
        if change.transactionDay != today,
           let date = TransactionDay.date(from: change.transactionDay, calendar: calendar, locale: locale) {
            // 今年的只写月日，其他年份带上年份
            let template = change.transactionDay / 10_000 == today / 10_000 ? "MMMd" : "yMMMd"
            parts.append(
                BookkeepingDateFormatting.formatter(template: template, locale: locale, calendar: calendar).string(from: date)
            )
        }
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

/// 一轮中的一次账户相关改动：图标、动作、账户名称、说明与金额，样式与流水行一致。
struct VoiceAccountChangeRow: View {
    /// 账户相关改动。
    let change: VoiceAccountChange

    /// 所在轮次是否已撤销；已撤销时整行划掉、变淡。
    var isUndone = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: change.symbolName)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.08), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(change.actionText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(change.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                }
                if let detail = change.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let formattedAmount = change.formattedAmount {
                Text(formattedAmount)
                    .font(.system(.subheadline, design: .serif).monospacedDigit())
                    .lineLimit(1)
            }
        }
        .strikethrough(isUndone)
        .opacity(isUndone ? 0.45 : 1)
        .accessibilityElement(children: .combine)
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
        case .insufficientPoints: "voice.failure.insufficientPoints"
        case .turnInvalid: "voice.failure.turnInvalid"
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

    /// 本轮改动过、仍然存在的账户；已撤销的轮次为空。账户页列表据此在对应账户上补笔迹。
    var changedAccountIDs: Set<UUID> {
        guard !isUndone else { return [] }
        return Set(changes.flatMap { change -> [UUID] in
            guard case let .account(accountChange) = change else { return [] }
            return accountChange.accountIDs
        })
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
