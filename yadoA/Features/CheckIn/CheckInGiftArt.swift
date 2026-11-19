import SwiftUI

// 连续签到礼包的手绘图形：礼盒、背后的光芒和开盒时的彩纸。
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
struct CheckInGiftBox: View {
    /// 礼包档位，决定颜色和笔迹。
    let tier: AICheckInGiftTier

    /// 盒盖掀开的程度，0 为盖好，1 为完全飞起。
    var lidLift: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let seed = tier.artSeed
            let ink = Color.primary.opacity(0.72)
            let stroke = StrokeStyle(lineWidth: max(1.2, size / 110), lineCap: .round, lineJoin: .round)

            ZStack {
                // 盒口的光：盒盖掀开时从盒身上沿透出来
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
                    .opacity(Double(lidLift))

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

/// 开盒时从盒口向上喷出、再随重力落下的彩纸，大约 1.9 秒后淡出并停止刷新。
///
/// 每片彩纸的方向、速度、转速和颜色都由种子决定，重绘时不跳动。父视图换一个 `id` 即可重新播放。
struct CheckInConfetti: View {
    /// 这档礼包的主色，彩纸里会多用一些。
    let tint: Color

    /// 彩纸喷出的位置，相对视图大小，0 到 1。
    var origin = UnitPoint(x: 0.5, y: 0.5)

    /// 开始播放的时刻。
    @State private var start = Date()

    /// 是否还在播放；播完后停止逐帧刷新。
    @State private var isRunning = true

    /// 整段时长。
    private static let duration: Double = 1.9

    /// 重力加速度，pt/s²。
    private static let gravity: CGFloat = 820

    /// 一片彩纸。
    private struct Piece {
        let angle: CGFloat
        let speed: CGFloat
        let spin: CGFloat
        let width: CGFloat
        let height: CGFloat
        let colorIndex: Int
    }

    /// 全部彩纸，由固定种子生成。
    private static let pieces: [Piece] = {
        var jitter = HandDrawnJitter(seed: 20_261_118)
        return (0..<40).map { index in
            // 主要向上喷，左右各偏 70°
            let angle = -CGFloat.pi / 2 + jitter.next() * 1.22
            return Piece(
                angle: angle,
                speed: 300 + (jitter.next() + 1) * 130,
                spin: jitter.next() * 9,
                width: 6 + (jitter.next() + 1) * 2.5,
                height: 3.5 + (jitter.next() + 1) * 1.2,
                colorIndex: index
            )
        }
    }()

    var body: some View {
        let palette = [tint, tint, Color(.ledgerGreen), .orange, .pink, .yellow, .teal]
        TimelineView(.animation(paused: !isRunning)) { context in
            Canvas { canvas, size in
                let elapsed = CGFloat(context.date.timeIntervalSince(start))
                guard elapsed < Self.duration else { return }
                let fade = elapsed < 1.4 ? 1 : max(0, 1 - (elapsed - 1.4) / 0.5)
                let originPoint = CGPoint(x: size.width * origin.x, y: size.height * origin.y)
                for piece in Self.pieces {
                    let x = originPoint.x + cos(piece.angle) * piece.speed * elapsed
                    let y = originPoint.y + sin(piece.angle) * piece.speed * elapsed + 0.5 * Self.gravity * elapsed * elapsed
                    var layer = canvas
                    layer.opacity = Double(fade)
                    layer.translateBy(x: x, y: y)
                    layer.rotate(by: .radians(Double(piece.spin * elapsed)))
                    let rect = CGRect(x: -piece.width / 2, y: -piece.height / 2, width: piece.width, height: piece.height)
                    layer.fill(
                        Path(roundedRect: rect, cornerRadius: 1.2),
                        with: .color(palette[piece.colorIndex % palette.count])
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            try? await Task.sleep(for: .seconds(Self.duration))
            isRunning = false
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
        CheckInGiftBox(tier: .yearly, lidLift: 1).frame(width: 180)
    }
    .padding()
    .paperPage()
}
