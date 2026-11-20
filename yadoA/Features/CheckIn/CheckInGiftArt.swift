import SwiftUI

// 连续签到礼包的手绘图形：礼盒、背后的光芒和开盒时的彩纸；月礼包、年度礼包另有的星光、光环和印章见 `CheckInGiftEffects.swift`。
// 礼盒用纸色上的淡色块加墨线描边，与“我的”页的签到气泡一个画风；颜色都用系统语义色或资源里的动态色，浅色和深色外观都能看清。

extension AICheckInGiftTier {
    /// 礼包的主色：周礼包账本绿、月礼包靛蓝、年度礼包橙色；都是随外观切换的动态色。
    var tint: Color {
        switch self {
        case .weekly: Color(.ledgerGreen)
        case .monthly: .indigo
        case .yearly: .orange
        case .unknown: .accentColor
        }
    }

    /// 礼盒笔迹的种子，同一档礼包每次画成同一个样子。
    var artSeed: UInt64 {
        rawValue.handDrawnSeed
    }
}

/// 一个手绘礼盒：盒身、盒盖和蝴蝶结。
///
/// `lidLift` 从 0 到 1 时盒盖连同蝴蝶结向上飞起并歪向一边，盒口透出一圈主色的光；为 0 时盒盖盖好。
/// `glow` 大于 0 时盒盖没开，光已经从盒缝漏出来：一圈光晕、一道亮线，`beamCount` 大于 0 时还有几道光束向上射出。
struct CheckInGiftBox: View {
    /// 礼包档位，决定颜色和笔迹。
    let tier: AICheckInGiftTier

    /// 盒盖掀开的程度，0 为盖好，1 为完全飞起。
    var lidLift: CGFloat = 0

    /// 盒缝透出的光，0 为不透光，1 为最亮；开盖前蓄力时由暗到亮。
    var glow: CGFloat = 0

    /// 从盒缝向上射出的光束条数；0 为没有光束。
    var beamCount = 0

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let seed = tier.artSeed
            let ink = Color.primary.opacity(0.72)
            let stroke = StrokeStyle(lineWidth: max(1.2, size / 110), lineCap: .round, lineJoin: .round)
            // 盒盖与盒身之间那条缝的高度
            let seamY = size * 0.565

            ZStack {
                // 盒缝射出的光束：画在盒子后面，从盒盖两侧和上方露出来
                if beamCount > 0 {
                    GiftBeamsShape(count: beamCount)
                        .fill(
                            LinearGradient(
                                colors: [tier.tint.opacity(0.5), tier.tint.opacity(0)],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: size * 1.3, height: size * 0.62)
                        .position(x: size / 2, y: seamY - size * 0.31)
                        .opacity(Double(min(1, glow * 1.3)) * Double(1 - lidLift))
                }

                // 盒口的光：盒盖掀开时从盒身上沿透出来；蓄力时盒盖没开，光从盒子四周漏出
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [tier.tint.opacity(0.55), tier.tint.opacity(0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: size * 0.4
                        )
                    )
                    .frame(width: size * 0.9, height: size * 0.5)
                    .position(x: size / 2, y: size * 0.52)
                    .scaleEffect(1 + 0.25 * glow)
                    .opacity(Double(max(lidLift, glow * 0.9)))

                // 盒身
                ZStack {
                    HandDrawnBox(cornerRadius: size * 0.05, seed: seed)
                        .fill(tier.tint.opacity(0.26))
                    Rectangle()
                        .fill(tier.tint)
                        .frame(width: size * 0.12)
                    HandDrawnBox(cornerRadius: size * 0.05, seed: seed)
                        .stroke(ink, style: stroke)
                }
                .frame(width: size * 0.7, height: size * 0.44)
                .position(x: size / 2, y: size * 0.78)

                // 盒缝里的亮线：盒盖压住上半，只从缝里露出来
                Capsule()
                    .fill(tier.tint)
                    .frame(width: size * 0.74, height: max(2, size * 0.022))
                    .blur(radius: size * 0.012)
                    .position(x: size / 2, y: seamY)
                    .opacity(Double(glow) * Double(1 - lidLift))

                // 盒盖与蝴蝶结：一起飞起
                ZStack {
                    GiftBowShape()
                        .fill(tier.tint)
                        .overlay(GiftBowShape().stroke(ink, style: stroke))
                        .frame(width: size * 0.38, height: size * 0.2)
                        .offset(y: -size * 0.17)
                    ZStack {
                        HandDrawnBox(cornerRadius: size * 0.04, seed: seed &+ 1)
                            .fill(tier.tint.opacity(0.42))
                        Rectangle()
                            .fill(tier.tint)
                            .frame(width: size * 0.13)
                        HandDrawnBox(cornerRadius: size * 0.04, seed: seed &+ 1)
                            .stroke(ink, style: stroke)
                    }
                    .frame(width: size * 0.8, height: size * 0.15)
                }
                .position(x: size / 2, y: size * 0.5)
                .rotationEffect(.degrees(-22 * Double(lidLift)), anchor: .center)
                .offset(x: -size * 0.1 * lidLift, y: -size * 0.42 * lidLift)
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// 从底边中点向上呈扇形散开的几道光束，左右对称，越往外越斜。
private struct GiftBeamsShape: Shape {
    /// 光束条数。
    var count: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard count > 0 else { return path }
        let origin = CGPoint(x: rect.midX, y: rect.maxY)
        // 光束分布在竖直方向左右各 62° 以内
        let maxTilt: CGFloat = 62 * .pi / 180
        let halfWidth: CGFloat = 0.07
        for index in 0..<count {
            let fraction: CGFloat = count == 1 ? 0.5 : CGFloat(index) / CGFloat(count - 1)
            let tilt = (fraction * 2 - 1) * maxTilt
            // 中间的光束更长，两侧的短一点，避免伸出画面
            let reach = rect.height * (1 - 0.25 * abs(fraction * 2 - 1))
            let left = tilt - halfWidth
            let right = tilt + halfWidth
            path.move(to: origin)
            path.addLine(to: CGPoint(x: origin.x + sin(left) * reach, y: origin.y - cos(left) * reach))
            path.addLine(to: CGPoint(x: origin.x + sin(right) * reach, y: origin.y - cos(right) * reach))
            path.closeSubpath()
        }
        return path
    }
}

/// 蝴蝶结：左右两个水滴形的环，中间一个小结。
private struct GiftBowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let knot = CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.18)
        // 左环
        path.move(to: knot)
        path.addCurve(
            to: knot,
            control1: CGPoint(x: rect.minX - rect.width * 0.05, y: rect.minY - rect.height * 0.1),
            control2: CGPoint(x: rect.minX, y: rect.maxY + rect.height * 0.05)
        )
        // 右环，略比左环高一点，像随手系的
        path.move(to: knot)
        path.addCurve(
            to: knot,
            control1: CGPoint(x: rect.maxX + rect.width * 0.05, y: rect.minY - rect.height * 0.18),
            control2: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        // 中间的结
        let radius = rect.width * 0.08
        path.addEllipse(in: CGRect(x: knot.x - radius, y: knot.y - radius * 0.85, width: radius * 2, height: radius * 1.7))
        return path
    }
}

/// 礼盒背后的放射状光芒：一圈相间的楔形，填充后旋转起来像在发光。
struct CheckInSunburst: Shape {
    /// 光芒的条数。
    var rayCount = 14

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let step = 2 * CGFloat.pi / CGFloat(rayCount)
        for index in 0..<rayCount {
            let start = CGFloat(index) * step
            path.move(to: center)
            path.addArc(
                center: center,
                radius: radius,
                startAngle: .radians(Double(start)),
                endAngle: .radians(Double(start + step * 0.45)),
                clockwise: false
            )
            path.closeSubpath()
        }
        return path
    }
}

/// 开盒时喷出的彩纸：一路或几路，每路按 `CheckInConfettiEmitter` 的设定从某处喷出，受重力和空气阻力落下，
/// 最后一片消失后停止刷新。
///
/// 每片彩纸的方向、速度、转速、大小和颜色都由种子决定，重绘时不跳动。父视图换一个 `id` 即可重新播放。
struct CheckInConfetti: View {
    /// 这档礼包的主色，彩纸里会多用一些。
    let tint: Color

    /// 全部碎片，创建时按各路的设定生成。
    private let pieces: [Piece]

    /// 从开始到最后一片消失的时长。
    private let duration: Double

    /// 开始播放的时刻。
    @State private var start = Date()

    /// 是否还在播放；播完后停止逐帧刷新。
    @State private var isRunning = true

    /// 每片在最后多少秒内淡出。
    private static let fadeDuration = 0.5

    /// 一片彩纸。
    private struct Piece {
        /// 喷出点，相对视图大小。
        let origin: CGPoint
        /// 初速度，pt/s。
        let velocity: CGVector
        /// 喷出前等待的秒数。
        let delay: Double
        /// 喷出后存在的秒数。
        let lifetime: Double
        /// 重力加速度。
        let gravity: CGFloat
        /// 空气阻力系数。
        let drag: CGFloat
        /// 左右飘摆的幅度和角速度、初相。
        let sway: CGFloat
        let swayRate: CGFloat
        let swayPhase: CGFloat
        /// 自转角速度，弧度每秒。
        let spin: CGFloat
        /// 翻面的角速度；0 为不翻面。
        let flip: CGFloat
        /// 外形和大小。
        let kind: CheckInConfettiEmitter.Kind
        let width: CGFloat
        let height: CGFloat
        let color: Color
    }

    /// 创建彩纸。
    ///
    /// - Parameters:
    ///   - tint: 这档礼包的主色。
    ///   - emitters: 各路彩纸的喷法。
    init(tint: Color, emitters: [CheckInConfettiEmitter]) {
        self.tint = tint
        pieces = emitters.flatMap { Self.pieces(for: $0, tint: tint) }
        duration = emitters.map(\.totalDuration).max() ?? 0
    }

    var body: some View {
        TimelineView(.animation(paused: !isRunning)) { context in
            Canvas { canvas, size in
                let elapsed = context.date.timeIntervalSince(start)
                guard elapsed < duration else { return }
                for piece in pieces {
                    draw(piece, elapsed: elapsed, in: canvas, size: size)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            try? await Task.sleep(for: .seconds(duration))
            isRunning = false
        }
    }

    /// 画出一片彩纸此刻的样子；还没喷出或已经消失时不画。
    ///
    /// - Parameters:
    ///   - piece: 要画的碎片。
    ///   - elapsed: 从开始播放起算的秒数。
    ///   - canvas: 画布；复制一份再变换，不影响其他碎片。
    ///   - size: 画布大小。
    private func draw(_ piece: Piece, elapsed: Double, in canvas: GraphicsContext, size: CGSize) {
        let local = elapsed - piece.delay
        guard local >= 0, local < piece.lifetime else { return }
        let time = CGFloat(local)
        let fadeStart = piece.lifetime - Self.fadeDuration
        let alpha: Double = local < fadeStart ? 1 : max(0, (piece.lifetime - local) / Self.fadeDuration)

        // 有阻力时速度按指数衰减，最终以 gravity / drag 的速度匀速下落；没有阻力时是抛物线
        var x = size.width * piece.origin.x
        var y = size.height * piece.origin.y
        if piece.drag > 0.001 {
            let travel = (1 - exp(-piece.drag * time)) / piece.drag
            let terminal = piece.gravity / piece.drag
            x += piece.velocity.dx * travel
            y += terminal * time + (piece.velocity.dy - terminal) * travel
        } else {
            x += piece.velocity.dx * time
            y += piece.velocity.dy * time + 0.5 * piece.gravity * time * time
        }
        if piece.sway > 0 {
            // 刚喷出时不飘，慢慢摆起来
            x += piece.sway * min(1, time / 0.6) * sin(piece.swayRate * time + piece.swayPhase)
        }

        var layer = canvas
        layer.opacity = alpha
        layer.translateBy(x: x, y: y)
        layer.rotate(by: .radians(Double(piece.spin * time)))
        if piece.flip > 0 {
            layer.scaleBy(x: 1, y: max(0.15, abs(cos(piece.flip * time))))
        }
        let rect = CGRect(x: -piece.width / 2, y: -piece.height / 2, width: piece.width, height: piece.height)
        let path: Path = switch piece.kind {
        case .strip: Path(roundedRect: rect, cornerRadius: 1.2)
        case .dot: Path(ellipseIn: rect)
        case .star: CheckInStarShape().path(in: rect)
        }
        layer.fill(path, with: .color(piece.color))
    }

    /// 按一路的设定生成碎片。
    ///
    /// - Parameters:
    ///   - emitter: 这一路的喷法。
    ///   - tint: 这档礼包的主色。
    private static func pieces(for emitter: CheckInConfettiEmitter, tint: Color) -> [Piece] {
        let palette: [Color] = switch emitter.palette {
        case .festive: [tint, tint, Color(.ledgerGreen), .orange, .pink, .yellow, .teal]
        case .golden: [tint, .yellow, .orange, tint, .yellow]
        }
        var jitter = HandDrawnJitter(seed: emitter.seed)
        /// 取 0...1 之间的随机数。
        func unit() -> CGFloat { (jitter.next() + 1) / 2 }

        return (0..<max(0, emitter.count)).map { index in
            let angle = CGFloat(emitter.direction) + jitter.next() * CGFloat(emitter.spread)
            let speed = CGFloat(emitter.speed.lowerBound) + unit() * CGFloat(emitter.speed.upperBound - emitter.speed.lowerBound)
            let delay = emitter.delay.lowerBound + Double(unit()) * (emitter.delay.upperBound - emitter.delay.lowerBound)
            let originX = emitter.origin.x + jitter.next() * emitter.originWidth / 2
            let spin = jitter.next() * 9 * (emitter.kind == .star ? 0.4 : 1)
            // 长条是长方形，圆点和星星宽高相同
            let pieceSize: CGSize
            switch emitter.kind {
            case .strip:
                pieceSize = CGSize(width: 6 + unit() * 5, height: 3.5 + unit() * 2.4)
            case .dot:
                let side = 4 + unit() * 3
                pieceSize = CGSize(width: side, height: side)
            case .star:
                let side = 8 + unit() * 7
                pieceSize = CGSize(width: side, height: side)
            }
            return Piece(
                origin: CGPoint(x: originX, y: emitter.origin.y),
                velocity: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed),
                delay: delay,
                // 每片的寿命略有长短，免得一齐消失
                lifetime: emitter.lifetime * (0.85 + 0.15 * Double(unit())),
                gravity: CGFloat(emitter.gravity),
                drag: CGFloat(emitter.drag),
                sway: CGFloat(emitter.sway) * (0.5 + unit() * 0.5),
                swayRate: 3 + unit() * 2.5,
                swayPhase: unit() * 2 * .pi,
                spin: spin,
                flip: emitter.flutter ? 4 + unit() * 6 : 0,
                kind: emitter.kind,
                width: pieceSize.width,
                height: pieceSize.height,
                color: palette[index % palette.count]
            )
        }
    }
}

#Preview {
    VStack(spacing: 24) {
        HStack(spacing: 24) {
            CheckInGiftBox(tier: .weekly).frame(width: 90)
            CheckInGiftBox(tier: .monthly).frame(width: 90)
            CheckInGiftBox(tier: .yearly).frame(width: 90)
        }
        HStack(spacing: 24) {
            CheckInGiftBox(tier: .monthly, glow: 0.75, beamCount: 3).frame(width: 140)
            CheckInGiftBox(tier: .yearly, lidLift: 1).frame(width: 140)
        }
        CheckInGiftBox(tier: .yearly, glow: 1, beamCount: 5).frame(width: 180)
    }
    .padding()
    .paperPage()
}
