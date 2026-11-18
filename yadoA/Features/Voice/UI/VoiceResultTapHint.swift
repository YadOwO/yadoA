import Foundation
import Observation

/// 语音卡片结果下方「点一下可以查看」的一次性提示。
///
/// 语音记完账、建完账户后，结果行可以点开定位或查看详情，但不少用户不知道。最新一轮出现可以点的结果时，
/// 在结果下面写一句提示；用户从卡片上点过任意一行结果，或已经在 `maxShownCount` 轮里看过，就不再出现。
/// 学会与否存在本机，不随账本同步，也不随清除数据重置。
@MainActor
@Observable
final class VoiceResultTapHint {
    /// 应用内唯一的提示状态。
    static let shared = VoiceResultTapHint()

    /// 用户是否已经点过结果行的本机存储键。
    static let learnedKey = "voice.resultTapHint.learned"

    /// 提示已经在几轮里出现过的本机存储键。
    static let shownCountKey = "voice.resultTapHint.shownCount"

    /// 最多在几轮结果下面出现；看过这么多次还没点，说明用户不需要，不再打扰。
    static let maxShownCount = 3

    /// 用户是否已经从卡片上点过结果行。
    private(set) var isLearned: Bool

    /// 提示已经在几轮里出现过。
    private(set) var shownCount: Int

    /// 本次启动里已经计过数的轮次；同一轮反复出现在卡片上只算一次，也保证计满之后这一轮仍然显示到结束。
    private var countedTurnIDs: Set<UUID> = []

    private let defaults: UserDefaults

    /// 读取本机保存的提示状态。
    ///
    /// - Parameter defaults: 保存状态的本机存储，测试时注入隔离实例。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isLearned = defaults.bool(forKey: Self.learnedKey)
        shownCount = defaults.integer(forKey: Self.shownCountKey)
    }

    /// 这一轮的结果下面是否要显示提示。
    ///
    /// - Parameter turnID: 卡片上最新一轮的标识。
    /// - Returns: 用户还没学会，并且这一轮已经计过数或还没用完次数时为 true。
    func shouldShow(for turnID: UUID) -> Bool {
        guard !isLearned else { return false }
        return countedTurnIDs.contains(turnID) || shownCount < Self.maxShownCount
    }

    /// 提示在这一轮出现了，计一次；同一轮只计一次。
    ///
    /// - Parameter turnID: 出现提示的轮次标识。
    func markShown(turnID: UUID) {
        guard !isLearned, shownCount < Self.maxShownCount, countedTurnIDs.insert(turnID).inserted else { return }
        shownCount += 1
        defaults.set(shownCount, forKey: Self.shownCountKey)
    }

    /// 用户从卡片上点了一行结果，之后不再提示。
    func markLearned() {
        guard !isLearned else { return }
        isLearned = true
        defaults.set(true, forKey: Self.learnedKey)
    }
}
