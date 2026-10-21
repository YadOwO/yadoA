import Foundation
import Testing
@testable import yadoA

/// 麦克风按钮交互的时序：取消后不能再收音或发送，上一句收尾期间不接受新的按下。
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

    @Test("按住不足 0.3 秒按点按处理：放弃收音，不发送文字")
    func shortPressIsTap() async {
        let fixture = Fixture()
        var tapCount = 0
        var received: [String] = []

        fixture.press()
        await waitUntil { fixture.recognizer.startCount == 1 }
        fixture.clock.date = fixture.clock.date.addingTimeInterval(0.1)
        fixture.controller.pressEnded(onTap: { tapCount += 1 }, onText: { received.append($0) })
        await settle()

        #expect(tapCount == 1)
        #expect(received.isEmpty)
        #expect(fixture.recognizer.cancelCount == 1)
        #expect(fixture.recognizer.state == .idle)
    }

    // MARK: - 辅助

    /// 一次测试使用的假识别器、时钟与交互逻辑；权限视为已授权。
    @MainActor
    private final class Fixture {
        let recognizer: FakeSpeechRecognizer
        let clock: InputTestClock
        let controller: VoiceInputController

        init() {
            let recognizer = FakeSpeechRecognizer()
            let clock = InputTestClock()
            self.recognizer = recognizer
            self.clock = clock
            controller = VoiceInputController(
                recognizer: recognizer,
                permission: { .granted },
                now: { clock.date }
            )
        }

        /// 已登录状态下按下麦克风。
        func press() {
            controller.pressBegan(isSignedIn: true, locale: Locale(identifier: "zh-Hans"), contextualStrings: { [] })
        }

        /// 按下、等收音开始、按住 1 秒后松手，停在等待最终文字的状态。
        func pressAndRelease(onText: @escaping (String) -> Void) async {
            press()
            await waitUntil { recognizer.startCount == 1 }
            clock.date = clock.date.addingTimeInterval(1)
            controller.pressEnded(onTap: {}, onText: onText)
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

/// 可手动推进的时钟。
@MainActor
private final class InputTestClock {
    /// 当前时间。
    var date = Date(timeIntervalSince1970: 1_792_470_600)
}

/// 不接触麦克风的假识别器：启动立即进入收音，松手后挂起，直到测试交出最终文字。
@MainActor
private final class FakeSpeechRecognizer: VoiceSpeechRecognizing {
    private(set) var state = VoiceSpeechRecognizer.State.idle
    private(set) var transcript = ""

    /// 真正开始收音的次数。
    private(set) var startCount = 0

    /// 被取消的次数。
    private(set) var cancelCount = 0

    private var stopContinuation: CheckedContinuation<String, Never>?

    /// 是否有松手后还在等待最终文字的收尾。
    var hasPendingStop: Bool { stopContinuation != nil }

    func start(locale: Locale, contextualStrings: [String]) async throws {
        guard state == .idle else { return }
        startCount += 1
        state = .recording
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
        state = .idle
    }

    /// 交出最终文字，结束挂起的收尾。
    func finishStop(with text: String) {
        state = .idle
        stopContinuation?.resume(returning: text)
        stopContinuation = nil
    }
}
