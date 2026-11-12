import SwiftUI

/// 线条头像的几何工具：解析 SVG 路径、按弧长重新取样、对齐两条线的起点和方向。
///
/// 所有头像和 logo 都画在 `canvasSize` 见方的设计画布上；每条线统一重新取样成 `pointCount` 个点，
/// 变形动画只需逐点插值。设计稿用 SVG 路径字符串描述，Figma 导出的绝对坐标路径可以直接粘贴。
nonisolated enum LineAvatarGeometry {
    /// 每条线取样的点数；64 个点在 240pt 以内的尺寸上看不出折角。
    static let pointCount = 64
    /// 设计画布边长（画布单位），头像居中画在这个正方形里。
    static let canvasSize: CGFloat = 100
    /// 线宽（画布单位），与 logo 原稿 16 / 412 的笔画比例接近，logo 和头像粗细一致。
    static let lineWidth: CGFloat = 3
    /// 首尾距离小于该值（画布单位）的线视为闭合，如脸的轮廓、眼睛。
    static let closedTolerance: CGFloat = 0.5

    // MARK: - SVG 路径

    /// 把 SVG 路径拍平成一条连续折线。
    ///
    /// 支持 `M L H V C Q Z` 及其小写相对坐标形式；同一条线中途的 `M` 会被当作直线连过去，
    /// 所以设计稿里每条线都应是一笔画完的连续线。不支持的命令会跳过其参数。
    /// - Parameter d: SVG `path` 的 `d` 属性。
    /// - Returns: 折线上的点，曲线按固定段数细分。
    static func polyline(fromSVGPath d: String) -> [CGPoint] {
        let tokens = svgTokens(in: d)
        var index = 0
        var points: [CGPoint] = []
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero

        func number() -> CGFloat? {
            guard index < tokens.count, case let .number(value) = tokens[index] else { return nil }
            index += 1
            return value
        }

        func point(relative: Bool) -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }

        func line(to target: CGPoint) {
            if points.isEmpty { points.append(current) }
            points.append(target)
            current = target
        }

        func move(to target: CGPoint) {
            if points.isEmpty {
                points.append(target)
                current = target
            } else {
                line(to: target)
            }
            subpathStart = target
        }

        func cubic(_ control1: CGPoint, _ control2: CGPoint, _ end: CGPoint) {
            if points.isEmpty { points.append(current) }
            let start = current
            for step in 1...cubicSteps {
                let t = CGFloat(step) / CGFloat(cubicSteps)
                let u = 1 - t
                let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, e = t * t * t
                points.append(CGPoint(
                    x: a * start.x + b * control1.x + c * control2.x + e * end.x,
                    y: a * start.y + b * control1.y + c * control2.y + e * end.y
                ))
            }
            current = end
        }

        func quad(_ control: CGPoint, _ end: CGPoint) {
            if points.isEmpty { points.append(current) }
            let start = current
            for step in 1...quadSteps {
                let t = CGFloat(step) / CGFloat(quadSteps)
                let u = 1 - t
                points.append(CGPoint(
                    x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                    y: u * u * start.y + 2 * u * t * control.y + t * t * end.y
                ))
            }
            current = end
        }

        while index < tokens.count {
            guard case let .command(command) = tokens[index] else {
                // 没有命令开头的多余数字直接跳过，避免死循环
                index += 1
                continue
            }
            index += 1
            let relative = command.isLowercase
            switch command.uppercased() {
            case "M":
                guard let target = point(relative: relative) else { break }
                move(to: target)
                // M 之后紧跟的坐标按 L 处理
                while let target = point(relative: relative) { line(to: target) }
            case "L":
                while let target = point(relative: relative) { line(to: target) }
            case "H":
                while let x = number() { line(to: CGPoint(x: relative ? current.x + x : x, y: current.y)) }
            case "V":
                while let y = number() { line(to: CGPoint(x: current.x, y: relative ? current.y + y : y)) }
            case "C":
                while let control1 = point(relative: relative),
                      let control2 = point(relative: relative),
                      let end = point(relative: relative) {
                    cubic(control1, control2, end)
                }
            case "Q":
                while let control = point(relative: relative), let end = point(relative: relative) {
                    quad(control, end)
                }
            case "Z":
                if !points.isEmpty, current != subpathStart { line(to: subpathStart) }
                current = subpathStart
            default:
                while number() != nil {}
            }
        }
        return points
    }

    /// 三次贝塞尔每段细分的步数。
    private static let cubicSteps = 32
    /// 二次贝塞尔每段细分的步数。
    private static let quadSteps = 24

    /// SVG 路径里的一个记号：命令字母或数字。
    nonisolated private enum SVGToken {
        case command(Character)
        case number(CGFloat)
    }

    /// SVG 路径中的命令字母；`e`/`E` 不在其中，属于数字的科学计数法。
    private static let svgCommands: Set<Character> = Set("MmLlHhVvCcSsQqTtAaZz")

    /// 把路径字符串切成命令和数字；兼容 `-` 和第二个小数点直接分隔数字的紧凑写法。
    private static func svgTokens(in d: String) -> [SVGToken] {
        var tokens: [SVGToken] = []
        var buffer = ""

        func flush() {
            if let value = Double(buffer) { tokens.append(.number(CGFloat(value))) }
            buffer = ""
        }

        for character in d {
            if svgCommands.contains(character) {
                flush()
                tokens.append(.command(character))
            } else if character == "," || character.isWhitespace {
                flush()
            } else if character == "-", !buffer.isEmpty, buffer.last != "e", buffer.last != "E" {
                flush()
                buffer.append(character)
            } else if character == ".", buffer.contains("."), !buffer.contains("e"), !buffer.contains("E") {
                flush()
                buffer.append(character)
            } else {
                buffer.append(character)
            }
        }
        flush()
        return tokens
    }

    // MARK: - 取样与对齐

    /// 按弧长均匀取样折线上的一段。
    ///
    /// - Parameters:
    ///   - polyline: 原始折线。
    ///   - start: 起点占全长的比例。
    ///   - end: 终点占全长的比例。
    ///   - count: 取样点数。
    /// - Returns: `count` 个点；折线退化成一个点时返回该点的重复。
    static func resample(
        _ polyline: [CGPoint],
        from start: CGFloat = 0,
        to end: CGFloat = 1,
        count: Int = pointCount
    ) -> [CGPoint] {
        guard count > 0 else { return [] }
        guard polyline.count > 1, count > 1 else {
            return Array(repeating: polyline.first ?? .zero, count: count)
        }

        var lengths: [CGFloat] = [0]
        lengths.reserveCapacity(polyline.count)
        for index in 1..<polyline.count {
            lengths.append(lengths[index - 1] + distance(polyline[index - 1], polyline[index]))
        }
        let total = lengths[lengths.count - 1]
        guard total > 0 else { return Array(repeating: polyline[0], count: count) }

        var result: [CGPoint] = []
        result.reserveCapacity(count)
        var segment = 0
        for step in 0..<count {
            let fraction = start + (end - start) * CGFloat(step) / CGFloat(count - 1)
            let target = total * min(max(fraction, 0), 1)
            while segment < lengths.count - 2, lengths[segment + 1] < target { segment += 1 }
            let segmentLength = lengths[segment + 1] - lengths[segment]
            let t = segmentLength > 0 ? min(max((target - lengths[segment]) / segmentLength, 0), 1) : 0
            result.append(interpolate(polyline[segment], polyline[segment + 1], t))
        }
        return result
    }

    /// 折线首尾是否重合（视为闭合图形）。
    static func isClosed(_ polyline: [CGPoint]) -> Bool {
        guard let first = polyline.first, let last = polyline.last, polyline.count > 2 else { return false }
        return distance(first, last) < closedTolerance
    }

    /// 调整目标线的方向和起点，让它尽量贴近当前线，变形时线条不会翻转或绕圈。
    ///
    /// 开放的线只比较正反两个方向；闭合的线还会尝试每一个起点。
    /// - Parameters:
    ///   - target: 要变成的线，点数与 `reference` 相同。
    ///   - isClosed: 目标线是否闭合。
    ///   - reference: 当前的线。
    /// - Returns: 形状不变、只换了方向或起点的目标线。
    static func aligned(_ target: [CGPoint], isClosed: Bool, to reference: [CGPoint]) -> [CGPoint] {
        guard target.count == reference.count, target.count > 2 else { return target }

        var best = target
        var bestDistance = squaredDistance(target, reference)

        let reversed = Array(target.reversed())
        let reversedDistance = squaredDistance(reversed, reference)
        if reversedDistance < bestDistance {
            best = reversed
            bestDistance = reversedDistance
        }

        guard isClosed else { return best }

        // 闭合线的最后一个点与第一个点重合，旋转时只轮换前 n 个点，再补上首点闭合
        let ringCount = target.count - 1
        for ring in [Array(target.prefix(ringCount)), Array(reversed.prefix(ringCount))] {
            for shift in 0..<ringCount {
                var sum: CGFloat = 0
                for index in 0..<ringCount {
                    sum += squaredDistance(ring[(index + shift) % ringCount], reference[index])
                    if sum >= bestDistance { break }
                }
                sum += squaredDistance(ring[shift], reference[ringCount])
                if sum < bestDistance {
                    bestDistance = sum
                    best = (0...ringCount).map { ring[($0 + shift) % ringCount] }
                }
            }
        }
        return best
    }

    // MARK: - 绘制

    /// 用中点二次曲线把取样点连成平滑路径。
    static func smoothPath(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            if points.count == 2 { path.addLine(to: points[1]) }
            return path
        }
        for index in 1..<(points.count - 1) {
            let control = points[index]
            let next = points[index + 1]
            path.addQuadCurve(to: CGPoint(x: (control.x + next.x) / 2, y: (control.y + next.y) / 2), control: control)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    // MARK: - 工具

    /// 两点间线性插值；`t` 可以超出 0...1，用于弹簧回弹时的过冲。
    static func interpolate(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// 两点距离。
    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }

    private static func squaredDistance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        return dx * dx + dy * dy
    }

    private static func squaredDistance(_ a: [CGPoint], _ b: [CGPoint]) -> CGFloat {
        zip(a, b).reduce(0) { $0 + squaredDistance($1.0, $1.1) }
    }
}
