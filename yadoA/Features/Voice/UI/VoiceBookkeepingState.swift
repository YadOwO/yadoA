import SwiftUI
import UIKit

/// 语音记账在麦克风、会话卡片和根导航之间共享的状态：同一个会话、同一个按住说话控制器。
///
/// 麦克风和会话卡片出现在每个一级页面上，切换 Tab 时会话不中断；iPhone 上 iOS 26.1 起麦克风挂在 Tab Bar 附属栏里，
/// 和页面里的会话卡片不在同一棵视图下，因此由根导航持有，通过环境交给附属栏和各一级页面。
@MainActor
@Observable
final class VoiceBookkeepingState {
    /// 当前语音会话；根导航第一次出现时创建。
    var session: VoiceSession?

    /// 按住说话的交互逻辑。
    let input = VoiceInputController()

    /// 识别时优先识别的账户名、分类名；进入一级页面时读一次，按下时不再查库，避免卡住按下后的第一帧。
    var contextualStrings: [String] = []

    /// Tab Bar 附属栏里麦克风顶边在窗口中的位置；附属栏不显示时为 nil。
    ///
    /// 页面内容区的底部安全区不包含附属栏，会话卡片和提示据此抬到附属栏上方。
    var accessoryMinY: CGFloat?

    /// 卡片上点选、等待记账页定位的一笔流水；根导航据此切回记账页，记账页可见时取走并清空。
    var pendingLocate: VoiceEntryChange?

    /// 从卡片打开详情的流水；由根导航以弹层展示，不离开当前页面，会话卡片保留在下面。
    var presentedTransaction: VoicePresentedTransaction?

    /// 从卡片打开详情的账户；由根导航以弹层展示，不离开当前页面，会话卡片保留在下面。
    var presentedAccount: VoicePresentedAccount?

    /// 是否从卡片打开了周期记账列表；由根导航以弹层展示，不离开当前页面，会话卡片保留在下面。
    var isRecurringRulesPresented = false

    /// 带着这句话去手动记账时预填的备注；由根导航以弹层展示。
    var manualEntryNote: VoiceManualEntryNote?

    /// 因为没有账户没能记上、正在为它新建账户的一轮；由根导航以弹层展示，建好后接着处理这句话。
    var accountCreationTurn: VoiceSession.Turn?

    /// 是否打开模型选择：点数不够所用档位但够更便宜的档位时，从卡片上打开；由根导航以弹层展示，切换后关掉可以接着说。
    var isModelTierPresented = false

    /// 是否打开聊天页；由根导航全屏展示，关闭后回到原来的一级页面。
    var isChatPresented = false

    /// 当前账号是否已同意“AI 记账说明”；由根导航注入真实判断，默认按未同意处理，保守拦截。
    var isAIProcessingConsented: () -> Bool = { false }

    /// 是否正在弹出“AI 记账说明”；由根导航和聊天页的弹层修饰符展示。
    var isAIConsentPresented = false

    /// 用户同意后要接着做的事；弹层完全关掉后才执行。
    private var aiConsentContinuation: VoiceAIConsentContinuation?

    /// 用户是否点了“同意并继续”；向下滑关掉弹层等同于“暂不使用”，此时为 false。
    private var didAcceptAIConsent = false

    /// 现在发出的话算哪个入口：聊天页全屏盖住了一级页面，打开时发出的每一句（说话、打字、点选、重发、
    /// 建好账户后接着处理）都用 AI 对话的模型，否则用快捷语音的模型。
    var modelScope: AIModelScope {
        isChatPresented ? .chat : .quickVoice
    }

    /// 会话是否正在处理上一句。
    var isProcessing: Bool {
        session?.isProcessing == true
    }

    /// 没同意“AI 记账说明”时先弹出说明，所有发往 AI 的入口共用这一道检查。
    ///
    /// - Parameter continuation: 用户同意后，弹层完全关掉再接着做的事；没有要接着做的事时为 nil。
    /// - Returns: 已同意时为 false，调用方照常继续；没同意时弹出说明并返回 true，调用方应当直接返回。
    @discardableResult
    func presentAIConsentIfNeeded(then continuation: VoiceAIConsentContinuation? = nil) -> Bool {
        guard !isAIProcessingConsented() else { return false }
        input.transientHint = nil
        aiConsentContinuation = continuation
        didAcceptAIConsent = false
        isAIConsentPresented = true
        return true
    }

    /// 用户点了“同意并继续”：记下同意并关掉弹层，接着做的事等弹层完全关掉后在 `finishAIConsent()` 里执行。
    ///
    /// 同意状态本身由弹层写入 `AIPointsStore`。
    func acceptAIConsent() {
        didAcceptAIConsent = true
        isAIConsentPresented = false
    }

    /// 用户点了“暂不使用”，或向下滑关掉了弹层：只关掉弹层，不发请求，也不接着做任何事。
    func declineAIConsent() {
        isAIConsentPresented = false
    }

    /// 弹层完全关掉后调用（弹层的 `onDismiss`）：同意过才执行接着要做的事，然后清空记录。
    ///
    /// 不在点按钮时直接打开聊天页，因为关弹层的同时盖上全屏页会失败。
    func finishAIConsent() {
        if didAcceptAIConsent, let continuation = aiConsentContinuation {
            switch continuation {
            case .openChat:
                isChatPresented = true
            case .hint(let text):
                input.transientHint = text
            }
        }
        aiConsentContinuation = nil
        didAcceptAIConsent = false
    }

    /// 按下麦克风：未登录时松手后提示登录，已登录没同意时弹出说明，都不开始收音；已同意时开始收音。
    ///
    /// - Parameters:
    ///   - isSignedIn: 当前是否已登录。
    ///   - locale: 识别使用的语言。
    func beginPress(isSignedIn: Bool, locale: Locale) {
        if isSignedIn,
           presentAIConsentIfNeeded(then: .hint(AccountLocalization.string("ai.consent.granted", locale: locale))) {
            return
        }
        input.pressBegan(
            isSignedIn: isSignedIn,
            locale: locale,
            contextualStrings: { [weak self] in self?.contextualStrings ?? [] }
        )
    }

    /// 无障碍模式下切换收音。
    ///
    /// - Parameters:
    ///   - isSignedIn: 当前是否已登录。
    ///   - locale: 识别使用的语言。
    func toggleRecording(isSignedIn: Bool, locale: Locale) {
        if isSignedIn,
           presentAIConsentIfNeeded(then: .hint(AccountLocalization.string("ai.consent.granted", locale: locale))) {
            return
        }
        input.toggleRecording(
            isSignedIn: isSignedIn,
            locale: locale,
            contextualStrings: { [weak self] in self?.contextualStrings ?? [] },
            onText: { [weak self] in self?.send($0) }
        )
    }

    /// 打开聊天页：未登录时和按住说话一样询问是否去登录；正在说话时不响应。上一句还在处理时可以打开，结果会出现在聊天页里。
    ///
    /// - Parameter isSignedIn: 当前是否已登录。
    func openChat(isSignedIn: Bool) {
        guard !input.isPressing, !input.isFinishing else { return }
        guard isSignedIn else {
            input.alert = .signInRequired
            return
        }
        guard !presentAIConsentIfNeeded(then: .openChat) else { return }
        input.transientHint = nil
        isChatPresented = true
    }

    /// 发送一句话或点选的候选项；入口在调用时就定下，之后关掉聊天页也不变。
    ///
    /// - Parameters:
    ///   - text: 识别出或打出来的文字，或候选项文案。
    ///   - option: 点选的候选项；直接说话或打字时为空。
    ///   - images: 随这句话发送的图片。
    func send(_ text: String, option: VoiceAskOption? = nil, images: [VoiceImageUpload] = []) {
        guard let session else { return }
        guard !presentAIConsentIfNeeded() else { return }
        // 说话发出的一句带上识别收尾耗时；点选候选项没有识别
        let speechFinalizeDuration = option == nil ? input.takeSpeechFinalizeDuration() : nil
        let scope = modelScope
        Task {
            await session.send(
                text,
                selectedOption: option,
                speechFinalizeDuration: speechFinalizeDuration,
                images: images,
                scope: scope
            )
        }
    }

    /// 重新发送没能完成的一轮：文字和图片都和原来一样，图片从本机文件读回。
    ///
    /// - Parameters:
    ///   - turn: 没能完成的一轮。
    ///   - images: 图片文件存储。
    func resend(_ turn: VoiceSession.Turn, images: AIChatImageStore = .production) {
        let uploads = turn.imageFileNames.compactMap { fileName in
            images.data(for: fileName).map { VoiceImageUpload(fileName: fileName, data: $0) }
        }
        guard !turn.userText.isEmpty || !uploads.isEmpty else { return }
        send(turn.userText, images: uploads)
    }

    /// 关闭会话卡片，同时作废还在收尾的语音输入，避免它在卡片收起后识别完成、又弹出新的一轮。
    func closeCard() {
        input.cancel()
        session?.closeCard()
    }

    /// 结束当前对话段；用于账本被替换、记录被清空或换账号，之后不能再引用之前的内容。
    func endSession() {
        input.cancel()
        session?.end()
    }
}

/// 用户同意“AI 记账说明”后要接着做的事。
enum VoiceAIConsentContinuation: Equatable {
    /// 接着打开聊天页。
    case openChat

    /// 接着显示一次性提示，例如“已同意，按住麦克风说话”。
    case hint(String)
}

/// 麦克风放在哪里。
@MainActor
enum VoiceMicPlacement {
    /// 是否把麦克风放进 Tab Bar 附属栏，跟随 Tab Bar 滚动收起。
    ///
    /// 只在 iPhone 的 iOS 26.1 及以上启用：需要 `tabViewBottomAccessory(isEnabled:)` 才能只在一级页面显示；
    /// iPad 的 Tab Bar 在顶部，仍用悬浮按钮。按设备而不是尺寸类别判断，避免旋转时麦克风换位置打断按住。
    static var usesTabBarAccessory: Bool {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return false }
        if #available(iOS 26.1, *) {
            return true
        }
        return false
    }
}
