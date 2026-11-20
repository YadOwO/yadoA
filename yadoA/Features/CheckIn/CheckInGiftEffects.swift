import SwiftUI

// 月礼包、年度礼包开盒仪式额外用到的图形：礼盒周围闪烁的星光、扩散的光环、年度礼包的印章，以及彩纸里的星星。
// 和礼盒一个画风：主色加手绘线条，颜色都用随外观切换的动态色。

/// 五角星，填满给定区域；彩纸里的星星用它。
struct CheckInStarShape: Shape {
    func path(in rect: CGRect) -> Path {
        Self.points(in: rect, tips: 5, innerRatio: 0.45)
    }

    /// 以区域中心为圆心、尖角朝上的星形折线。
    ///
    /// - Parameters:
    ///   - rect: 星形所在的区域。
    ///   - tips: 尖角数量。
    ///   - innerRatio: 凹处到圆心的距离占外半径的比例，越小越尖。
    static func points(in rect: CGRect, tips: Int, innerRatio: CGFloat) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * innerRatio
        let count = max(2, tips) * 2
        for index in 0..<count {
            let angle = CGFloat(index) / CGFloat(count) * 2 * .pi - .pi / 2
            let radius = index.isMultiple(of: 2) ? outer : inner
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }
}

/// 礼盒周围一闪一闪的四角星光：月礼包、年度礼包没打开时就有，开盒后继续闪。
///
/// 每颗星的位置、大小和闪烁节奏由种子决定；`isAnimating` 为 false（如开启了减弱动态效果）时停在半亮。
struct CheckInSparkles: View {
    /// 这档礼包的主色。
    let tint: Color

    /// 星光的数量。
    let count: Int

    /// 是否闪烁。
    var isAnimating = true

    /// 一颗星光。
    private struct Sparkle {
        /// 位置，相对视图大小。
        let position: CGPoint
        /// 最亮时的半径。
        let radius: CGFloat
        /// 闪烁的角速度和初相。
        let rate: Double
        let phase: Double
        /// 是否用暖黄色；其余用主色。
        let isWarm: Bool
    }

    /// 全部星光，围着礼盒排成一圈，避开礼盒本身。
    private var sparkles: [Sparkle] {
        var jitter = HandDrawnJitter(seed: UInt64(count) &* 7_919)
        return (0..<count).map { index in
            let angle = (CGFloat(index) + jitter.next() * 0.35) / CGFloat(max(count, 1)) * 2 * .pi
            let reach = 0.4 + (jitter.next() + 1) * 0.05
            return Sparkle(
                position: CGPoint(x: 0.5 + cos(angle) * reach, y: 0.5 + sin(angle) * reach * 0.92),
                radius: 5 + (jitter.next() + 1) * 2.5,
                rate: 1.6 + Double(jitter.next() + 1) * 0.6,
                phase: Double(jitter.next() + 1) * .pi,
                isWarm: index % 3 == 1
            )
        }
    }

    var body: some View {
        let sparkles = self.sparkles
        TimelineView(.animation(paused: !isAnimating)) { context in
            Canvas { canvas, size in
                let time = context.date.timeIntervalSinceReferenceDate
                for sparkle in sparkles {
                    // 正弦的负半段视为熄灭，星光有亮有灭，不是一直在呼吸
                    let level = isAnimating ? max(0, sin(time * sparkle.rate + sparkle.phase)) : 0.6
                    guard level > 0.02 else { continue }
                    let radius = sparkle.radius * CGFloat(0.35 + 0.65 * level)
                    let center = CGPoint(x: size.width * sparkle.position.x, y: size.height * sparkle.position.y)
                    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                    var layer = canvas
                    layer.opacity = 0.25 + 0.75 * level
                    layer.fill(
                        CheckInStarShape.points(in: rect, tips: 4, innerRatio: 0.28),
                        with: .color(sparkle.isWarm ? .yellow : tint)
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 一圈手绘的光环：`trigger` 变化时从中心向外扩散并淡出，平时看不见。
///
/// 开盒时的冲击波、数字停下和盖章时的余波都用它。
struct CheckInRipple: View {
    /// 光环的颜色。
    let tint: Color

    /// 每次变化播放一遍。
    let trigger: Int

    /// 触发后等多久才开始扩散，用来让几圈光环错开。
    var delay: Double = 0

    /// 扩散到原始大小的几倍。
    var maxScale: CGFloat = 2.4

    /// 线宽。
    var lineWidth: CGFloat = 3

    /// 笔迹种子。
    var seed: UInt64 = 0

    /// 光环某一刻的大小和不透明度；初始值看不见，播完也回到看不见。
    private nonisolated struct Wave {
        var scale: CGFloat = 0.3
        var opacity: Double = 0
    }

    var body: some View {
        // 关键帧的时长不能为 0，不需要延迟时也留一点点
        let startDelay = max(self.delay, 0.001)
        let peakScale = self.maxScale
        HandDrawnBlob(seed: seed)
            .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .keyframeAnimator(initialValue: Wave(), trigger: trigger) { content, wave in
                content
                    .scaleEffect(wave.scale)
                    .opacity(wave.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    LinearKeyframe(0.3, duration: startDelay)
                    SpringKeyframe(peakScale, duration: 0.75, spring: .smooth)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(0, duration: startDelay)
                    LinearKeyframe(0.85, duration: 0.06)
                    LinearKeyframe(0, duration: 0.69)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// 年度礼包开完后盖上的印章：两道手绘圆圈里一顶皇冠和连签天数，略微歪着，像真的盖上去的。
///
/// 纯装饰，读屏跳过；天数已经写在标题下方。
struct CheckInSeal: View {
    @Environment(\.locale) private var locale

    /// 印泥的颜色。
    let tint: Color

    /// 连签天数。
    let streak: Int

    /// 印章边长。
    static let size: CGFloat = 78

    var body: some View {
        ZStack {
            HandDrawnBlob(seed: 365)
                .fill(tint.opacity(0.12))
            HandDrawnBlob(seed: 365)
                .stroke(tint, style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
            HandDrawnBlob(seed: 366)
                .stroke(tint.opacity(0.7), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                .padding(6)
            VStack(spacing: 0) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 17, weight: .semibold))
                Text(verbatim: streak.formatted(.number.locale(locale)))
                    .font(.system(size: 19, weight: .bold, design: .serif))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .foregroundStyle(tint)
            .padding(12)
        }
        .frame(width: Self.size, height: Self.size)
        .rotationEffect(.degrees(-14))
        .accessibilityHidden(true)
    }
}

#Preview {
    VStack(spacing: 32) {
        CheckInSparkles(tint: .orange, count: 12)
            .frame(width: 300, height: 260)
            .overlay(CheckInGiftBox(tier: .yearly, glow: 0.22).frame(width: 160))
        HStack(spacing: 24) {
            CheckInSeal(tint: .orange, streak: 365)
            CheckInStarShape().fill(.yellow).frame(width: 28, height: 28)
        }
    }
    .padding()
    .paperPage()
}
