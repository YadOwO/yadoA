import Foundation
import Testing
@testable import yadoA

/// 麦克风按钮交互的时序：按满时长才收音，取消后不能再收音或发送，上一句收尾期间不接受新的按下。
@Suite("按住说话交互", .serialized)
@MainActor
struct VoiceInputControllerTests {
    @Test("按下后立即取消、启动任务尚未执行时，不会开始收音")
    func cancelBeforeStartTaskRuns() async {
        let fixture = Fixture()

        fixture.press()
        fixture.controller.cancel()
        await settle()

        #expect(fixture.recognizer.startCount == 0)
        #expect(fixture.recognizer.state == .idle)
        #expect(!fixture.controller.isRecording)
    }

    @Test("松手后正常收尾，把识别出的文字交给会话")
    func sendsRecognizedText() async {
        let fixture = Fixture()
        var received: [String] = []

        await fixture.pressAndRelease { received.append($0) }
        fixture.recognizer.finishStop(with: "午饭 28")
        await settle()

        #expect(received == ["午饭 28"])
        #expect(!fixture.controller.isFinishing)
    }

    @Test("等待最终文字期间取消，识别结果迟到也不发送")
    func cancelWhileFinishingDropsText() async {
        let fixture = Fixture()
        var received: [String] = []

        await fixture.pressAndRelease { received.append($0) }
        fixture.controller.cancel()
        fixture.recognizer.finishStop(with: "午饭 28")
        await settle()

        #expect(received.isEmpty)
    }

    @Test("上一句还在收尾时不接受新的按下，收尾结束后恢复")
    func ignoresPressWhileFinishing() async {
        let fixture = Fixture()

        await fixture.pressAndRelease { _ in }
        #expect(fixture.controller.isFinishing)

        fixture.press()
        #expect(!fixture.controller.isPressing)
        #expect(!fixture.controller.isRecording)

        fixture.recognizer.finishStop(with: "")
        await settle()
        #expect(!fixture.controller.isFinishing)

        fixture.press()
        await waitUntil { fixture.recognizer.startCount == 2 }
        #expect(fixture.controller.isRecording)
    }

    @Test("没按满时长就松手：不打开麦克风、不发送，只提示要按住说话")
    func releaseBeforeHoldDelayShowsHint() async {
        let fixture = Fixture(holdDelay: .seconds(60))
        var received: [String] = []

        fixture.press()
        await settle()
        #expect(!fixture.controller.isRecording)
        fixture.controller.pressEnded(onText: { received.append($0) })
        await settle()

        #expect(fixture.recognizer.startCount == 0)
        #expect(received.isEmpty)
        #expect(fixture.controller.transientHint == AccountLocalization.string("voice.mic.holdHint", locale: Fixture.locale))
    }

    @Test("手指按下后不移动，按满时长也会开始收音")
    func startsWithoutMovementAfterHoldDelay() async {
        let fixture = Fixture(holdDelay: .milliseconds(50))

        fixture.press()
        #expect(!fixture.controller.isRecording)
        try? await Task.sleep(for: .milliseconds(200))
        await waitUntil { fixture.recognizer.startCount == 1 }

        #expect(fixture.controller.isRecording)
    }

    @Test("上滑超过取消距离后松手，取消识别且不发送")
    func releaseAfterSlidingUpCancels() async {
        let fixture = Fixture()
        var received: [String] = []

        fixture.press()
        await waitUntil { fixture.recognizer.startCount == 1 }
        fixture.controller.pressMoved(verticalTranslation: -VoiceInputController.cancelDistance - 1)
        #expect(fixture.controller.isCancelArmed)

        fixture.controller.pressEnded(onText: { received.append($0) })
        await settle()

        #expect(fixture.recognizer.cancelCount == 1)
        #expect(!fixture.recognizer.hasPendingStop)
        #expect(received.isEmpty)
        #expect(!fixture.controller.isRecording)
        #expect(!fixture.controller.isFinishing)
    }

    @Test("上滑后移回取消距离以内，松手仍正常发送")
    func movingBackFromCancelAreaRestoresSending() async {
        let fixture = Fixture()
        var received: [String] = []

        fixture.press()
        await waitUntil { fixture.recognizer.startCount == 1 }
        fixture.controller.pressMoved(verticalTranslation: -VoiceInputController.cancelDistance - 1)
        fixture.controller.pressMoved(verticalTranslation: 0)
        #expect(!fixture.controller.isCancelArmed)

        fixture.controller.pressEnded(onText: { received.append($0) })
        await waitUntil { fixture.recognizer.hasPendingStop }
        fixture.recognizer.finishStop(with: "午饭 28")
        await settle()

        #expect(received == ["午饭 28"])
        #expect(fixture.recognizer.cancelCount == 0)
    }

    @Test("触摸在收音期间被系统取消，之后松手也不发送")
    func cancelledTouchDoesNotSendOnLaterRelease() async {
        let fixture = Fixture()
        var received: [String] = []

        fixture.press()
        await waitUntil { fixture.recognizer.startCount == 1 }
        fixture.controller.cancel()
        fixture.controller.pressEnded(onText: { received.append($0) })
        await settle()

        #expect(fixture.recognizer.cancelCount == 1)
        #expect(!fixture.recognizer.hasPendingStop)
        #expect(received.isEmpty)
        #expect(!fixture.controller.isPressing)
        #expect(!fixture.controller.isFinishing)
    }

    @Test("识别器启动还没完成时松手：立即停止采集，启动完成后照常发送")
    func releaseWhileStartingStopsCaptureImmediately() async {
        let fixture = Fixture()
        fixture.recognizer.holdsStart = true
        var received: [String] = []

        fixture.press()
        await waitUntil { fixture.recognizer.state == .starting }
        fixture.controller.pressEnded(onText: { received.append($0) })

        #expect(!fixture.recognizer.isCapturing)
        #expect(fixture.controller.isFinishing)
        #expect(!fixture.recognizer.hasPendingStop)

        fixture.recognizer.finishStart()
        await waitUntil { fixture.recognizer.hasPendingStop }
        fixture.recognizer.finishStop(with: "午饭 28")
        await settle()

        #expect(received == ["午饭 28"])
    }

    @Test("识别器启动还没完成时上滑取消：立即作废，启动迟到也不提示、不发送")
    func cancelWhileStartingDropsImmediately() async {
        let fixture = Fixture()
        fixture.recognizer.holdsStart = true
        var received: [String] = []

        fixture.press()
        await waitUntil { fixture.recognizer.state == .starting }
        fixture.controller.pressMoved(verticalTranslation: -VoiceInputController.cancelDistance - 1)
        fixture.controller.pressEnded(onText: { received.append($0) })

        #expect(fixture.recognizer.cancelCount == 1)
        #expect(!fixture.recognizer.isCapturing)
        #expect(!fixture.controller.isFinishing)

        fixture.recognizer.finishStart()
        await settle()

        #expect(!fixture.recognizer.hasPendingStop)
        #expect(received.isEmpty)
        #expect(fixture.controller.alert == nil)
    }

    @Test("按住说了话但没识别到文字时静默结束")
    func emptyTextEndsSilently() async {
        let fixture = Fixture()
        var received: [String] = []

        await fixture.pressAndRelease { received.append($0) }
        fixture.recognizer.finishStop(with: "")
        await settle()

        #expect(received.isEmpty)
        #expect(fixture.controller.transientHint == nil)
        #expect(!fixture.controller.isFinishing)
    }

    // MARK: - 辅助

    /// 一次测试使用的假识别器与交互逻辑；权限视为已授权，默认不等按住时长。
    @MainActor
    private final class Fixture {
        let recognizer: FakeSpeechRecognizer
        let controller: VoiceInputController

        init(holdDelay: Duration = .zero) {
            let recognizer = FakeSpeechRecognizer()
            self.recognizer = recognizer
            controller = VoiceInputController(recognizer: recognizer, permission: { .granted }, holdDelay: holdDelay)
        }

        /// 识别与提示使用的语言。
        static let locale = Locale(identifier: "zh-Hans")

        /// 已登录状态下按下麦克风。
        func press() {
            controller.pressBegan(isSignedIn: true, locale: Self.locale, contextualStrings: { [] })
        }

        /// 按下、等收音开始后松手，停在等待最终文字的状态。
        func pressAndRelease(onText: @escaping (String) -> Void) async {
            press()
            await waitUntil { recognizer.startCount == 1 }
            controller.pressEnded(onText: onText)
            await waitUntil { recognizer.hasPendingStop }
        }
    }
}

/// 让主线程上排队的任务跑完。
@MainActor
private func settle() async {
    for _ in 0..<20 {
        await Task.yield()
    }
}

/// 让出主线程，直到条件成立或达到次数上限。
@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<100 {
        if condition() { return }
        await Task.yield()
    }
}

/// 不接触麦克风的假识别器：默认启动立即进入收音，也可挂在启动中；松手后挂起，直到测试交出最终文字。
@MainActor
private final class FakeSpeechRecognizer: VoiceSpeechRecognizing {
    private(set) var state = VoiceSpeechRecognizer.State.idle
    private(set) var transcript = ""

    /// 真正开始收音的次数。
    private(set) var startCount = 0

    /// 丢弃识别的次数，用于区分上滑取消和正常松手收尾。
    private(set) var cancelCount = 0

    /// 是否让启动挂起，直到测试调用 `finishStart()`，用于模拟模型加载较慢。
    var holdsStart = false

    /// 麦克风是否还在采集。
    private(set) var isCapturing = false

    private var startContinuation: CheckedContinuation<Void, Never>?
    private var stopContinuation: CheckedContinuation<String, Never>?

    /// 是否有松手后还在等待最终文字的收尾。
    var hasPendingStop: Bool { stopContinuation != nil }

    func start(locale: Locale, contextualStrings: [String]) async throws {
        guard state == .idle else { return }
        startCount += 1
        state = .starting
        isCapturing = true
        if holdsStart {
            await withCheckedContinuation { continuation in
                startContinuation = continuation
            }
            // 与真实识别器一致：启动期间被取消时抛错
            guard state == .starting else { throw CancellationError() }
        }
        state = .recording
    }

    func stopCapture() {
        isCapturing = false
    }

    func stop() async -> String {
        guard state == .recording else { return "" }
        state = .finishing
        return await withCheckedContinuation { continuation in
            stopContinuation = continuation
        }
    }

    func cancel() {
        cancelCount += 1
        isCapturing = false
        state = .idle
    }

    /// 结束挂起的启动。
    func finishStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    /// 交出最终文字，结束挂起的收尾。
    func finishStop(with text: String) {
        state = .idle
        stopContinuation?.resume(returning: text)
        stopContinuation = nil
    }
}
