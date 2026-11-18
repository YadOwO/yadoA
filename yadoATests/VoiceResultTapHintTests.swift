import Foundation
import Testing
@testable import yadoA

/// 语音卡片「点一下可以查看」提示的出现次数与学会后的收起，用隔离的本机存储验证。
@Suite("语音结果可点提示", .serialized)
@MainActor
struct VoiceResultTapHintTests {
    @Test("没学会时最多在 3 轮里出现，同一轮反复出现只计一次，计满那一轮仍然显示")
    func showsInLimitedTurns() throws {
        let (defaults, cleanup) = try makeDefaults("limit")
        defer { cleanup() }
        let hint = VoiceResultTapHint(defaults: defaults)
        let turns = (0..<VoiceResultTapHint.maxShownCount).map { _ in UUID() }

        for turn in turns {
            #expect(hint.shouldShow(for: turn))
            hint.markShown(turnID: turn)
            hint.markShown(turnID: turn)
        }
        #expect(hint.shownCount == VoiceResultTapHint.maxShownCount)
        // 计满的最后一轮还留在卡片上，继续显示到这一轮结束
        let lastTurn = try #require(turns.last)
        #expect(hint.shouldShow(for: lastTurn))
        // 新的一轮不再显示，也不再计数
        let next = UUID()
        #expect(!hint.shouldShow(for: next))
        hint.markShown(turnID: next)
        #expect(hint.shownCount == VoiceResultTapHint.maxShownCount)

        // 重启后从本机读回次数，新的一轮仍然不显示
        let relaunched = VoiceResultTapHint(defaults: defaults)
        #expect(relaunched.shownCount == VoiceResultTapHint.maxShownCount)
        #expect(!relaunched.shouldShow(for: UUID()))
    }

    @Test("点过一次结果后立即收起，重启后也不再出现")
    func learnedHidesForever() throws {
        let (defaults, cleanup) = try makeDefaults("learned")
        defer { cleanup() }
        let hint = VoiceResultTapHint(defaults: defaults)
        let turn = UUID()
        hint.markShown(turnID: turn)
        #expect(hint.shouldShow(for: turn))

        hint.markLearned()
        #expect(hint.isLearned)
        #expect(!hint.shouldShow(for: turn))
        #expect(!hint.shouldShow(for: UUID()))

        let relaunched = VoiceResultTapHint(defaults: defaults)
        #expect(relaunched.isLearned)
        #expect(!relaunched.shouldShow(for: UUID()))
    }

    @Test("提示文案两种语言都有")
    func hintIsLocalized() {
        for localeID in ["en", "zh-Hans"] {
            let value = AccountLocalization.string("voice.change.tapHint", locale: Locale(identifier: localeID))
            #expect(value != "voice.change.tapHint")
        }
    }

    /// 每个用例一份隔离的本机存储，结束时清掉。
    private func makeDefaults(_ name: String) throws -> (UserDefaults, () -> Void) {
        let suiteName = "VoiceResultTapHintTests.\(name)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }
}
