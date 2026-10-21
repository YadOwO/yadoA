import AVFoundation
import Foundation
import Speech

/// 一套端上语音识别实现：接收麦克风音频，持续给出转写文字。
///
/// 音频回调在音频线程执行，因此实现都是 `nonisolated` 的，内部自行加锁；
/// 不能写成默认的 MainActor 隔离类型，否则音频线程调用时会违反隔离。
/// 开始、收尾标为 `@concurrent`，加载模型等耗时工作在后台执行，不占主线程。
nonisolated protocol VoiceSpeechBackend: AnyObject, Sendable {
    /// 开始识别。
    ///
    /// - Parameter onPartial: 转写文字更新时回调（任意线程），参数为截至目前的完整文字。
    /// - Throws: 识别服务无法启动时抛出错误。
    @concurrent func start(onPartial: @escaping @Sendable (String) -> Void) async throws

    /// 送入一段麦克风音频。
    func append(_ buffer: AVAudioPCMBuffer)

    /// 音频结束，等待识别出最终文字。
    ///
    /// - Returns: 最终转写文字；没识别到时为空字符串。
    @concurrent func finish() async -> String

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

    @concurrent func start(onPartial: @escaping @Sendable (String) -> Void) async throws {
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

    @concurrent func finish() async -> String {
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

    /// 加载模型的任务；预热和开始识别可能同时调用 `prepare()`，共用同一次加载。
    private var prepareTask: Task<Void, Never>?

    private init(transcriber: SpeechTranscriber, contextualStrings: [String]) {
        self.transcriber = transcriber
        // 用完后让系统多留一会儿模型，连续说几句时不用每句都重新加载
        self.analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        )
        self.contextualStrings = contextualStrings
    }

    /// 识别模型的准备情况。
    enum Availability: Sendable {
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
    @concurrent static func availability(locale: Locale, contextualStrings: [String]) async -> Availability {
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
    @concurrent static func installAssets(locale: Locale) async throws {
        let transcriber = makeTranscriber(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    /// 创建实时转写模块。
    ///
    /// 用系统为实时转写准备的预设：除中间结果外还偏向响应速度，按住期间尽快出字；松手后的最终结果照常校正。
    /// 只开 `.volatileResults` 时中间结果要攒更长的音频才给出，记账这种两三秒的短句容易松手后才出字。
    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    }

    /// 提前确定音频格式、设置专有名词并把识别模型载入内存，之后 `start` 不用再等模型加载，按下就能边说边出字。
    ///
    /// 可重复调用，只加载一次；加载失败时 `start` 照常开始，由系统在收到音频时再加载。
    @concurrent func prepare() async {
        let task: Task<Void, Never> = lock.withLock {
            if let prepareTask { return prepareTask }
            let task = Task { await self.loadModel() }
            prepareTask = task
            return task
        }
        await task.value
    }

    /// 实际的加载工作，只由 `prepare()` 调用一次。
    @concurrent private func loadModel() async {
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        lock.withLock { analyzerFormat = format }
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualStrings
            // 专有名词只是提高识别率，设置失败不影响识别
            try? await analyzer.setContext(context)
        }
        // 预加载失败不影响识别，只是第一段文字出来得晚一些
        try? await analyzer.prepareToAnalyze(in: format)
    }

    @concurrent func start(onPartial: @escaping @Sendable (String) -> Void) async throws {
        // 已预热时立即返回
        await prepare()
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        lock.withLock { inputContinuation = continuation }
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

    @concurrent func finish() async -> String {
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

/// 麦克风采集：配置音频会话，把输入音频交给中转，再由中转送给识别实现。
///
/// 激活、释放音频会话和启停音频引擎都是会卡住线程的同步调用（可能要几百毫秒），全部放在一条串行队列上执行，
/// 不占用主线程；同一条队列也保证这些操作按调用顺序执行，例如「上一次释放会话」一定先于「这一次激活」。
nonisolated final class VoiceAudioCapture: @unchecked Sendable {
    /// 音频会话与引擎操作的串行队列。
    private static let queue = DispatchQueue(label: "yadoA.voice.audio", qos: .userInitiated)

    private let engine = AVAudioEngine()

    /// 引擎是否正在采集；只在队列上读写，松手和收尾可能先后关闭，重复关闭时直接跳过。
    private var isRunning = false

    private let lock = NSLock()

    /// 是否已经关闭；在调用关闭的线程上立即置位，不等队列。
    ///
    /// 打开可能晚于关闭才排进队列（例如按下后很快松手，打开所在的子任务还没执行），
    /// 这时队列上的停止会因为引擎还没启动而直接跳过；打开前检查这个标记，已关闭就不再打开麦克风。
    /// 每次采集都新建一个实例，关闭后不会再打开。
    private var isClosed = false

    /// 激活音频会话并开始采集，持续把音频交给中转；在后台队列执行，不阻塞调用方所在线程。
    ///
    /// 已经调用过关闭时不做任何事，既不激活音频会话也不打开麦克风。
    ///
    /// - Parameter relay: 接收音频的中转；识别实现还没就绪时由它暂存。
    /// - Returns: 是否真的打开了麦克风；打开前已关闭时为 false。
    /// - Throws: 音频会话配置失败（例如正在通话）、没有可用的麦克风输入或引擎启动失败时抛出错误。
    @discardableResult
    func open(feeding relay: VoiceAudioRelay) async throws -> Bool {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            Self.queue.async {
                // 在队列上检查：此后才置位的关闭，它的停止排在本次打开之后，仍能关掉麦克风
                guard !self.lock.withLock({ self.isClosed }) else {
                    continuation.resume(returning: false)
                    return
                }
                do {
                    try Self.activateSession()
                    try self.start(feeding: relay)
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 停止采集；在后台队列执行，返回后不会再有新的音频送出。
    func close() async {
        markClosed()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Self.queue.async {
                self.stopEngine()
                continuation.resume()
            }
        }
    }

    /// 停止采集，不等待完成；用于取消。之后排队的释放会话仍在它之后执行。
    func closeInBackground() {
        markClosed()
        Self.queue.async {
            self.stopEngine()
        }
    }

    /// 释放音频会话，恢复其他 App 的声音；在后台队列执行，失败可忽略。
    static func deactivateSession() {
        queue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// 激活录音用的音频会话，压低其他 App 的声音。
    ///
    /// 录音会话默认会屏蔽触感反馈，开始收音的震动正好赶上会话激活，会被吞掉或推迟，所以显式允许。
    private static func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    /// 标记已关闭，阻止之后才排进队列的打开。
    private func markClosed() {
        lock.withLock { isClosed = true }
    }

    /// 停止音频引擎并移除采集；只在队列上调用，可重复调用。
    private func stopEngine() {
        guard isRunning else { return }
        isRunning = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    /// 开始采集；只在队列上调用。
    private func start(feeding relay: VoiceAudioRelay) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceSpeechError.microphoneUnavailable
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            relay.receive(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
            isRunning = true
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }
}

/// 麦克风与识别实现之间的音频中转，识别仍是边说边出字的实时识别。
///
/// 只在按下后识别模型加载的那一小段时间（通常几百毫秒）里暂存音频；模型一就绪就把这段补送过去，
/// 之后每段音频直接实时转发。这样按下后马上开口，开头的字也不会丢。
nonisolated final class VoiceAudioRelay: @unchecked Sendable {
    /// 最多暂存的时长（秒），识别迟迟没就绪时丢弃更早的音频，避免占用过多内存。
    private static let maxPendingDuration: Double = 15

    private let lock = NSLock()
    private var backend: VoiceSpeechBackend?
    private var pending: [AVAudioPCMBuffer] = []
    private var pendingFrames: AVAudioFrameCount = 0

    /// 收到一段麦克风音频（音频线程）。
    ///
    /// - Parameter buffer: 采集回调给出的音频。
    func receive(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            if let backend {
                backend.append(buffer)
                return
            }
            // 采集回调的缓冲区可能被系统复用，暂存前先复制
            guard let copy = Self.copy(buffer) else { return }
            pending.append(copy)
            pendingFrames += copy.frameLength
            let limit = AVAudioFrameCount(buffer.format.sampleRate * Self.maxPendingDuration)
            while pendingFrames > limit, !pending.isEmpty {
                pendingFrames -= pending.removeFirst().frameLength
            }
        }
    }

    /// 识别实现已就绪：补送暂存的音频，之后的音频直接转发。
    ///
    /// - Parameter backend: 已开始识别的实现。
    func connect(to backend: VoiceSpeechBackend) {
        // 在锁内补送，保证暂存的音频排在音频线程新送来的音频之前
        lock.withLock {
            for buffer in pending {
                backend.append(buffer)
            }
            pending = []
            pendingFrames = 0
            self.backend = backend
        }
    }

    /// 复制一段音频数据。
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(source.count, destination.count) {
            guard let from = source[index].mData, let to = destination[index].mData else { continue }
            let size = min(source[index].mDataByteSize, destination[index].mDataByteSize)
            memcpy(to, from, Int(size))
            destination[index].mDataByteSize = size
        }
        return copy
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
