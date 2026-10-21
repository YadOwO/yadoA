import AVFoundation
import Foundation
import Observation
import Speech

/// 语音识别所需权限的状态。
enum VoiceSpeechPermission: Equatable {
    /// 麦克风和语音识别都已授权。
    case granted

    /// 至少一项还没有询问过用户。
    case notDetermined

    /// 用户拒绝了麦克风或语音识别权限，需要去系统设置开启。
    case denied
}

/// 按住说话的交互依赖的语音识别能力，便于测试时替换。
@MainActor
protocol VoiceSpeechRecognizing: AnyObject {
    /// 识别状态。
    var state: VoiceSpeechRecognizer.State { get }

    /// 截至目前的转写文字。
    var transcript: String { get }

    /// 开始收音并识别；只在空闲时生效。
    func start(locale: Locale, contextualStrings: [String]) async throws

    /// 松手时立即停止采集：之后的声音不再进入识别，已采集的音频照常识别；启动还没完成时也生效。
    func stopCapture()

    /// 停止收音并等待最终文字。
    func stop() async -> String

    /// 丢弃本次识别。
    func cancel()
}

/// 按住说话期间的端上语音识别：管理权限、音频采集与识别实现，向界面提供实时转写文字。
///
/// iOS 26 起优先使用 `SpeechAnalyzer`；该语言的模型尚未安装时，本次先用 `SFSpeechRecognizer`，
/// 同时在后台下载模型，下次即可使用新识别。音频只在本机处理，不上传到 yado_ai。
@MainActor
@Observable
final class VoiceSpeechRecognizer: VoiceSpeechRecognizing {
    /// 识别状态。
    enum State: Equatable {
        /// 空闲。
        case idle

        /// 正在启动音频与识别。
        case starting

        /// 正在收音。
        case recording

        /// 已松手，正在等待最终文字。
        case finishing
    }

    /// 当前状态。
    private(set) var state = State.idle

    /// 截至目前的转写文字。
    private(set) var transcript = ""

    private var backend: VoiceSpeechBackend?
    private var capture: VoiceAudioCapture?

    /// 后台下载识别模型的任务；同一时间只下载一次。
    private var assetInstallTask: Task<Void, Never>?

    /// 每次开始识别或取消时递增：丢弃上一次识别迟到的转写回调，
    /// 也让被取消的启动、收尾在异步返回后不再改动状态。
    private var generation = 0

    /// 当前权限状态，不会弹出系统授权框。
    static var permission: VoiceSpeechPermission {
        let microphone = AVAudioApplication.shared.recordPermission
        let speech = SFSpeechRecognizer.authorizationStatus()
        if microphone == .denied || speech == .denied || speech == .restricted {
            return .denied
        }
        if microphone == .undetermined || speech == .notDetermined {
            return .notDetermined
        }
        return .granted
    }

    /// 依次请求麦克风与语音识别权限。
    ///
    /// - Returns: 请求后的权限状态。
    static func requestPermission() async -> VoiceSpeechPermission {
        guard await AVAudioApplication.requestRecordPermission() else { return .denied }
        let status = await VoiceSpeechAuthorization.request()
        return status == .authorized ? .granted : .denied
    }

    /// 开始收音并识别。
    ///
    /// 按下就打开麦克风，同时加载识别模型；加载期间的音频由 `VoiceAudioRelay` 暂存，
    /// 模型就绪后补送，之后实时识别、边说边出字。
    /// 启动期间被 `cancel()` 取消时，在下一个异步返回点停下，关闭麦克风并释放已创建的识别。
    ///
    /// - Parameters:
    ///   - locale: 识别语言，跟随 App 界面语言。
    ///   - contextualStrings: 需要优先识别的专有名词。
    /// - Throws: `VoiceSpeechError`、音频会话错误，或启动期间被取消时的 `CancellationError`；失败时状态回到空闲。
    func start(locale: Locale, contextualStrings: [String]) async throws {
        guard state == .idle else { return }
        state = .starting
        transcript = ""
        generation += 1
        let startGeneration = generation
        let capture = VoiceAudioCapture()
        let relay = VoiceAudioRelay()
        var startedBackend: VoiceSpeechBackend?
        do {
            // 先记下，启动期间 cancel() 才能关掉麦克风；关闭排在打开之后，再释放音频会话
            self.capture = capture
            // 在后台队列打开麦克风，主线程先把「正在听」的界面画出来
            try await capture.open(feeding: relay)
            try ensureCurrent(startGeneration)
            let backend = try await makeBackend(locale: locale, contextualStrings: contextualStrings)
            try ensureCurrent(startGeneration)
            startedBackend = backend
            try await backend.start { [weak self] text in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == startGeneration, self.state != .idle else { return }
                    self.transcript = text
                }
            }
            try ensureCurrent(startGeneration)
            relay.connect(to: backend)
            self.backend = backend
            state = .recording
        } catch {
            capture.closeInBackground()
            startedBackend?.cancel()
            // 被取消时 cancel() 已经复位，之后可能已开始新的一次识别，不能再改动共享状态
            if generation == startGeneration {
                self.capture = nil
                VoiceAudioCapture.deactivateSession()
                state = .idle
            }
            throw error
        }
    }

    /// 松手时立即关闭麦克风，不等启动完成；启动期间已采集的音频仍在中转里，启动完成后照常补送识别。
    func stopCapture() {
        guard state == .starting || state == .recording else { return }
        // 关闭排在打开之后，打开还没完成时也会在打开后立即关掉
        capture?.closeInBackground()
    }

    /// 松手：停止收音并等待最终文字。
    ///
    /// - Returns: 去掉首尾空白的转写文字；没识别到或收尾期间被取消时为空。
    func stop() async -> String {
        guard state == .recording, let backend else { return "" }
        state = .finishing
        let stopGeneration = generation
        await capture?.close()
        let text = await backend.finish()
        // 收尾期间被取消：cancel() 已经复位，丢弃结果
        guard generation == stopGeneration else { return "" }
        let result = text.isEmpty ? transcript : text
        reset()
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 上滑取消或离开页面：丢弃本次识别，启动中、收尾中也立即失效。
    func cancel() {
        guard state != .idle else { return }
        generation += 1
        capture?.closeInBackground()
        backend?.cancel()
        reset()
    }

    /// 启动期间被取消时抛出 `CancellationError`。
    private func ensureCurrent(_ startGeneration: Int) throws {
        guard generation == startGeneration else { throw CancellationError() }
    }

    private func reset() {
        capture = nil
        backend = nil
        state = .idle
        transcript = ""
        VoiceAudioCapture.deactivateSession()
    }

    /// 选择识别实现：iOS 26 模型已安装时用 `SpeechAnalyzer`，否则用 `SFSpeechRecognizer`。
    private func makeBackend(locale: Locale, contextualStrings: [String]) async throws -> VoiceSpeechBackend {
        if #available(iOS 26, *) {
            switch await AnalyzerSpeechBackend.availability(locale: locale, contextualStrings: contextualStrings) {
            case let .ready(backend):
                return backend
            case let .needsAssets(supportedLocale):
                installAssetsInBackground(locale: supportedLocale)
            case .unsupported:
                break
            }
        }
        guard let backend = await Self.makeLegacyBackend(locale: locale, contextualStrings: contextualStrings) else {
            throw VoiceSpeechError.unsupported
        }
        return backend
    }

    /// 在后台创建 `SFSpeechRecognizer` 识别实现，不占主线程。
    @concurrent
    private nonisolated static func makeLegacyBackend(locale: Locale, contextualStrings: [String]) async -> LegacySpeechBackend? {
        LegacySpeechBackend(locale: locale, contextualStrings: contextualStrings)
    }

    /// 在后台下载识别模型；失败时下次使用再试，本次不打扰用户。
    @available(iOS 26, *)
    private func installAssetsInBackground(locale: Locale) {
        guard assetInstallTask == nil else { return }
        assetInstallTask = Task { [weak self] in
            try? await AnalyzerSpeechBackend.installAssets(locale: locale)
            self?.assetInstallTask = nil
        }
    }
}

/// 语音识别授权请求；系统回调在后台线程，放在非隔离上下文里桥接成 async。
nonisolated enum VoiceSpeechAuthorization {
    /// 请求语音识别授权。
    ///
    /// - Returns: 用户选择后的授权状态。
    static func request() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}
