import AVFoundation
import Foundation
import Testing
@testable import yadoA

/// 识别还没就绪时说的话先暂存，就绪后按顺序补送，按下后马上开口也不会丢字。
@Suite("麦克风音频中转")
struct VoiceAudioRelayTests {
    @Test("识别就绪前的音频暂存并按顺序补送，之后直接转发")
    func flushesPendingAudioInOrder() throws {
        let relay = VoiceAudioRelay()
        let backend = RecordingSpeechBackend()

        relay.receive(try makeBuffer(frames: 100))
        relay.receive(try makeBuffer(frames: 200))
        #expect(backend.receivedFrames.isEmpty)

        relay.connect(to: backend)
        #expect(backend.receivedFrames == [100, 200])

        relay.receive(try makeBuffer(frames: 300))
        #expect(backend.receivedFrames == [100, 200, 300])
    }

    @Test("暂存超过上限时丢弃最早的音频")
    func dropsOldestAudioBeyondLimit() throws {
        let relay = VoiceAudioRelay()
        let backend = RecordingSpeechBackend()

        // 采样率 1000，每段 4 秒，5 段共 20 秒，超过 15 秒上限
        for _ in 0..<5 {
            relay.receive(try makeBuffer(frames: 4000, sampleRate: 1000))
        }
        relay.connect(to: backend)

        #expect(backend.receivedFrames == [4000, 4000, 4000])
    }

    /// 生成一段指定帧数的单声道音频。
    private func makeBuffer(frames: AVAudioFrameCount, sampleRate: Double = 16000) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        return buffer
    }
}

/// 打开可能晚于关闭才排进队列：按下后很快松手或取消时，迟到的打开不能再把麦克风打开。
///
/// 只覆盖已关闭的分支，不会激活音频会话或真的打开麦克风。
@Suite("麦克风采集的关闭时序")
struct VoiceAudioCaptureTests {
    @Test("松手先于打开排进队列时，迟到的打开不再打开麦克风")
    func openAfterBackgroundCloseIsSkipped() async throws {
        let capture = VoiceAudioCapture()

        // 模拟 stopCapture() / cancel() 先于打开执行
        capture.closeInBackground()
        let isOpened = try await capture.open(feeding: VoiceAudioRelay())

        #expect(!isOpened)
    }

    @Test("等待关闭完成后再打开，同样不会打开麦克风")
    func openAfterCloseIsSkipped() async throws {
        let capture = VoiceAudioCapture()

        await capture.close()
        let isOpened = try await capture.open(feeding: VoiceAudioRelay())

        #expect(!isOpened)
    }
}

/// 只记录收到的音频帧数的假识别实现。
private nonisolated final class RecordingSpeechBackend: VoiceSpeechBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [AVAudioFrameCount] = []

    /// 依次收到的每段音频帧数。
    var receivedFrames: [AVAudioFrameCount] {
        lock.withLock { frames }
    }

    @concurrent func start(onPartial: @escaping @Sendable (String) -> Void) async throws {}

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { frames.append(buffer.frameLength) }
    }

    @concurrent func finish() async -> String { "" }

    func cancel() {}
}
