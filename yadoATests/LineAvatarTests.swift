import CoreGraphics
import Foundation
import Testing
@testable import yadoA

@Suite("线条头像")
struct LineAvatarTests {
    // MARK: - SVG 路径

    @Test("相对坐标与绝对坐标解析结果一致，Z 回到起点并视为闭合")
    func parsesRelativeCommandsAndClose() {
        let absolute = LineAvatarGeometry.polyline(fromSVGPath: "M10 10 L20 10 L20 20 Z")
        let relative = LineAvatarGeometry.polyline(fromSVGPath: "m10 10 l10 0 l0 10 z")

        #expect(absolute == [CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 10), CGPoint(x: 20, y: 20), CGPoint(x: 10, y: 10)])
        #expect(relative == absolute)
        #expect(LineAvatarGeometry.isClosed(absolute))
        #expect(!LineAvatarGeometry.isClosed(LineAvatarGeometry.polyline(fromSVGPath: "M0 0 L10 0 L10 10")))
    }

    @Test("支持 H/V 命令，以及负号、第二个小数点直接分隔数字的紧凑写法")
    func parsesCompactNumbersAndAxisLines() {
        #expect(
            LineAvatarGeometry.polyline(fromSVGPath: "M0 0 H10 V5 h-5 v-5")
                == [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 5), CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 0)]
        )
        #expect(
            LineAvatarGeometry.polyline(fromSVGPath: "M1-2L3.5.5")
                == [CGPoint(x: 1, y: -2), CGPoint(x: 3.5, y: 0.5)]
        )
    }

    @Test("曲线按段细分，终点精确落在路径终点上")
    func curvesEndOnTheirEndPoints() {
        let cubic = LineAvatarGeometry.polyline(fromSVGPath: "M0 0 C10 0 20 10 30 10")
        let quad = LineAvatarGeometry.polyline(fromSVGPath: "M0 0 Q15 20 30 0")

        #expect(cubic.first == CGPoint(x: 0, y: 0))
        #expect(cubic.last == CGPoint(x: 30, y: 10))
        #expect(cubic.count > 10)
        #expect(quad.last == CGPoint(x: 30, y: 0))
    }

    // MARK: - 取样与对齐

    @Test("按弧长均匀取样，可以只取其中一段")
    func resamplesByArcLength() {
        let line = [CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 0), CGPoint(x: 63, y: 0)]
        let points = LineAvatarGeometry.resample(line)

        #expect(points.count == LineAvatarGeometry.pointCount)
        for (index, point) in points.enumerated() {
            #expect(abs(point.x - CGFloat(index)) < 0.0001)
            #expect(point.y == 0)
        }

        let half = LineAvatarGeometry.resample(line, from: 0.5, to: 1, count: 2)
        #expect(half == [CGPoint(x: 31.5, y: 0), CGPoint(x: 63, y: 0)])
    }

    @Test("开放的线方向相反时翻回来，闭合的线换回最贴近的起点")
    func alignsDirectionAndStartPoint() {
        let line = LineAvatarGeometry.resample([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)])
        #expect(LineAvatarGeometry.aligned(Array(line.reversed()), isClosed: false, to: line) == line)

        let ringCount = LineAvatarGeometry.pointCount - 1
        let ring = (0..<ringCount).map { index in
            let angle = CGFloat(index) / CGFloat(ringCount) * 2 * .pi
            return CGPoint(x: 50 + 20 * cos(angle), y: 50 + 20 * sin(angle))
        }
        let circle = ring + [ring[0]]
        let rotatedRing = Array(ring[10...] + ring[..<10])
        let rotated = rotatedRing + [rotatedRing[0]]

        #expect(LineAvatarGeometry.aligned(rotated, isClosed: true, to: circle) == circle)
        #expect(LineAvatarGeometry.aligned(Array(circle.reversed()), isClosed: true, to: circle) == circle)
    }

    // MARK: - 头像目录与 logo

    @Test("预制头像 ID 唯一，每条线都能解析成固定点数并落在画布内，脸的轮廓闭合")
    func catalogIsWellFormed() {
        let ids = LineAvatarCatalog.presets.map(\.id)
        #expect(ids.count >= 8)
        #expect(Set(ids).count == ids.count)

        for preset in LineAvatarCatalog.presets {
            let figure = preset.figure
            #expect(figure.strokes[.outline]?.isClosed == true, "\(preset.id) 缺少闭合的脸部轮廓")
            for (slot, stroke) in figure.strokes {
                #expect(stroke.points.count == LineAvatarGeometry.pointCount)
                #expect(
                    stroke.points.allSatisfy { (0...100).contains($0.x) && (0...100).contains($0.y) },
                    "\(preset.id).\(slot) 超出画布"
                )
            }
            #expect(LineAvatarCatalog.preset(id: preset.id) == preset)
        }
        #expect(LineAvatarCatalog.preset(id: "missing") == nil)
    }

    @Test("logo 每一笔被各槽位首尾相接地分完，2 秒写完时每段都已写出")
    func logoSegmentsCoverEachStroke() {
        for index in LineAvatarLogo.strokes.indices {
            let parts = LineAvatarLogo.segments.values
                .filter { $0.strokeIndex == index }
                .sorted { $0.from < $1.from }
            #expect(parts.first?.from == 0)
            #expect(parts.last?.to == 1)
            for (previous, next) in zip(parts, parts.dropFirst()) {
                #expect(previous.to == next.from)
            }
        }
        #expect(LineAvatarLogo.segments[.accent] == nil)
        #expect(abs(LineAvatarLogo.drawDuration - 2) < 0.0001)

        for slot in LineAvatarLogo.segments.keys {
            #expect(LineAvatarLogo.reveal(of: slot, elapsed: 0) == 0)
            #expect(LineAvatarLogo.reveal(of: slot, elapsed: LineAvatarLogo.drawDuration) == 1)
        }

        let figure = LineAvatarLogo.figure
        #expect(figure.strokes.count == LineAvatarLogo.segments.count)
        for stroke in figure.strokes.values {
            #expect(stroke.points.allSatisfy { (0...100).contains($0.x) && (0...100).contains($0.y) })
        }
    }

    @Test("同一笔里靠后的段要等前面的段写完才开始")
    func logoSegmentsRevealInOrder() {
        // 0.45 秒时第一笔约写到 48%：开头那段（0–25%）已写完，结尾那段（65%–100%）还没开始
        let midway = 0.45
        #expect(LineAvatarLogo.reveal(of: .leftDetail, elapsed: midway) == 1)
        #expect(LineAvatarLogo.reveal(of: .rightEar, elapsed: midway) == 0)
        // 第三笔在 1.5 秒才开始
        #expect(LineAvatarLogo.reveal(of: .outline, elapsed: 1.4) == 0)
    }

    // MARK: - 缓动与弹簧

    @Test("贝塞尔缓动从 0 到 1 单调递增")
    func timingCurveIsMonotonic() {
        let curve = LineAvatarTimingCurve(0.55, 0.06, 0.36, 1)
        #expect(curve.value(at: 0) == 0)
        #expect(curve.value(at: 1) == 1)
        var previous: CGFloat = 0
        for step in 1...20 {
            let value = curve.value(at: CGFloat(step) / 20)
            #expect(value >= previous)
            previous = value
        }
    }

    @Test("弹簧从 0 出发、带轻微过冲，时间进度到 1 时正好落在 1")
    func springOvershootsSlightlyAndSettles() {
        #expect(LineAvatarSpring.progress(0) == 0)
        #expect(LineAvatarSpring.progress(1) == 1)
        let peak = (1...99).map { LineAvatarSpring.progress(CGFloat($0) / 100) }.max() ?? 0
        #expect(peak > 1)
        #expect(peak < 1.1)
        #expect(abs(LineAvatarSpring.progress(0.99) - 1) < 0.005)
    }

    // MARK: - 动画时间线

    @Test("变形开始时停在原头像，结束后停在目标头像，目标里没有的线缩到看不见")
    func morphStartsFromCurrentAndSettlesOnTarget() throws {
        let cat = try #require(LineAvatarCatalog.preset(id: "cat"))
        let chick = try #require(LineAvatarCatalog.preset(id: "chick"))
        var animator = LineAvatarAnimator(resting: cat.figure)
        animator.morph(to: chick.figure, at: 100)

        let start = animator.frames(at: 100)
        #expect(start[.outline]?.points == cat.figure.strokes[.outline]?.points)
        #expect(start[.leftDetail]?.presence == 1)

        #expect(animator.endTime > 100)
        let end = animator.frames(at: animator.endTime + 1)
        for slot in LineAvatarSlot.allCases {
            if let stroke = chick.figure.strokes[slot] {
                let frame = try #require(end[slot])
                #expect(frame.presence == 1)
                #expect(frame.reveal == 1)
                #expect(frame.accentMix == (stroke.tint == .accent ? 1 : 0))
                // 只换了方向或起点，形状不变
                #expect(Set(frame.points.map { [$0.x, $0.y] }) == Set(stroke.points.map { [$0.x, $0.y] }))
            } else if cat.figure.strokes[slot] != nil {
                #expect(end[slot]?.presence == 0)
            }
        }
    }

    @Test("logo 书写途中开始变形：还没写出的线直接在目标位置长出来")
    func morphDuringLogoGrowsHiddenStrokesInPlace() throws {
        let dog = try #require(LineAvatarCatalog.preset(id: "dog"))
        var animator = LineAvatarAnimator()
        animator.startLogoDrawing(at: 0)

        let beginning = animator.frames(at: 0)
        #expect(beginning.count == LineAvatarLogo.segments.count)
        #expect(beginning.values.allSatisfy { $0.reveal == 0 })
        #expect(animator.frames(at: LineAvatarLogo.drawDuration).values.allSatisfy { $0.reveal == 1 })

        // 0.5 秒时第三笔还没开始写，右眼看不见；logo 里也没有舌头
        animator.morph(to: dog.figure, at: 0.5)
        let frames = animator.frames(at: 0.5)
        #expect(frames[.rightEye]?.points == dog.figure.strokes[.rightEye]?.points)
        #expect(frames[.accent]?.points == dog.figure.strokes[.accent]?.points)
        #expect(frames[.accent]?.presence == 0)
    }

    @Test("立即切换没有过渡，结束时间不晚于现在")
    func jumpHasNoTransition() throws {
        let bear = try #require(LineAvatarCatalog.preset(id: "bear"))
        var animator = LineAvatarAnimator()
        animator.jump(to: bear.figure)

        #expect(animator.endTime == 0)
        #expect(animator.frames(at: 0) == LineAvatarStrokeFrame.resting(bear.figure))
    }

    // MARK: - 换一换

    @Test("换一换不会连着出现同一个头像，第一轮不重复")
    func deckNeverRepeatsBackToBack() throws {
        var deck = LineAvatarDeck(ids: ["a", "b", "c", "d"])
        var generator = SplitMix64(seed: 7)
        var current: String?
        var history: [String] = []
        for _ in 0..<40 {
            let next = try #require(deck.next(after: current, using: &generator))
            #expect(next != current)
            history.append(next)
            current = next
        }
        #expect(Set(history.prefix(4)).count == 4)
    }

    @Test("只有一个头像时返回它本身，没有头像时返回 nil")
    func deckEdgeCases() {
        var single = LineAvatarDeck(ids: ["only"])
        #expect(single.next(after: nil) == "only")
        #expect(single.next(after: "only") == "only")

        var empty = LineAvatarDeck(ids: [])
        #expect(empty.next(after: nil) == nil)
    }
}

/// 可复现的随机数来源，用于固定洗牌结果。
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
