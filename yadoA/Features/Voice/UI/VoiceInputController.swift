import Foundation
import Observation

/// 按住说话时需要弹出的提示。
enum VoiceInputAlert: Identifiable, Equatable {
    /// 需要先登录。
    case signInRequired

    /// 麦克风或语音识别权限被拒绝。
    case permissionDenied

    /// 当前语言不支持语音识别。
    case unsupported

    /// 麦克风暂时不可用。
    case microphoneUnavailable

    /// 稳定标识。
    var id: Self { self }
}

/// 麦克风按钮的交互逻辑：按下即收音、松手发送、上滑取消，按住不足 0.3 秒按点按处理。
///
/// 记账页的悬浮按钮与对话面板里的按钮共用这一套逻辑。
@MainActor
@Observable
final class VoiceInputController {
    /// 按住不足该时长视为点按。
    static let tapThreshold: TimeInterval = 0.3

    /// 手指上滑超过该距离（pt）时松手即取消。
    static let cancelDistance: CGFloat = 80

    /// 端上语音识别。
    let recognizer: any VoiceSpeechRecognizing

    /// 读取当前权限状态，不弹出系统授权框。
    private let permission: () -> VoiceSpeechPermission

    /// 当前时刻，用于判断按住时长。
    private let now: () -> Date

    /// 手指是否正按在按钮上。
    private(set) var isPressing = false

    /// 手指是否已上滑到取消区域。
    private(set) var isCancelArmed = false

    /// 需要弹出的提示；界面展示后置空。
    var alert: VoiceInputAlert?

    /// 刚授权后的一次性提示，例如「已开启，按住麦克风说话」。
    var transientHint: String?

    /// 本次按下要做的事，在按下时确定，松手时执行。
    private enum PressIntent {
        /// 收音识别。
        case record

        /// 松手后请求权限。
        case requestPermission

        /// 松手后提示。
        case alert(VoiceInputAlert)
    }

    private var pressIntent: PressIntent?
    private var pressStartedAt: Date?
    private var startTask: Task<Void, Never>?
    private var startError: Error?

    /// 每次按下或 `cancel()` 时递增；松手后的异步收尾在每个返回点比对，不一致说明这次输入已作废。
    private var inputGeneration = 0

    /// 最近一次按下时的界面语言，用于一次性提示的文案。
    private var locale = Locale.current

    /// 创建按住说话的交互逻辑。
    ///
    /// - Parameters:
    ///   - recognizer: 语音识别，测试时可替换。
    ///   - permission: 读取权限状态的动作，测试时可替换。
    ///   - now: 当前时刻，测试时可替换。
    init(
        recognizer: any VoiceSpeechRecognizing = VoiceSpeechRecognizer(),
        permission: @escaping () -> VoiceSpeechPermission = { VoiceSpeechRecognizer.permission },
        now: @escaping () -> Date = { .now }
    ) {
        self.recognizer = recognizer
        self.permission = permission
        self.now = now
    }

    /// 是否正在收音（含启动中），界面据此显示转写气泡。
    var isRecording: Bool {
        guard isPressing, case .record? = pressIntent else { return false }
        return true
    }

    /// 已松手、上一句还在启动或等待最终文字；期间不接受新的按下，否则新的一句会被丢掉。
    var isFinishing: Bool {
        !isPressing && recognizer.state != .idle
    }

    /// 手指按下。
    ///
    /// - Parameters:
    ///   - isSignedIn: 当前是否已登录；未登录时松手后提示登录。
    ///   - locale: 识别语言。
    ///   - contextualStrings: 读取识别专有名词的动作，只在真正收音时调用。
    func pressBegan(isSignedIn: Bool, locale: Locale, contextualStrings: () -> [String]) {
        guard !isPressing, !isFinishing else { return }
        inputGeneration += 1
        isPressing = true
        isCancelArmed = false
        pressStartedAt = now()
        transientHint = nil
        self.locale = locale
        guard isSignedIn else {
            pressIntent = .alert(.signInRequired)
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
            let strings = contextualStrings()
            let generation = inputGeneration
            startTask = Task {
                // 任务还没开始执行就被取消时，识别器仍是空闲，cancel() 停不住它，必须在入口拦下
                guard generation == inputGeneration, !Task.isCancelled else { return }
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
    /// - Parameters:
    ///   - onTap: 按住不足 0.3 秒时执行，例如打开对话面板。
    ///   - onText: 识别出文字时执行，例如发送给会话。
    func pressEnded(onTap: @escaping () -> Void, onText: @escaping (String) -> Void) {
        guard isPressing else { return }
        isPressing = false
        let duration = pressStartedAt.map { now().timeIntervalSince($0) } ?? 0
        let isCancelled = isCancelArmed
        isCancelArmed = false
        let intent = pressIntent
        pressIntent = nil
        let generation = inputGeneration

        switch intent {
        case let .alert(alert):
            self.alert = alert
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
        case .record:
            let startTask = startTask
            self.startTask = nil
            Task {
                // 启动尚未完成时先等它结束，再决定停止还是取消
                await startTask?.value
                // 等待期间离开了页面或结束了会话：识别已被取消，这次输入整个作废
                guard generation == inputGeneration else { return }
                if let startError {
                    self.startError = nil
                    alert = Self.alert(for: startError)
                    return
                }
                if duration < Self.tapThreshold {
                    recognizer.cancel()
                    onTap()
                    return
                }
                if isCancelled {
                    recognizer.cancel()
                    return
                }
                let text = await recognizer.stop()
                guard generation == inputGeneration else { return }
                // 没识别到话时静默取消
                if !text.isEmpty {
                    onText(text)
                }
            }
        case nil:
            break
        }
    }

    /// 无障碍「开始说话 / 结束说话」：轻点一次开始，再轻点一次结束并发送。
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
            // 无障碍模式下没有按住时长，按收音处理
            pressStartedAt = .distantPast
            pressEnded(onTap: {}, onText: onText)
        } else {
            pressBegan(isSignedIn: isSignedIn, locale: locale, contextualStrings: contextualStrings)
            if case .record = pressIntent {
                return
            }
            // 不能收音时立即给出提示
            pressEnded(onTap: {}, onText: onText)
        }
    }

    /// 离开页面或结束会话时放弃这次输入：正在收音、启动中或等待最终文字的都作废，不再回调 `onText`。
    func cancel() {
        inputGeneration += 1
        startError = nil
        isPressing = false
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
