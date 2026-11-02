import Testing
@testable import yadoA

@Suite("芽豆插画时间轴")
@MainActor
struct SproutTimelineTests {
    @Test("墨线七笔的落笔时刻从 0 开始递增，且都在书写时长内")
    func strokeStartTimesFollowDrawingOrder() {
        let times = SproutTimeline.strokeStartTimes
        // 地面、两笔根须、茎、左叶、叶脉、右叶
        #expect(times.count == 7)
        #expect(abs((times.first ?? 1) - 0) < 0.001)
        #expect(zip(times, times.dropFirst()).allSatisfy { $0 < $1 })
        #expect(times.allSatisfy { $0 < SproutTimeline.lineDuration })
    }

    @Test("豆子落定与余震取自弹簧曲线：先放大到原大小，冲过头后再回落")
    func beanHapticsFollowSpring() {
        let landing = SproutTimeline.beanLandingOffset
        let rebound = SproutTimeline.beanReboundOffset
        // duration 0.5、bounce 0.55 的弹簧约 0.18 秒到达原大小、约 0.46 秒回落
        #expect((0.12...0.25).contains(landing))
        #expect(rebound > landing)
        #expect(rebound < 0.6)
        // 闪光短线的触感相对豆子弹出那一刻排布，必须在其之后
        #expect(SproutTimeline.sparkleStrokeTimes.allSatisfy { $0 > SproutTimeline.beanStart })
    }

    @Test("三道闪光短线的触感落在闪光划出的时间段内")
    func sparkleStrokeTimesStayInsideSparkleWindow() {
        let times = SproutTimeline.sparkleStrokeTimes
        #expect(times.count == 3)
        #expect(abs((times.first ?? 0) - SproutTimeline.sparkleStart) < 0.001)
        #expect(times.allSatisfy { $0 < SproutTimeline.sparkleStart + SproutTimeline.sparkleDuration })
    }
}
