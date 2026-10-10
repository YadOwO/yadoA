import SwiftUI

/// 应用图标上那一笔手绘对勾的几何定义，供轮廓与书写动画共用。
private enum HandDrawnTickGeometry {
    /// 一段带粗细变化的三次贝塞尔笔画。
    struct Stroke {
        /// 起点、两个控制点和终点，沿用图标 1024 画布上的坐标。
        let points: [CGPoint]

        /// 沿笔画均匀分布的笔宽，模拟落笔轻重。
        let widths: [CGFloat]
    }

    /// 先短促下顿、再向右上提笔的两段笔画，与 `AppIcon.icon` 的对勾图层保持一致。
    static let strokes = [
        Stroke(
            points: [
                CGPoint(x: 372, y: 588), CGPoint(x: 404, y: 622),
                CGPoint(x: 432, y: 658), CGPoint(x: 458, y: 696)
            ],
            widths: [57, 68, 77]
        ),
        Stroke(
            points: [
                CGPoint(x: 458, y: 696), CGPoint(x: 540, y: 628),
                CGPoint(x: 630, y: 572), CGPoint(x: 729, y: 526)
            ],
            widths: [77, 70, 62, 48]
        )
    ]

    /// 包含笔宽在内的对勾外接范围。
    static let designBounds = CGRect(x: 338, y: 496, width: 422, height: 244)

    /// 书写动画使用的揭示笔宽，需略大于最粗处才能完整露出轮廓。
    static let revealWidth: CGFloat = 112

    /// 把图标坐标等比缩放并居中到目标区域。
    static func transform(in rect: CGRect) -> CGAffineTransform {
        let scale = min(rect.width / designBounds.width, rect.height / designBounds.height)
        return CGAffineTransform(
            translationX: rect.midX - designBounds.midX * scale,
            y: rect.midY - designBounds.midY * scale
        )
        .scaledBy(x: scale, y: scale)
    }

    /// 三次贝塞尔曲线在 `t` 处的位置。
    static func position(_ points: [CGPoint], at t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u
        let b = 3 * u * u * t
        let c = 3 * u * t * t
        let d = t * t * t
        return CGPoint(
            x: a * points[0].x + b * points[1].x + c * points[2].x + d * points[3].x,
            y: a * points[0].y + b * points[1].y + c * points[2].y + d * points[3].y
        )
    }

    /// 三次贝塞尔曲线在 `t` 处的单位法线。
    static func normal(_ points: [CGPoint], at t: CGFloat) -> CGVector {
        let u = 1 - t
        let dx = 3 * u * u * (points[1].x - points[0].x)
            + 6 * u * t * (points[2].x - points[1].x)
            + 3 * t * t * (points[3].x - points[2].x)
        let dy = 3 * u * u * (points[1].y - points[0].y)
            + 6 * u * t * (points[2].y - points[1].y)
            + 3 * t * t * (points[3].y - points[2].y)
        let length = max(hypot(dx, dy), .leastNonzeroMagnitude)
        return CGVector(dx: -dy / length, dy: dx / length)
    }

    /// 在相邻笔宽之间线性插值。
    static func width(_ widths: [CGFloat], at t: CGFloat) -> CGFloat {
        let scaled = t * CGFloat(widths.count - 1)
        let index = min(Int(scaled), widths.count - 2)
        let fraction = scaled - CGFloat(index)
        return widths[index] + (widths[index + 1] - widths[index]) * fraction
    }
}

/// 粗细有变化的手绘对勾轮廓，用于填充。
struct HandDrawnTickShape: Shape {
    /// 每段笔画的采样数，足够让小尺寸下的边缘保持平滑。
    private let sampleCount = 24

    func path(in rect: CGRect) -> Path {
        var outline = Path()
        for stroke in HandDrawnTickGeometry.strokes {
            var left: [CGPoint] = []
            var right: [CGPoint] = []
            for step in 0...sampleCount {
                let t = CGFloat(step) / CGFloat(sampleCount)
                let center = HandDrawnTickGeometry.position(stroke.points, at: t)
                let normal = HandDrawnTickGeometry.normal(stroke.points, at: t)
                let halfWidth = HandDrawnTickGeometry.width(stroke.widths, at: t) / 2
                left.append(CGPoint(x: center.x + normal.dx * halfWidth, y: center.y + normal.dy * halfWidth))
                right.append(CGPoint(x: center.x - normal.dx * halfWidth, y: center.y - normal.dy * halfWidth))
            }

            var body = Path()
            body.addLines(left + right.reversed())
            body.closeSubpath()
            outline = outline.union(body)

            // 两端补圆头，让起笔和收笔像真实笔尖一样圆润。
            for (point, width) in [
                (stroke.points[0], stroke.widths[0]),
                (stroke.points[3], stroke.widths[stroke.widths.count - 1])
            ] {
                let cap = Path(
                    ellipseIn: CGRect(
                        x: point.x - width / 2,
                        y: point.y - width / 2,
                        width: width,
                        height: width
                    )
                )
                outline = outline.union(cap)
            }
        }
        return outline.applying(HandDrawnTickGeometry.transform(in: rect))
    }
}

/// 沿书写方向逐步展开的揭示区域，作为对勾轮廓的遮罩实现"一笔写出"。
private struct HandDrawnTickReveal: Shape {
    /// 书写进度，0 为未落笔，1 为写完。
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard progress > 0 else { return Path() }

        var centerline = Path()
        for (index, stroke) in HandDrawnTickGeometry.strokes.enumerated() {
            if index == 0 {
                centerline.move(to: stroke.points[0])
            }
            centerline.addCurve(
                to: stroke.points[3],
                control1: stroke.points[1],
                control2: stroke.points[2]
            )
        }

        return centerline
            .trimmedPath(from: 0, to: min(progress, 1))
            .strokedPath(
                StrokeStyle(
                    lineWidth: HandDrawnTickGeometry.revealWidth,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            .applying(HandDrawnTickGeometry.transform(in: rect))
    }
}

/// 账本红的手绘对勾；`progress` 从 0 变到 1 时呈现落笔书写的过程。
struct HandDrawnTick: View {
    /// 书写进度，0 为未落笔，1 为写完。
    var progress: CGFloat = 1

    var body: some View {
        HandDrawnTickShape()
            .fill(Color(.ledgerRed))
            .mask {
                HandDrawnTickReveal(progress: progress)
            }
            .aspectRatio(
                HandDrawnTickGeometry.designBounds.width / HandDrawnTickGeometry.designBounds.height,
                contentMode: .fit
            )
    }
}
