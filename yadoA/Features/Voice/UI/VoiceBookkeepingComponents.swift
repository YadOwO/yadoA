import SwiftData
import SwiftUI

// MARK: - 麦克风按钮

/// 语音记账的麦克风按钮：按住说话、松手发送、上滑取消；没有轻点操作，打字和发图片走右侧的键盘入口 `AIChatEntryButton`。
struct VoiceMicButton: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 麦克风按钮的直径；旁边打字入口的可点高度与它一致，不把这一行撑高。
    static let size: CGFloat = 64

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
        .frame(width: Self.size, height: Self.size)
        // 玻璃只负责外观，触摸由上层 UIKit 控件接收，避免额外的手势识别等待。
        .floatingGlassSurface(in: Circle())
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

/// Tab Bar 附属栏里的麦克风：按住说话，跟随 Tab Bar 滚动收起；按下、上滑取消、松手发送与 `VoiceMicButton` 相同。
///
/// 附属栏的玻璃底和形状由系统绘制，这里只画图标和文字；Tab Bar 收起后附属栏与它并排，文字随之变小。
/// 右端用一道竖线隔出打字入口（键盘图标，整段高度都能点，见 `AIChatEntryButton`），其余部分都可以按住。
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
        HStack(spacing: 0) {
            holdArea
            AIChatEntryButton(voice: voice, style: .accessory)
        }
    }

    /// 按住说话的区域：图标与文字加上透明触摸层。
    private var holdArea: some View {
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
        // 展开时左边留出右端打字入口的宽度，文字仍在整条中间（留白处照样能按住）；与 Tab Bar 并排时空间太窄，不留
        .padding(.leading, placement == .inline ? 0 : AIChatEntryButton.accessoryWidth)
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

/// 会话卡片上点一行结果要打开的东西；行的样子和聊天页共用 `AIChatResultSlip`，打开的方式卡片自己定。
enum VoiceChangeOpenTarget: Equatable {
    /// 一笔流水的详情；带着这次改动，详情里还可以去记账页定位它。
    case transaction(VoiceEntryChange)

    /// 一个账户的详情；转账时是转出账户。
    case account(UUID)

    /// 周期记账列表：规则不在记账页明细里，在列表里查看和编辑。
    case recurringRules

    /// 找出纸条上一行要打开的东西。
    ///
    /// - Parameters:
    ///   - row: 纸条上被点的一行。
    ///   - changes: 这一轮实际写入的改动，用来找回流水改动本身。
    /// - Returns: 删除的流水、删掉的账户或规则、找不到对应改动时为 `nil`。
    static func resolve(_ row: AIChatChangeSnapshot, in changes: [VoiceChange]) -> VoiceChangeOpenTarget? {
        switch row.kind {
        case .created, .updated:
            return changes.lazy.compactMap(\.entryChange).first { $0.id == row.id }.map { .transaction($0) }
        case .deleted:
            return nil
        case .account:
            return row.targetID.map { .account($0) }
        case .recurring:
            return row.targetID == nil ? nil : .recurringRules
        }
    }
}

/// 一笔流水改动的文字；结果卡片和聊天页的历史记录共用。
enum VoiceEntryChangeText {
    /// 变更类型文字：新增、已修改、已删除。
    ///
    /// - Parameters:
    ///   - kind: 变更类型。
    ///   - locale: 文案使用的语言环境。
    static func action(for kind: VoiceEntryChange.Kind, locale: Locale) -> String {
        switch kind {
        case .created: AccountLocalization.string("voice.change.created", locale: locale)
        case .updated: AccountLocalization.string("voice.change.updated", locale: locale)
        case .deleted: AccountLocalization.string("voice.change.deleted", locale: locale)
        }
    }

    /// 待确认字段的说明，例如「待确认：账户、分类」。
    ///
    /// - Parameters:
    ///   - inferredFields: 待确认字段的原始值。
    ///   - locale: 文案使用的语言环境。
    /// - Returns: 说明文字；没有待确认字段时为 `nil`。
    static func inferredText(_ inferredFields: [String], locale: Locale) -> String? {
        guard !inferredFields.isEmpty else { return nil }
        let fields = inferredFields.map { AccountLocalization.string("voice.inferred.\($0)", locale: locale) }
        let listFormatter = ListFormatter()
        listFormatter.locale = locale
        return AccountLocalization.formatted(
            "voice.change.inferred",
            value: listFormatter.string(from: fields) ?? fields.joined(separator: ", "),
            locale: locale
        )
    }

    /// 日期、账户与待确认字段，例如「9月28日 · 微信钱包 · 待确认：账户」；日期只在不是今天时显示。
    ///
    /// - Parameters:
    ///   - transactionDay: `YYYYMMDD` 记账日。
    ///   - accountName: 所属账户名称。
    ///   - inferredFields: 待确认字段的原始值。
    ///   - locale: 文案使用的语言环境。
    ///   - calendar: 记账日使用的日历。
    /// - Returns: 说明文字；没有内容时为 `nil`。
    static func detail(
        transactionDay: Int,
        accountName: String?,
        inferredFields: [String],
        locale: Locale,
        calendar: Calendar
    ) -> String? {
        var parts: [String] = []
        // 改到别的日期、或者改的是旧账时带上日期，用户点之前就知道首页会跳到哪个月
        let today = TransactionDay.encode(.now, calendar: calendar)
        if transactionDay != today,
           let date = TransactionDay.date(from: transactionDay, calendar: calendar, locale: locale) {
            // 今年的只写月日，其他年份带上年份
            let template = transactionDay / 10_000 == today / 10_000 ? "MMMd" : "yMMMd"
            parts.append(
                BookkeepingDateFormatting.formatter(template: template, locale: locale, calendar: calendar).string(from: date)
            )
        }
        if let accountName {
            parts.append(accountName)
        }
        if let inferred = inferredText(inferredFields, locale: locale) {
            parts.append(inferred)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
        case .capacityExhausted: "voice.failure.capacityExhausted"
        case .turnInvalid: "voice.failure.turnInvalid"
        case .serviceUnavailable: "voice.failure.serviceUnavailable"
        case .network: "voice.failure.network"
        case .upgradeRequired: "appUpdate.inline"
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
        case .processing, .reply, .accountRequired: false
        }
    }

    /// 是否要引导用户新建账户：这句话因为没有账户没能记上。
    var requiresAccount: Bool {
        if case .accountRequired = outcome { return true }
        return false
    }
}

/// 从语音记账打开的新建账户：保存成功后接着处理卡在这里的那句话。
struct VoiceAccountCreationSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.locale) private var locale

    /// 因为没有账户没能记上的一轮。
    let turn: VoiceSession.Turn

    /// 与麦克风、会话卡片共享的语音状态。
    let voice: VoiceBookkeepingState

    var body: some View {
        AccountCreationView { draft in
            let repository = LocalAccountRepository(container: modelContext.container)
            try repository.save(draft, locale: locale)
            voice.resend(turn)
        }
    }
}

/// 从语音记账转手动记账的弹层：把没记上的那句话带进备注，用今天作为记账日。
struct VoiceManualEntrySheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale

    /// 带进备注的文字。
    let note: String

    /// 点「取消」时关闭弹层。
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            DiningExpenseEntryView(
                draft: DiningExpenseDraft(
                    transactionDay: TransactionDay.encode(.now, calendar: calendar),
                    note: note
                )
            ) { draft in
                try LocalExpenseRepository(container: modelContext.container).save(draft)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AccountLocalization.string("common.cancel", locale: locale), systemImage: "xmark") { onCancel() }
                }
            }
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
