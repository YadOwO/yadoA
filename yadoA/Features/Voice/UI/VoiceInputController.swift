import Foundation
import Observation
import os
import UIKit

/// 按住说话时需要弹出的提示。
enum VoiceInputAlert: Identifiable, Equatable {
    /// 麦克风或语音识别权限被拒绝。
    case permissionDenied

    /// 当前语言不支持语音识别。
    case unsupported

    /// 麦克风暂时不可用。
    case microphoneUnavailable

    /// 稳定标识。
    var id: Self { self }
}

/// 麦克风按钮的交互逻辑：按住满 70 毫秒开始收音、松手发送、上滑取消；不满 70 毫秒松手只提示要按住说话，不打开麦克风。
@MainActor
@Observable
final class VoiceInputController {
    /// 从 UIKit 触摸按下回调起，按住满该时长才确认收音；界面绘制和动画另计。
    static let holdDelay: Duration = .milliseconds(70)

    /// 手指上滑超过该距离（pt）时松手即取消。
    static let cancelDistance: CGFloat = 80

    /// 端上语音识别。
    let recognizer: any VoiceSpeechRecognizing

    /// 读取当前权限状态，不弹出系统授权框。
    private let permission: @MainActor () -> VoiceSpeechPermission

    /// 本实例使用的按住时长，测试时可缩短。
    private let holdDelay: Duration

    /// 手指是否正按在按钮上。
    private(set) var isPressing = false

    /// 手指是否已上滑到取消区域。
    private(set) var isCancelArmed = false

    /// 需要弹出的提示；界面展示后置空。
    var alert: VoiceInputAlert?

    /// 未登录时松手，需要打开登录页；界面打开登录页后置回 false。
    var isSignInRequested = false

    /// 一次性提示，例如刚授权后的「已开启，按住麦克风说话」或轻点时的「按住说话」；界面展示一会儿后置空。
    var transientHint: String?

    /// 本次按下要做的事，在按下时确定，松手时执行。
    private enum PressIntent {
        /// 收音识别。
        case record

        /// 松手后请求权限。
        case requestPermission

        /// 松手后提示。
        case alert(VoiceInputAlert)

        /// 松手后打开登录页。
        case signIn
    }

    private var pressIntent: PressIntent?

    /// 本次按下是否已按满时长、开始收音。
    private var isHoldConfirmed = false

    /// 开始收音时的震动；按下时预热，按满时长当下直接触发，不等界面刷新。
    private let startFeedback = UIImpactFeedbackGenerator(style: .medium)

    private var startTask: Task<Void, Never>?
    private var startError: Error?

    /// 每次按下或 `cancel()` 时递增；松手后的异步收尾在每个返回点比对，不一致说明这次输入已作废。
    private var inputGeneration = 0

    /// 最近一次按下时的界面语言，用于一次性提示的文案。
    private var locale = Locale.current

    /// 最近一句从松手到拿到最终识别文字的耗时；由 `takeSpeechFinalizeDuration()` 取走，计入这句话的耗时。
    private var speechFinalizeDuration: Duration?

    /// 创建按住说话的交互逻辑。
    ///
    /// - Parameters:
    ///   - recognizer: 语音识别，测试时可替换；为空时使用系统识别。
    ///   - permission: 读取权限状态的动作，测试时可替换；为空时读取系统权限。
    ///   - holdDelay: 按住满多久开始收音，测试时可替换；为空时使用 `VoiceInputController.holdDelay`。
    init(
        recognizer: (any VoiceSpeechRecognizing)? = nil,
        permission: (@MainActor () -> VoiceSpeechPermission)? = nil,
        holdDelay: Duration? = nil
    ) {
        // 默认参数在非隔离上下文中求值，碰不到主线程隔离的识别器，所以在初始化体内创建默认值
        self.recognizer = recognizer ?? VoiceSpeechRecognizer()
        self.permission = permission ?? { VoiceSpeechRecognizer.permission }
        self.holdDelay = holdDelay ?? Self.holdDelay
    }

    /// 是否正在收音（含启动中）：手指按着且已按满时长，界面据此显示实时转写。
    var isRecording: Bool {
        isPressing && isHoldConfirmed
    }

    /// 已松手、上一句还在启动或等待最终文字；期间不接受新的按下，否则新的一句会被丢掉。
    var isFinishing: Bool {
        !isPressing && recognizer.state != .idle
    }

    /// 进入记账页时提前加载识别模型，按下后马上就能边说边出字；还没授权时不做，免得在用户同意前就准备识别。
    ///
    /// - Parameters:
    ///   - locale: 识别语言。
    ///   - contextualStrings: 需要优先识别的专有名词。
    func prepareRecognizer(locale: Locale, contextualStrings: [String]) {
        guard permission() == .granted else { return }
        recognizer.prepare(locale: locale, contextualStrings: contextualStrings)
    }

    /// 手指按下：按住满 `holdDelay` 才开始收音。
    ///
    /// - Parameters:
    ///   - isSignedIn: 当前是否已登录；未登录时松手后打开登录页。
    ///   - locale: 识别语言。
    ///   - contextualStrings: 读取识别专有名词的动作，只在可以收音时调用。
    func pressBegan(isSignedIn: Bool, locale: Locale, contextualStrings: () -> [String]) {
        begin(isSignedIn: isSignedIn, locale: locale, contextualStrings: contextualStrings, delay: holdDelay)
    }

    /// 开始一次输入。
    ///
    /// - Parameters:
    ///   - isSignedIn: 当前是否已登录。
    ///   - locale: 识别语言。
    ///   - contextualStrings: 读取识别专有名词的动作。
    ///   - delay: 开始收音前的等待；VoiceOver 切换时为零。
    private func begin(isSignedIn: Bool, locale: Locale, contextualStrings: () -> [String], delay: Duration) {
        guard !isPressing, !isFinishing else { return }
        inputGeneration += 1
        speechFinalizeDuration = nil
        isPressing = true
        isHoldConfirmed = false
        isCancelArmed = false
        transientHint = nil
        self.locale = locale
        guard isSignedIn else {
            pressIntent = .signIn
            return
        }
        switch permission() {
        case .denied:
            pressIntent = .alert(.permissionDenied)
        case .notDetermined:
            pressIntent = .requestPermission
        case .granted:
            pressIntent = .record
            startError = nil
            startFeedback.prepare()
            let strings = contextualStrings()
            let generation = inputGeneration
            startTask = Task {
                if delay > .zero {
                    // 不满时长就松手时任务被取消，sleep 提前结束，由下面的检查拦下
                    try? await Task.sleep(for: delay)
                }
                // 任务还没开始执行就被取消时，识别器仍是空闲，cancel() 停不住它，必须在入口拦下
                guard generation == inputGeneration, !Task.isCancelled else { return }
                isHoldConfirmed = true
                // 先震动再启动识别，震动不受之后激活录音会话的影响
                startFeedback.impactOccurred()
                do {
                    try await recognizer.start(locale: locale, contextualStrings: strings)
                } catch {
                    // 已作废的输入迟到的错误不能留给下一次按下
                    guard generation == inputGeneration else { return }
                    startError = error
                }
            }
        }
    }

    /// 手指移动。
    ///
    /// - Parameter verticalTranslation: 相对按下位置的竖直位移，向上为负。
    func pressMoved(verticalTranslation: CGFloat) {
        guard isPressing else { return }
        isCancelArmed = verticalTranslation < -Self.cancelDistance
    }

    /// 手指抬起。
    ///
    /// - Parameter onText: 识别出文字时执行，例如发送给会话。
    func pressEnded(onText: @escaping (String) -> Void) {
        guard isPressing else { return }
        isPressing = false
        let isCancelled = isCancelArmed
        isCancelArmed = false
        let intent = pressIntent
        pressIntent = nil
        let wasHoldConfirmed = isHoldConfirmed
        isHoldConfirmed = false
        let generation = inputGeneration

        switch intent {
        case let .alert(alert):
            self.alert = alert
        case .signIn:
            isSignInRequested = true
        case .requestPermission:
            Task {
                let permission = await VoiceSpeechRecognizer.requestPermission()
                guard generation == inputGeneration else { return }
                if permission == .granted {
                    transientHint = AccountLocalization.string("voice.permission.granted", locale: locale)
                } else {
                    alert = .permissionDenied
                }
            }
        case .record where !wasHoldConfirmed:
            // 没按满时长就松手：还没开始收音，取消等待，只提示要按住说话
            startTask?.cancel()
            startTask = nil
            transientHint = AccountLocalization.string("voice.mic.holdHint", locale: locale)
        case .record where isCancelled:
            // 上滑取消：立即作废并关麦，启动还没完成也不等
            cancel()
        case .record:
            let releasedAt = VoiceTimingClock.now
            let signposter = VoiceTimingLog.signposter
            let finalizeSignpost = signposter.beginInterval("VoiceSpeechFinalize", id: signposter.makeSignpostID())
            // 松手即停止采集，启动较慢时松手之后的声音也不会被识别
            recognizer.stopCapture()
            let startTask = startTask
            self.startTask = nil
            Task {
                defer { signposter.endInterval("VoiceSpeechFinalize", finalizeSignpost) }
                // 启动尚未完成时先等它结束，已采集的音频随后照常识别
                await startTask?.value
                // 等待期间离开了页面或结束了会话：识别已被取消，这次输入整个作废
                guard generation == inputGeneration else { return }
                if let startError {
                    self.startError = nil
                    alert = Self.alert(for: startError)
                    return
                }
                let text = await recognizer.stop()
                guard generation == inputGeneration else { return }
                // 没识别到话时静默结束
                if !text.isEmpty {
                    speechFinalizeDuration = ContinuousClock.now - releasedAt
                    onText(text)
                }
            }
        case nil:
            break
        }
    }

    /// VoiceOver 下切换收音：轻点两下开始，再轻点两下结束并发送。
    ///
    /// - Parameters:
    ///   - isSignedIn: 当前是否已登录。
    ///   - locale: 识别语言。
    ///   - contextualStrings: 读取识别专有名词的动作。
    ///   - onText: 识别出文字时执行。
    func toggleRecording(
        isSignedIn: Bool,
        locale: Locale,
        contextualStrings: () -> [String],
        onText: @escaping (String) -> Void
    ) {
        guard !isFinishing else { return }
        if isPressing {
            pressEnded(onText: onText)
        } else {
            // VoiceOver 下没有按住的动作，立即开始收音
            begin(isSignedIn: isSignedIn, locale: locale, contextualStrings: contextualStrings, delay: .zero)
            if case .record = pressIntent {
                return
            }
            // 不能收音时立即给出提示
            pressEnded(onText: onText)
        }
    }

    /// 取走最近一句从松手到拿到最终识别文字的耗时，取走后清空，避免算到下一句上。
    ///
    /// - Returns: 耗时；没有待取的耗时时为空。
    func takeSpeechFinalizeDuration() -> Duration? {
        defer { speechFinalizeDuration = nil }
        return speechFinalizeDuration
    }

    /// 离开页面或结束会话时放弃这次输入：正在收音、启动中或等待最终文字的都作废，不再回调 `onText`；一次性提示也一并清掉。
    func cancel() {
        inputGeneration += 1
        speechFinalizeDuration = nil
        startError = nil
        transientHint = nil
        isPressing = false
        isHoldConfirmed = false
        isCancelArmed = false
        pressIntent = nil
        startTask?.cancel()
        startTask = nil
        recognizer.cancel()
    }

    private static func alert(for error: Error) -> VoiceInputAlert {
        switch error as? VoiceSpeechError {
        case .microphoneDenied, .speechRecognitionDenied: .permissionDenied
        case .unsupported: .unsupported
        case .microphoneUnavailable, nil: .microphoneUnavailable
        }
    }
}
