import SwiftUI
import UIKit

/// 记账页语音记账在麦克风和会话卡片之间共享的状态：同一个会话、同一个按住说话控制器。
///
/// iPhone 上 iOS 26.1 起麦克风挂在 Tab Bar 附属栏里，和记账页里的会话卡片不在同一棵视图下，
/// 因此由根导航持有，通过环境分别交给附属栏和记账页。
@MainActor
@Observable
final class VoiceBookkeepingState {
    /// 当前语音会话；记账页第一次出现时创建。
    var session: VoiceSession?

    /// 按住说话的交互逻辑。
    let input = VoiceInputController()

    /// 识别时优先识别的账户名、分类名；进入记账页时读一次，按下时不再查库，避免卡住按下后的第一帧。
    var contextualStrings: [String] = []

    /// 会话是否正在处理上一句。
    var isProcessing: Bool {
        session?.isProcessing == true
    }

    /// 按下麦克风：未登录时松手后提示登录，已登录时开始收音。
    ///
    /// - Parameters:
    ///   - isSignedIn: 当前是否已登录。
    ///   - locale: 识别使用的语言。
    func beginPress(isSignedIn: Bool, locale: Locale) {
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
        input.toggleRecording(
            isSignedIn: isSignedIn,
            locale: locale,
            contextualStrings: { [weak self] in self?.contextualStrings ?? [] },
            onText: { [weak self] in self?.send($0) }
        )
    }

    /// 发送一句话或点选的候选项。
    ///
    /// - Parameters:
    ///   - text: 识别出的文字或候选项文案。
    ///   - option: 点选的候选项；直接说话时为空。
    func send(_ text: String, option: VoiceAskOption? = nil) {
        guard let session else { return }
        // 说话发出的一句带上识别收尾耗时；点选候选项没有识别
        let speechFinalizeDuration = option == nil ? input.takeSpeechFinalizeDuration() : nil
        Task { await session.send(text, selectedOption: option, speechFinalizeDuration: speechFinalizeDuration) }
    }

    /// 结束会话，同时作废还在收尾的语音输入，避免它在会话结束后识别完成、又发起新的一轮。
    func endSession() {
        input.cancel()
        session?.end()
    }
}

/// 麦克风放在哪里。
@MainActor
enum VoiceMicPlacement {
    /// 是否把麦克风放进 Tab Bar 附属栏，跟随 Tab Bar 滚动收起。
    ///
    /// 只在 iPhone 的 iOS 26.1 及以上启用：需要 `tabViewBottomAccessory(isEnabled:)` 才能只在记账页显示；
    /// iPad 的 Tab Bar 在顶部，仍用悬浮按钮。按设备而不是尺寸类别判断，避免旋转时麦克风换位置打断按住。
    static var usesTabBarAccessory: Bool {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return false }
        if #available(iOS 26.1, *) {
            return true
        }
        return false
    }
}
