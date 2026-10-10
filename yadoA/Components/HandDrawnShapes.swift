import SwiftUI

/// 手绘图形共用的确定性抖动来源。
///
/// 同一个种子总是得到同一组偏移：线条看起来是随手画的，但重绘、滚动和外观切换时不会跳动。
struct HandDrawnJitter {
    /// SplitMix64 的内部状态。
    private var state: UInt64

    /// - Parameter seed: 决定这一笔长什么样的种子，相同种子得到相同笔迹。
    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    /// 取下一个 -1...1 之间的偏移系数。
    mutating func next() -> CGFloat {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value = value ^ (value >> 31)
        return CGFloat(value >> 11) / CGFloat(UInt64(1) << 53) * 2 - 1
    }
}

extension UUID {
    /// 由标识本身推出的笔迹种子，同一条数据每次都画成同一个样子。
    var handDrawnSeed: UInt64 {
        let bytes = uuid
        return [bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7]
            .reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }
}

/// 一条随手画出的横线：整体水平，中途略有起伏，两端长短不齐。
///
/// 用来代替列表分隔线和标题下的直线，线条画在给定区域的垂直中线上。
struct HandDrawnRule: Shape {
    /// 笔迹种子。
    var seed: UInt64 = 0

    func path(in rect: CGRect) -> Path {
        var jitter = HandDrawnJitter(seed: seed)
        let amplitude = min(rect.height / 2, 1.1)
        let segmentCount = max(2, Int(rect.width / 80))
        let step = rect.width / CGFloat(segmentCount)

        var points: [CGPoint] = []
        for index in 0...segmentCount {
            var x = rect.minX + step * CGFloat(index)
            // 两端各自缩进一点，避免每条线都整整齐齐顶到边。
            if index == 0 {
                x += (jitter.next() + 1) * 2
            } else if index == segmentCount {
                x -= (jitter.next() + 1) * 2
            }
            points.append(CGPoint(x: x, y: rect.midY + jitter.next() * amplitude))
        }

        // 以相邻点的中点为端点、原始点为控制点，得到没有折角的连续曲线。
        var path = Path()
        path.move(to: points[0])
        for index in 1..<(points.count - 1) {
            let middle = CGPoint(
                x: (points[index].x + points[index + 1].x) / 2,
                y: (points[index].y + points[index + 1].y) / 2
            )
            path.addQuadCurve(to: middle, control: points[index])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}

/// 一笔画成的圆角方框：四条边微微鼓起或内凹，收笔处略微越过起笔点。
///
/// 用来代替卡片的实色底，描边即可得到手画的边框。
struct HandDrawnBox: Shape {
    /// 圆角大小，超过短边一半时自动收小。
    var cornerRadius: CGFloat = 20

    /// 笔迹种子。
    var seed: UInt64 = 0

    func path(in rect: CGRect) -> Path {
        var jitter = HandDrawnJitter(seed: seed)
        let radius = min(cornerRadius, min(rect.width, rect.height) / 2)

        /// 垂直于边方向的小幅偏移。
        func wobble(_ scale: CGFloat = 1.3) -> CGFloat {
            jitter.next() * scale
        }

        var path = Path()
        let start = CGPoint(x: rect.minX + radius, y: rect.minY + wobble())
        path.move(to: start)

        // 上边
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.minY + wobble()),
            control: CGPoint(x: rect.midX + wobble(12), y: rect.minY + wobble(1.8))
        )
        // 右上角
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX + wobble(), y: rect.minY + radius),
            control: CGPoint(x: rect.maxX + wobble(), y: rect.minY + wobble())
        )
        // 右边
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX + wobble(), y: rect.maxY - radius),
            control: CGPoint(x: rect.maxX + wobble(1.8), y: rect.midY + wobble(8))
        )
        // 右下角
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY + wobble()),
            control: CGPoint(x: rect.maxX + wobble(), y: rect.maxY + wobble())
        )
        // 下边
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.maxY + wobble()),
            control: CGPoint(x: rect.midX + wobble(12), y: rect.maxY + wobble(1.8))
        )
        // 左下角
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + wobble(), y: rect.maxY - radius),
            control: CGPoint(x: rect.minX + wobble(), y: rect.maxY + wobble())
        )
        // 左边
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + wobble(), y: rect.minY + radius),
            control: CGPoint(x: rect.minX + wobble(1.8), y: rect.midY + wobble(8))
        )
        // 左上角收笔：越过起笔点一小段，并且没有完全对上。
        path.addQuadCurve(
            to: CGPoint(x: start.x + 12, y: start.y - 1.6),
            control: CGPoint(x: rect.minX + wobble(), y: rect.minY - 1)
        )
        return path
    }
}

/// 一个不规则的圆润色块，像用笔随手涂出的底。
///
/// 用来代替图标后面的圆角方块，填充使用。
struct HandDrawnBlob: Shape {
    /// 笔迹种子。
    var seed: UInt64 = 0

    /// 围成色块的控制点数量。
    private let pointCount = 7

    func path(in rect: CGRect) -> Path {
        var jitter = HandDrawnJitter(seed: seed)
        let center = CGPoint(x: rect.midX, y: rect.midY)

        var points: [CGPoint] = []
        for index in 0..<pointCount {
            let angle = (CGFloat(index) + jitter.next() * 0.22) / CGFloat(pointCount) * 2 * .pi
            // 中点平滑会让曲线落在控制点内侧，这里把半径略放大以填满给定区域。
            let reach = 1.04 + jitter.next() * 0.09
            points.append(
                CGPoint(
                    x: center.x + cos(angle) * rect.width / 2 * reach,
                    y: center.y + sin(angle) * rect.height / 2 * reach
                )
            )
        }

        /// 相邻两个控制点的中点。
        func middle(_ index: Int) -> CGPoint {
            let current = points[index % pointCount]
            let next = points[(index + 1) % pointCount]
            return CGPoint(x: (current.x + next.x) / 2, y: (current.y + next.y) / 2)
        }

        var path = Path()
        path.move(to: middle(pointCount - 1))
        for index in 0..<pointCount {
            path.addQuadCurve(to: middle(index), control: points[index])
        }
        path.closeSubpath()
        return path
    }
}

#Preview {
    VStack(spacing: 28) {
        HandDrawnBox(cornerRadius: 22, seed: 7)
            .stroke(Color.primary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            .frame(height: 88)
        HStack(spacing: 16) {
            ForEach(0..<5, id: \.self) { index in
                HandDrawnBlob(seed: UInt64(index))
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 38, height: 38)
            }
        }
        ForEach(0..<3, id: \.self) { index in
            HandDrawnRule(seed: UInt64(index))
                .stroke(Color.primary.opacity(0.5), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                .frame(height: 3)
        }
    }
    .padding(24)
    .paperPage()
}
