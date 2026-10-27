import SwiftUI

/// 登录页中央的手绘插画：一笔墨线画出地面、破土的芽和两片叶子，芽尖顶着一颗账本红的豆子。
///
/// 呼应“芽豆”的名字。出现时墨线先一笔画完，豆子再弹出，闪光短线随后划出，最后在芽尖上轻轻浮动；
/// 浮动时两片叶子绕着与茎的连接点轻轻抬落，点一下豆子会弹跳一下、叶子跟着颤一下。触感由 `SproutHaptics` 按 `SproutTimeline` 对齐到每一笔，
/// 设备不支持 Core Haptics 时退回 `appHaptic`。墨线使用系统主文字色，随浅色、深色外观自动切换。
struct SproutIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 插画边长。
    var size: CGFloat = 220

    /// 墨线的书写进度。
    @State private var lineProgress: CGFloat = 0
    /// 豆子是否已弹出。
    @State private var isBeanVisible = false
    /// 豆子旁闪光短线的书写进度。
    @State private var sparkleProgress: CGFloat = 0
    /// 豆子是否处于浮起的一端，用于循环浮动。
    @State private var isFloating = false
    /// 叶子是否处于抬起的一端，比豆子稍晚开始，形成跟随的错落感。
    @State private var isLeafLifted = false
    /// 点按豆子的次数，驱动弹跳与震动。
    @State private var tapCount = 0
    /// 与笔画对齐的触感播放器。
    @State private var haptics = SproutHaptics()

    var body: some View {
        let scale = size / SproutGeometry.canvas
        let line = StrokeStyle(lineWidth: 4.8 * scale, lineCap: .round, lineJoin: .round)

        ZStack(alignment: .topLeading) {
            ForEach(SproutLinePart.allCases, id: \.self) { part in
                SproutStrokePart(part: part, progress: lineProgress)
                    .stroke(Color.primary, style: line)
                    .rotationEffect(
                        .degrees(isLeafLifted ? part.liftDirection * SproutMotion.leafSwayDegrees : 0),
                        anchor: part.anchor
                    )
                    // 点按豆子时叶子先向上一甩，再回弹两下落定
                    .keyframeAnimator(initialValue: 0.0, trigger: tapCount) { content, wobble in
                        content.rotationEffect(
                            .degrees(reduceMotion ? 0 : wobble * part.liftDirection),
                            anchor: part.anchor
                        )
                    } keyframes: { _ in
                        SpringKeyframe(SproutMotion.leafWobbleDegrees, duration: 0.12)
                        SpringKeyframe(-SproutMotion.leafWobbleDegrees * 0.4, duration: 0.18)
                        SpringKeyframe(0, duration: 0.5, spring: .bouncy)
                    }
            }

            SproutSparkleShape()
                .trim(from: 0, to: sparkleProgress)
                .stroke(Color.primary.opacity(0.5), style: StrokeStyle(lineWidth: 2.8 * scale, lineCap: .round))

            Circle()
                .fill(Color(.ledgerRed))
                .frame(width: SproutGeometry.beanRadius * 2 * scale, height: SproutGeometry.beanRadius * 2 * scale)
                .keyframeAnimator(initialValue: CGFloat(1), trigger: tapCount) { content, bounce in
                    content.scaleEffect(bounce)
                } keyframes: { _ in
                    SpringKeyframe(1.22, duration: 0.14)
                    SpringKeyframe(1, duration: 0.5, spring: .bouncy)
                }
                .scaleEffect(isBeanVisible ? 1 : 0.01)
                .offset(y: isFloating ? -3 * scale : 0)
                .position(x: SproutGeometry.beanCenter.x * scale, y: SproutGeometry.beanCenter.y * scale)
                .onTapGesture {
                    tapCount += 1
                    haptics.playTap()
                }
        }
        .frame(width: size, height: size)
        // 只在 Core Haptics 不可用时兜底，避免与精细触感叠在一起
        .appHaptic(.landing, trigger: isBeanVisible) { _, visible in
            visible && !haptics.isAvailable
        }
        .appHaptic(.tap, trigger: tapCount) { _, _ in
            !haptics.isAvailable
        }
        .accessibilityHidden(true)
        .onAppear {
            haptics.start()
            play()
        }
        .onDisappear {
            haptics.stop()
        }
    }

    /// 墨线书写 → 豆子弹出 → 闪光短线 → 循环浮动与叶子摆动；开启“减弱动态效果”时直接显示最终画面，不浮动、不摆动。
    private func play() {
        guard lineProgress == 0 else { return }
        if reduceMotion {
            lineProgress = 1
            isBeanVisible = true
            sparkleProgress = 1
            haptics.playBeanAppearance()
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(SproutTimeline.lineDelay))
            // 之后每一步都按墨线落笔这一刻的绝对时间等待，避免多次相对等待累积误差
            let clock = ContinuousClock()
            let origin = clock.now
            /// 等到相对墨线落笔的某一时刻。
            func wait(until offset: Double) async {
                try? await clock.sleep(until: origin + .seconds(offset), tolerance: .milliseconds(1))
            }

            // 触感与对应动画在同一刻启动
            haptics.playLine()
            withAnimation(.easeInOut(duration: SproutTimeline.lineDuration)) {
                lineProgress = 1
            }
            await wait(until: SproutTimeline.beanStart)
            haptics.playBean()
            withAnimation(.spring(SproutTimeline.beanSpring)) {
                isBeanVisible = true
            }
            await wait(until: SproutTimeline.sparkleStart)
            withAnimation(.easeOut(duration: SproutTimeline.sparkleDuration)) {
                sparkleProgress = 1
            }
            await wait(until: SproutTimeline.floatStart)
            withAnimation(.easeInOut(duration: SproutMotion.floatPeriod).repeatForever(autoreverses: true)) {
                isFloating = true
            }
            await wait(until: SproutTimeline.floatStart + SproutMotion.leafLag)
            withAnimation(.easeInOut(duration: SproutMotion.floatPeriod).repeatForever(autoreverses: true)) {
                isLeafLifted = true
            }
        }
    }
}

/// 插画入场后的循环动作与点按反馈的幅度。
private enum SproutMotion {
    /// 豆子单程浮动与叶子单程摆动的时长。
    static let floatPeriod: Double = 2.2
    /// 叶子比豆子晚开始摆动的时间，让叶子像被豆子带动。
    static let leafLag: Double = 0.25
    /// 叶子随浮动抬起的角度。
    static let leafSwayDegrees: Double = 4
    /// 点按豆子时叶子上甩的角度。
    static let leafWobbleDegrees: Double = 7
}

/// 插画入场动画的时间轴，动画与触感共用，保证每一下震动都落在对应的笔画上。
///
/// 除 `lineDelay` 外，时间都以墨线开始书写为 0 点，单位为秒。
enum SproutTimeline {
    /// 插画出现到墨线开始书写的等待。
    static let lineDelay: Double = 0.15
    /// 墨线书写时长，曲线为 `easeInOut`。
    static let lineDuration: Double = 1.5
    /// 豆子开始弹出的时刻，略早于墨线写完，让两段动作衔接。
    static let beanStart: Double = 1.35
    /// 豆子从无到有的弹簧，回弹明显，像从芽尖上蹦出来。
    static let beanSpring = Spring(duration: 0.5, bounce: 0.55)
    /// 豆子第一次放大到原大小的时刻，相对弹出开始；触感的“落定”放在这里。
    static let beanLandingOffset: Double = springCrossing(rising: true, after: 0)
    /// 豆子冲过头后第一次回落到原大小的时刻，相对弹出开始；触感的余震放在这里。
    static let beanReboundOffset: Double = springCrossing(rising: false, after: beanLandingOffset)
    /// 闪光短线开始划出的时刻。
    static let sparkleStart: Double = 1.57
    /// 闪光短线划出时长，曲线为 `easeOut`。
    static let sparkleDuration: Double = 0.35
    /// 豆子开始循环浮动的时刻。
    static let floatStart: Double = 1.97

    /// 墨线每一笔落笔的时刻：按各笔长度在全长上的比例，反推 `easeInOut` 曲线上的时间。
    static let strokeStartTimes: [Double] = SproutGeometry
        .strokeStartFractions(of: SproutLinePart.fullPath)
        .map { lineDuration * UnitCurve.easeInOut.inverse.value(at: $0) }

    /// 沿 `beanSpring` 的位移曲线按毫秒采样，找出越过终点的时刻。
    ///
    /// - Parameters:
    ///   - rising: true 找从下往上越过终点，false 找从上往下回落到终点。
    ///   - start: 从这一时刻之后开始找。
    /// - Returns: 越过终点的时刻；弹簧在 1 秒内没有越过时返回 `start`。
    private static func springCrossing(rising: Bool, after start: Double) -> Double {
        let step = 0.001
        var time = start + step
        while time < 1 {
            let value = beanSpring.value(target: 1.0, time: time)
            if rising ? value >= 1 : value <= 1 {
                return time
            }
            time += step
        }
        return start
    }

    /// 三道闪光短线各自划出的时刻。
    static let sparkleStrokeTimes: [Double] = SproutGeometry
        .strokeStartFractions(of: SproutSparkleShape().path(in: SproutGeometry.canvasRect))
        .map { sparkleStart + sparkleDuration * UnitCurve.easeOut.inverse.value(at: $0) }
}

/// 芽豆插画在 240×240 设计画布上的几何定义。
enum SproutGeometry {
    /// 设计画布边长。
    static let canvas: CGFloat = 240

    /// 豆子的圆心。
    static let beanCenter = CGPoint(x: 112, y: 62)

    /// 豆子的半径。
    static let beanRadius: CGFloat = 22

    /// 设计画布本身，按原尺寸取路径时使用。
    static let canvasRect = CGRect(x: 0, y: 0, width: canvas, height: canvas)

    /// 计算路径中每一笔（每个 `move` 开始的子路径）起点在总长度上的比例。
    ///
    /// 曲线按折线近似求长度，精度足够用来对齐触感。
    /// - Parameter path: 由若干笔组成的路径。
    /// - Returns: 各笔起点的比例，从 0 开始递增；路径为空时返回空数组。
    static func strokeStartFractions(of path: Path) -> [Double] {
        let lengths = strokeLengths(of: path)
        let total = lengths.reduce(0, +)
        guard total > 0 else { return [] }
        var fractions: [Double] = []
        var walked: Double = 0
        for length in lengths {
            fractions.append(walked / total)
            walked += length
        }
        return fractions
    }

    /// 计算路径中每一笔的长度，曲线按折线近似。
    ///
    /// - Parameter path: 由若干笔组成的路径。
    /// - Returns: 各笔长度，顺序与书写顺序一致。
    static func strokeLengths(of path: Path) -> [Double] {
        var lengths: [Double] = []
        var current = CGPoint.zero

        /// 沿参数曲线采样，把折线长度累加到当前这一笔上。
        func addSampled(steps: Int = 24, _ point: (CGFloat) -> CGPoint) {
            if lengths.isEmpty { lengths.append(0) }
            var previous = current
            for step in 1...steps {
                let next = point(CGFloat(step) / CGFloat(steps))
                lengths[lengths.count - 1] += hypot(next.x - previous.x, next.y - previous.y)
                previous = next
            }
            current = previous
        }

        path.forEach { element in
            switch element {
            case let .move(to):
                lengths.append(0)
                current = to
            case let .line(to):
                addSampled(steps: 1) { _ in to }
            case let .quadCurve(to, control):
                let start = current
                addSampled { t in
                    let u = 1 - t
                    return CGPoint(
                        x: u * u * start.x + 2 * u * t * control.x + t * t * to.x,
                        y: u * u * start.y + 2 * u * t * control.y + t * t * to.y
                    )
                }
            case let .curve(to, control1, control2):
                let start = current
                addSampled { t in
                    let u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                    return CGPoint(
                        x: a * start.x + b * control1.x + c * control2.x + d * to.x,
                        y: a * start.y + b * control1.y + c * control2.y + d * to.y
                    )
                }
            case .closeSubpath:
                break
            }
        }
        return lengths
    }

    /// 把设计画布上的路径等比缩放到目标区域。
    static func fit(_ path: Path, in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / canvas
        return path.applying(
            CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale)
        )
    }
}

/// 插画的墨线，按书写顺序拆成三部分：叶子要绕着与茎的连接点摆动，必须和地面、茎分开绘制。
enum SproutLinePart: CaseIterable {
    /// 地面、根须和茎，固定不动。
    case base
    /// 左叶及叶脉。
    case leftLeaf
    /// 右叶。
    case rightLeaf

    /// 设计画布上的路径。
    var path: Path {
        var path = Path()
        switch self {
        case .base:
            path.addPath(Self.groundPath)
            path.addPath(Self.rootsPath)
            path.addPath(Self.stemPath)
        case .leftLeaf:
            // 左叶：从茎上绕出一片，再回到茎上。
            path.move(to: Self.leftLeafBase)
            path.addCurve(to: CGPoint(x: 50, y: 140), control1: CGPoint(x: 92, y: 126), control2: CGPoint(x: 60, y: 124))
            path.addCurve(to: Self.leftLeafBase, control1: CGPoint(x: 66, y: 158), control2: CGPoint(x: 98, y: 162))
            // 左叶的叶脉。
            path.move(to: CGPoint(x: 62, y: 141))
            path.addQuadCurve(to: CGPoint(x: 104, y: 147), control: CGPoint(x: 84, y: 140))
        case .rightLeaf:
            path.move(to: Self.rightLeafBase)
            path.addCurve(to: CGPoint(x: 188, y: 108), control1: CGPoint(x: 138, y: 102), control2: CGPoint(x: 174, y: 96))
            path.addCurve(to: Self.rightLeafBase, control1: CGPoint(x: 176, y: 130), control2: CGPoint(x: 142, y: 140))
        }
        return path
    }

    /// 摆动的旋转中心：叶子与茎的连接点，换算为相对插画边长的比例；茎不转动，取中心即可。
    var anchor: UnitPoint {
        switch self {
        case .base: .center
        case .leftLeaf: UnitPoint(x: Self.leftLeafBase.x / SproutGeometry.canvas, y: Self.leftLeafBase.y / SproutGeometry.canvas)
        case .rightLeaf: UnitPoint(x: Self.rightLeafBase.x / SproutGeometry.canvas, y: Self.rightLeafBase.y / SproutGeometry.canvas)
        }
    }

    /// 叶尖向上抬起时的旋转方向：左叶顺时针、右叶逆时针；茎为 0，不参与摆动。
    var liftDirection: Double {
        switch self {
        case .base: 0
        case .leftLeaf: 1
        case .rightLeaf: -1
        }
    }

    /// 在整条墨线书写进度中所占的区间，按各部分长度划分。
    var drawRange: ClosedRange<Double> {
        Self.drawRanges[self] ?? 0...1
    }

    /// 三部分按书写顺序拼起来的完整墨线，用于计算落笔时刻。
    static var fullPath: Path {
        var path = Path()
        for part in allCases {
            path.addPath(part.path)
        }
        return path
    }

    /// 地面：一条略有起伏的横线。
    static var groundPath: Path {
        var path = Path()
        path.move(to: CGPoint(x: 42, y: 199))
        path.addCurve(to: CGPoint(x: 118, y: 196), control1: CGPoint(x: 70, y: 191), control2: CGPoint(x: 94, y: 203))
        path.addCurve(to: CGPoint(x: 192, y: 197), control1: CGPoint(x: 144, y: 189), control2: CGPoint(x: 170, y: 203))
        return path
    }

    /// 根须：从茎底向下分出两笔。
    static var rootsPath: Path {
        var path = Path()
        path.move(to: CGPoint(x: 117, y: 198))
        path.addCurve(to: CGPoint(x: 101, y: 217), control1: CGPoint(x: 115, y: 207), control2: CGPoint(x: 109, y: 213))
        path.move(to: CGPoint(x: 120, y: 198))
        path.addCurve(to: CGPoint(x: 138, y: 214), control1: CGPoint(x: 124, y: 206), control2: CGPoint(x: 131, y: 211))
        return path
    }

    /// 茎：自地面向上，微微摆动，止于豆子底部。
    static var stemPath: Path {
        var path = Path()
        path.move(to: stemBase)
        path.addCurve(to: CGPoint(x: 116, y: 120), control1: CGPoint(x: 104, y: 170), control2: CGPoint(x: 128, y: 142))
        path.addCurve(to: CGPoint(x: 113, y: 85), control1: CGPoint(x: 108, y: 106), control2: CGPoint(x: 111, y: 93))
        return path
    }

    /// 茎从地面长出的那一点。
    static let stemBase = CGPoint(x: 118, y: 196)

    /// 左叶与茎的连接点。
    private static let leftLeafBase = CGPoint(x: 114, y: 150)
    /// 右叶与茎的连接点。
    private static let rightLeafBase = CGPoint(x: 118, y: 128)

    /// 各部分的书写区间，只算一次。
    private static let drawRanges: [SproutLinePart: ClosedRange<Double>] = {
        let lengths = allCases.map { SproutGeometry.strokeLengths(of: $0.path).reduce(0, +) }
        let total = lengths.reduce(0, +)
        var ranges: [SproutLinePart: ClosedRange<Double>] = [:]
        var walked: Double = 0
        for (part, length) in zip(allCases, lengths) {
            ranges[part] = (walked / total)...((walked + length) / total)
            walked += length
        }
        return ranges
    }()
}

/// 墨线的一部分：按整条墨线的书写进度，只画出属于自己的那一段，三部分接起来就是一笔写完。
struct SproutStrokePart: Shape {
    /// 画哪一部分。
    let part: SproutLinePart
    /// 整条墨线的书写进度，0 为未落笔，1 为写完。
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let range = part.drawRange
        let local = (Double(progress) - range.lowerBound) / (range.upperBound - range.lowerBound)
        guard local > 0 else { return Path() }
        return SproutGeometry.fit(part.path, in: rect).trimmedPath(from: 0, to: min(local, 1))
    }
}

/// 豆子左上方的三道闪光短线，像刚冒出来时闪了一下。
struct SproutSparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let center = SproutGeometry.beanCenter
        var path = Path()
        for degrees in [-155.0, -100.0, -42.0] {
            let angle = degrees * .pi / 180
            let direction = CGPoint(x: cos(angle), y: sin(angle))
            path.move(to: CGPoint(x: center.x + direction.x * 31, y: center.y + direction.y * 31))
            path.addLine(to: CGPoint(x: center.x + direction.x * 40, y: center.y + direction.y * 40))
        }
        return SproutGeometry.fit(path, in: rect)
    }
}

#Preview {
    SproutIllustration()
        .padding(40)
        .paperPage()
}
