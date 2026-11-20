import CoreGraphics
import Foundation
import Testing
@testable import yadoA

/// 验证开礼包仪式的分量：周、月、年一级比一级重，周礼包保持原来的节奏，数字滚动和礼盒姿态的计算符合预期。
@Suite("开礼包仪式")
struct CheckInGiftCeremonyTests {
    private let weekly = AICheckInGiftTier.weekly.ceremony
    private let monthly = AICheckInGiftTier.monthly.ceremony
    private let yearly = AICheckInGiftTier.yearly.ceremony

    /// 某个仪式所有彩纸（舞台和整屏）的总片数。
    private func confettiCount(_ ceremony: CheckInGiftCeremony) -> Int {
        (ceremony.stageConfetti + ceremony.screenConfetti).reduce(0) { $0 + $1.count }
    }

    @Test("档位对应仪式级别，不认识的档位按周礼包")
    func mapsTierToLevel() {
        #expect(weekly.level == .light)
        #expect(monthly.level == .grand)
        #expect(yearly.level == .epic)
        #expect(AICheckInGiftTier.unknown.ceremony == weekly)
    }

    @Test("周礼包保持原来的时长、大小和彩纸")
    func weeklyKeepsBaseline() {
        #expect(weekly.chargeDuration == 1.1)
        #expect(weekly.rollDuration == 0.9)
        #expect(weekly.maxRollSteps == 24)
        #expect(weekly.boxSize == 188)
        #expect(weekly.rayCount == 14)
        #expect(confettiCount(weekly) == 40)
        #expect(weekly.flashPeak == 0)
        #expect(weekly.shockwaveCount == 0)
        #expect(weekly.screenShake == 0)
        #expect(weekly.sparkleCount == 0)
        #expect(weekly.landingPunch == 0)
        #expect(weekly.screenConfetti.isEmpty)
        #expect(!weekly.hasSeal)
    }

    @Test("周、月、年一级比一级重")
    func escalatesByTier() {
        let ladder = [weekly, monthly, yearly]
        for (lighter, heavier) in zip(ladder, ladder.dropFirst()) {
            #expect(lighter.level < heavier.level)
            #expect(lighter.chargeDuration < heavier.chargeDuration)
            #expect(lighter.rollDuration < heavier.rollDuration)
            #expect(lighter.boxSize < heavier.boxSize)
            #expect(lighter.sunburstSize < heavier.sunburstSize)
            #expect(lighter.rayCount < heavier.rayCount)
            #expect(lighter.numberFontSize < heavier.numberFontSize)
            #expect(lighter.flashPeak < heavier.flashPeak)
            #expect(lighter.shockwaveCount < heavier.shockwaveCount)
            #expect(lighter.screenShake < heavier.screenShake)
            #expect(lighter.sparkleCount < heavier.sparkleCount)
            #expect(lighter.landingPunch < heavier.landingPunch)
            #expect(lighter.chargeGlow < heavier.chargeGlow)
            #expect(lighter.beamCount < heavier.beamCount)
            #expect(lighter.popSquash > heavier.popSquash)
            #expect(confettiCount(lighter) < confettiCount(heavier))
            let lighterConfetti = (lighter.stageConfetti + lighter.screenConfetti).map(\.totalDuration).max() ?? 0
            let heavierConfetti = (heavier.stageConfetti + heavier.screenConfetti).map(\.totalDuration).max() ?? 0
            #expect(lighterConfetti < heavierConfetti)
        }
    }

    @Test("礼炮、漫天星星、内层光芒和印章只有年度礼包有")
    func yearlyOnlyExtras() {
        #expect(!yearly.screenConfetti.isEmpty)
        #expect(monthly.screenConfetti.isEmpty)
        #expect(yearly.hasSeal && !monthly.hasSeal)
        #expect(yearly.hasInnerRays && !monthly.hasInnerRays && !weekly.hasInnerRays)
        #expect(yearly.hasLandingRipple && !monthly.hasLandingRipple)
    }

    @Test("数字滚动的时刻严格递增、最后正好是滚动时长，月和年越到后面越慢")
    func rollTimesSlowDown() throws {
        for ceremony in [weekly, monthly, yearly] {
            let times = ceremony.rollTimes(steps: 20)
            #expect(times.count == 20)
            #expect(zip(times, times.dropFirst()).allSatisfy { $0 < $1 })
            let last = try #require(times.last)
            #expect(abs(last - ceremony.rollDuration) < 1e-9)
        }

        // 周礼包匀速
        let weeklyTimes = weekly.rollTimes(steps: 10)
        let weeklyGaps = zip(weeklyTimes, weeklyTimes.dropFirst()).map { $1 - $0 }
        #expect(weeklyGaps.allSatisfy { abs($0 - 0.09) < 1e-9 })

        // 月礼包、年度礼包最后一跳的间隔比第二跳长
        for ceremony in [monthly, yearly] {
            let times = ceremony.rollTimes(steps: 10)
            #expect(times[9] - times[8] > times[2] - times[1])
        }

        #expect(yearly.rollTimes(steps: 0).count == 1)
    }

    @Test("每跳的点数均匀增加，最后一跳正好是获得的点数")
    func rolledValueEndsAtPoints() {
        let values = (1...24).map { CheckInGiftCeremony.rolledValue(points: 365, step: $0, of: 24) }
        #expect(values.last == 365)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 })
        #expect(CheckInGiftCeremony.rolledValue(points: 50, step: 16, of: 32) == 25)
        #expect(CheckInGiftCeremony.rolledValue(points: 7, step: 1, of: 1) == 7)
        #expect(CheckInGiftCeremony.rolledValue(points: 7, step: 3, of: 0) == 7)
    }

    @Test("蓄力从静止开始，结束前晃动归零、礼盒落回原地")
    func chargeStartsAndSettlesAtRest() {
        for ceremony in [weekly, monthly, yearly] {
            let start = ceremony.chargePose(elapsed: 0)
            #expect(abs(start.angle) < 1e-9)
            #expect(start.offsetY == 0)

            let end = ceremony.chargePose(elapsed: ceremony.chargeDuration - 0.0001)
            #expect(abs(end.angle) < 0.05)
            #expect(abs(end.offsetY) < 0.05)

            #expect(ceremony.chargePose(elapsed: -1) == .rest)
        }
    }

    @Test("只有年度礼包蓄力后段会悬起，盒缝的光随蓄力变亮")
    func chargeLevitatesAndGlows() {
        let late = 0.8
        #expect(yearly.chargePose(elapsed: yearly.chargeDuration * late).offsetY < -10)
        #expect(monthly.chargePose(elapsed: monthly.chargeDuration * late).offsetY == 0)
        #expect(weekly.chargePose(elapsed: weekly.chargeDuration * late).offsetY == 0)

        for ceremony in [monthly, yearly] {
            let early = ceremony.chargePose(elapsed: ceremony.chargeDuration * 0.2).glow
            let later = ceremony.chargePose(elapsed: ceremony.chargeDuration * late).glow
            #expect(early < later)
        }
        #expect(weekly.chargePose(elapsed: weekly.chargeDuration * late).glow == 0)
    }

    @Test("请求比蓄力慢时周礼包停住，月和年原地颤动、保持透光")
    func holdsWhileWaiting() {
        #expect(weekly.chargePose(elapsed: weekly.chargeDuration + 0.5) == .rest)
        for ceremony in [monthly, yearly] {
            let hold = ceremony.chargePose(elapsed: ceremony.chargeDuration + 0.5)
            #expect(hold.glow > 0.5)
            #expect(hold.offsetY == 0)
        }
    }

    @Test("待开时只有年度礼包的盒缝发光")
    func idleGlowOnlyForYearly() {
        for time in stride(from: 0.0, to: 4, by: 0.25) {
            #expect(weekly.idlePose(time: time).glow == 0)
            #expect(monthly.idlePose(time: time).glow == 0)
            #expect(yearly.idlePose(time: time).glow > 0)
            #expect(abs(weekly.idlePose(time: time).offsetY) <= 5)
        }
    }
}
