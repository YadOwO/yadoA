import AVFoundation
import Foundation
import Speech

/// 一套端上语音识别实现：接收麦克风音频，持续给出转写文字。
///
/// 音频回调在音频线程执行，因此实现都是 `nonisolated` 的，内部自行加锁；
/// 不能写成默认的 MainActor 隔离类型，否则音频线程调用时会违反隔离。
nonisolated protocol VoiceSpeechBackend: AnyObject, Sendable {
    /// 开始识别。
    ///
    /// - Parameter onPartial: 转写文字更新时回调（任意线程），参数为截至目前的完整文字。
    /// - Throws: 识别服务无法启动时抛出错误。
    func start(onPartial: @escaping @Sendable (String) -> Void) async throws

    /// 送入一段麦克风音频。
    func append(_ buffer: AVAudioPCMBuffer)

    /// 音频结束，等待识别出最终文字。
    ///
    /// - Returns: 最终转写文字；没识别到时为空字符串。
    func finish() async -> String

    /// 放弃本次识别。
    func cancel()
}

/// 基于 `SFSpeechRecognizer` 的识别实现，iOS 18 及新系统不支持当前语言时使用。
///
/// 设备支持端上识别时强制端上识别；不支持时音频会交给 Apple 的识别服务（不经过 yado_ai）。
nonisolated final class LegacySpeechBackend: VoiceSpeechBackend, @unchecked Sendable {
    /// 松手后等待最终结果的最长时长，超时则使用最近一次的中间结果。
    private static let finishTimeout: TimeInterval = 2

    private let recognizer: SFSpeechRecognizer
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private let lock = NSLock()
    private var task: SFSpeechRecognitionTask?
    private var latestText = ""
    private var isFinished = false
    private var finishContinuation: CheckedContinuation<String, Never>?

    /// 创建识别实现；该语言没有可用的识别器时返回 `nil`。
    ///
    /// - Parameters:
    ///   - locale: 识别语言。
    ///   - contextualStrings: 需要优先识别的专有名词，例如账户名、分类名。
    init?(locale: Locale, contextualStrings: [String]) {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else { return nil }
        self.recognizer = recognizer
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.contextualStrings = contextualStrings
        request.addsPunctuation = true
        request.taskHint = .dictation
    }

    func start(onPartial: @escaping @Sendable (String) -> Void) async throws {
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                self.lock.withLock { self.latestText = text }
                onPartial(text)
                if result.isFinal {
                    self.complete()
                }
            }
            if error != nil {
                self.complete()
            }
        }
        lock.withLock { self.task = task }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request.append(buffer)
    }

    func finish() async -> String {
        request.endAudio()
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.finishTimeout) { [weak self] in
            self?.complete()
        }
        return await withCheckedContinuation { continuation in
            let finishedText: String? = lock.withLock {
                if isFinished { return latestText }
                finishContinuation = continuation
                return nil
            }
            if let finishedText {
                continuation.resume(returning: finishedText)
            }
        }
    }

    func cancel() {
        lock.withLock { task }?.cancel()
        complete()
    }

    /// 识别结束（得到最终结果、出错、超时或取消）时只执行一次，交出最近的文字。
    private func complete() {
        let (continuation, text): (CheckedContinuation<String, Never>?, String) = lock.withLock {
            guard !isFinished else { return (nil, latestText) }
            isFinished = true
            let continuation = finishContinuation
            finishContinuation = nil
            return (continuation, latestText)
        }
        continuation?.resume(returning: text)
    }
}

/// 基于 iOS 26 `SpeechAnalyzer` + `SpeechTranscriber` 的端上识别实现。
///
/// 识别模型由系统按语言下载；未安装时由 `VoiceSpeechRecognizer` 先改用 `LegacySpeechBackend`，并在后台下载。
@available(iOS 26, *)
nonisolated final class AnalyzerSpeechBackend: VoiceSpeechBackend, @unchecked Sendable {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let contextualStrings: [String]
    private let lock = NSLock()
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var finalizedText = ""
    private var volatileText = ""

    private init(transcriber: SpeechTranscriber, contextualStrings: [String]) {
        self.transcriber = transcriber
        self.analyzer = SpeechAnalyzer(modules: [transcriber])
        self.contextualStrings = contextualStrings
    }

    /// 识别模型的准备情况。
    enum Availability {
        /// 模型已安装，可以直接识别。
        case ready(AnalyzerSpeechBackend)

        /// 支持该语言，但模型尚未安装。
        case needsAssets(locale: Locale)

        /// 设备或语言不支持。
        case unsupported
    }

    /// 检查当前语言能否使用 `SpeechTranscriber`。
    ///
    /// - Parameters:
    ///   - locale: 识别语言。
    ///   - contextualStrings: 需要优先识别的专有名词。
    static func availability(locale: Locale, contextualStrings: [String]) async -> Availability {
        guard SpeechTranscriber.isAvailable,
              let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        else { return .unsupported }
        let installedLocales = await SpeechTranscriber.installedLocales
        let identifier = supportedLocale.identifier(.bcp47)
        guard installedLocales.contains(where: { $0.identifier(.bcp47) == identifier }) else {
            return .needsAssets(locale: supportedLocale)
        }
        return .ready(AnalyzerSpeechBackend(
            transcriber: makeTranscriber(locale: supportedLocale),
            contextualStrings: contextualStrings
        ))
    }

    /// 下载并安装该语言的识别模型。
    ///
    /// - Parameter locale: `availability` 返回的受支持语言。
    /// - Throws: 下载失败时抛出系统错误。
    static func installAssets(locale: Locale) async throws {
        let transcriber = makeTranscriber(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
    }

    func start(onPartial: @escaping @Sendable (String) -> Void) async throws {
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        lock.withLock {
            analyzerFormat = format
            inputContinuation = continuation
        }
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualStrings
            // 专有名词只是提高识别率，设置失败不影响识别
            try? await analyzer.setContext(context)
        }
        let transcriber = transcriber
        let task = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    let combined: String = self.lock.withLock {
                        if result.isFinal {
                            self.finalizedText += text
                            self.volatileText = ""
                        } else {
                            self.volatileText = text
                        }
                        return self.finalizedText + self.volatileText
                    }
                    onPartial(combined)
                }
            } catch {
                // 识别中断时保留已有文字，由 finish 交出
            }
        }
        lock.withLock { resultsTask = task }
        try await analyzer.start(inputSequence: stream)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let (continuation, converted): (AsyncStream<AnalyzerInput>.Continuation?, AVAudioPCMBuffer?) = lock.withLock {
            (inputContinuation, convert(buffer))
        }
        guard let continuation, let converted else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    func finish() async -> String {
        let (continuation, task) = lock.withLock { (inputContinuation, resultsTask) }
        continuation?.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        await task?.value
        return lock.withLock { finalizedText + volatileText }
    }

    func cancel() {
        let (continuation, task) = lock.withLock { (inputContinuation, resultsTask) }
        continuation?.finish()
        task?.cancel()
        let analyzer = analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }

    /// 把麦克风格式的音频转换为识别模型要求的格式；调用方已持有锁。
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let format = analyzerFormat, buffer.format != format else { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var isConsumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if isConsumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            isConsumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status == .error ? nil : output
    }
}

/// 麦克风采集：配置音频会话，把输入音频送给识别实现。
nonisolated final class VoiceAudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()

    /// 激活录音用的音频会话，压低其他 App 的声音。
    ///
    /// - Throws: 音频会话配置失败（例如正在通话）时抛出系统错误。
    static func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    /// 释放音频会话，恢复其他 App 的声音；失败可忽略。
    static func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 开始采集并持续送给识别实现。
    ///
    /// - Parameter backend: 接收音频的识别实现。
    /// - Throws: 没有可用的麦克风输入或引擎启动失败时抛出错误。
    func start(feeding backend: VoiceSpeechBackend) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceSpeechError.microphoneUnavailable
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            backend.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    /// 停止采集。
    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }
}

/// 语音识别无法开始的原因。
nonisolated enum VoiceSpeechError: Error, Equatable {
    /// 没有麦克风权限。
    case microphoneDenied

    /// 没有语音识别权限。
    case speechRecognitionDenied

    /// 当前语言或设备不支持语音识别。
    case unsupported

    /// 麦克风暂时不可用（例如正在通话）。
    case microphoneUnavailable
}
