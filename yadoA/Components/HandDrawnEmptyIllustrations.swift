import SwiftUI

/// 空状态手绘插画共用的画布换算：所有坐标按 120×100 的设计画布等比缩放并居中。
private enum HandDrawnIllustrationCanvas {
    /// 插画的设计画布，与手绘小票保持一致。
    static let size = CGSize(width: 120, height: 100)

    /// 把设计画布上的路径等比缩放并居中到目标区域。
    static func fit(_ path: Path, in rect: CGRect) -> Path {
        let scale = min(rect.width / size.width, rect.height / size.height)
        return path.applying(
            CGAffineTransform(
                translationX: rect.midX - size.width / 2 * scale,
                y: rect.midY - size.height / 2 * scale
            )
            .scaledBy(x: scale, y: scale)
        )
    }
}

/// 手绘卡片的墨线部分；`details` 为假时画卡片轮廓，为真时画磁条和卡号字迹。
private struct HandDrawnCardShape: Shape {
    /// 是否绘制卡面上的细节而不是卡片轮廓。
    let details: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if details {
            path.move(to: CGPoint(x: 23, y: 39))
            path.addCurve(to: CGPoint(x: 98, y: 38.5), control1: CGPoint(x: 48, y: 37.8), control2: CGPoint(x: 74, y: 39.6))
            path.move(to: CGPoint(x: 31, y: 62))
            path.addCurve(to: CGPoint(x: 56, y: 62), control1: CGPoint(x: 39, y: 61), control2: CGPoint(x: 48, y: 63))
            path.move(to: CGPoint(x: 31, y: 51))
            path.addCurve(to: CGPoint(x: 44, y: 51), control1: CGPoint(x: 35, y: 50.4), control2: CGPoint(x: 40, y: 51.6))
        } else {
            // 四条边各自起笔，转角处略微出头，保留手画时线条对不齐的感觉。
            path.move(to: CGPoint(x: 20, y: 25))
            path.addCurve(to: CGPoint(x: 100, y: 24.5), control1: CGPoint(x: 45, y: 22.5), control2: CGPoint(x: 75, y: 23.5))
            path.move(to: CGPoint(x: 98.5, y: 22.5))
            path.addCurve(to: CGPoint(x: 99.5, y: 78), control1: CGPoint(x: 100.5, y: 40), control2: CGPoint(x: 97.5, y: 60))
            path.move(to: CGPoint(x: 101, y: 76.5))
            path.addCurve(to: CGPoint(x: 20.5, y: 77.5), control1: CGPoint(x: 75, y: 79), control2: CGPoint(x: 45, y: 78.5))
            path.move(to: CGPoint(x: 22.5, y: 79))
            path.addCurve(to: CGPoint(x: 22, y: 23), control1: CGPoint(x: 20.5, y: 60), control2: CGPoint(x: 23.5, y: 40))
        }
        return HandDrawnIllustrationCanvas.fit(path, in: rect)
    }
}

/// 账户空状态使用的手绘卡片：墨线画出的卡片，加一笔账本红对勾。
///
/// 墨线使用系统主文字色，随浅色、深色外观自动切换；出现时对勾会写一遍。
struct HandDrawnCardIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 插画宽度，高度按设计画布比例确定。
    var width: CGFloat = 112

    /// 对勾的书写进度。
    @State private var tickProgress: CGFloat = 0

    var body: some View {
        let scale = width / HandDrawnIllustrationCanvas.size.width
        let stroke = StrokeStyle(lineWidth: 3 * scale, lineCap: .round, lineJoin: .round)

        ZStack(alignment: .topLeading) {
            HandDrawnCardShape(details: false)
                .stroke(Color.primary, style: stroke)
            HandDrawnCardShape(details: true)
                .stroke(Color.primary.opacity(0.3), style: stroke)
            // 对勾压在卡片右下角，位置与笔宽按画布比例换算。
            HandDrawnTick(progress: tickProgress)
                .frame(width: 41.4 * scale)
                .offset(x: 74 * scale, y: 54 * scale)
        }
        .frame(width: width, height: HandDrawnIllustrationCanvas.size.height * scale)
        .accessibilityHidden(true)
        .onAppear {
            if reduceMotion {
                tickProgress = 1
            } else {
                withAnimation(.easeInOut(duration: 0.45).delay(0.35)) {
                    tickProgress = 1
                }
            }
        }
    }
}

/// 手绘趋势图的各个部分。
private struct HandDrawnTrendShape: Shape {
    /// 趋势图插画的组成部分。
    enum Part {
        /// 墨线画的纵横坐标轴。
        case axes
        /// 坐标轴内的淡色柱子。
        case bars
        /// 向右上走的趋势折线。
        case trend
    }

    /// 当前绘制的部分。
    let part: Part

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch part {
        case .axes:
            // 两条轴各自起笔，交点处略微出头。
            path.move(to: CGPoint(x: 26, y: 14))
            path.addCurve(to: CGPoint(x: 27, y: 83), control1: CGPoint(x: 25, y: 36), control2: CGPoint(x: 28, y: 60))
            path.move(to: CGPoint(x: 23.5, y: 80.5))
            path.addCurve(to: CGPoint(x: 101, y: 80), control1: CGPoint(x: 50, y: 82), control2: CGPoint(x: 76, y: 79))
        case .bars:
            path.move(to: CGPoint(x: 43, y: 73))
            path.addCurve(to: CGPoint(x: 43.5, y: 64), control1: CGPoint(x: 42.6, y: 70), control2: CGPoint(x: 43.6, y: 67))
            path.move(to: CGPoint(x: 60, y: 73))
            path.addCurve(to: CGPoint(x: 59.5, y: 56), control1: CGPoint(x: 60.5, y: 67), control2: CGPoint(x: 59.3, y: 61))
            path.move(to: CGPoint(x: 77, y: 73))
            path.addCurve(to: CGPoint(x: 77.5, y: 60), control1: CGPoint(x: 76.6, y: 69), control2: CGPoint(x: 77.7, y: 64))
        case .trend:
            path.move(to: CGPoint(x: 37, y: 54))
            path.addLine(to: CGPoint(x: 52, y: 42))
            path.addLine(to: CGPoint(x: 66, y: 49))
            path.addLine(to: CGPoint(x: 93, y: 23))
        }
        return HandDrawnIllustrationCanvas.fit(path, in: rect)
    }
}

/// 图表空状态使用的手绘趋势图：墨线坐标轴，加一笔账本红的上扬折线。
///
/// 墨线使用系统主文字色，随浅色、深色外观自动切换；出现时折线会画一遍。
struct HandDrawnTrendIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 插画宽度，高度按设计画布比例确定。
    var width: CGFloat = 112

    /// 折线的书写进度。
    @State private var trendProgress: CGFloat = 0

    var body: some View {
        let scale = width / HandDrawnIllustrationCanvas.size.width
        let stroke = StrokeStyle(lineWidth: 3 * scale, lineCap: .round, lineJoin: .round)

        ZStack {
            HandDrawnTrendShape(part: .axes)
                .stroke(Color.primary, style: stroke)
            HandDrawnTrendShape(part: .bars)
                .stroke(Color.primary.opacity(0.3), style: stroke)
            HandDrawnTrendShape(part: .trend)
                .trim(from: 0, to: trendProgress)
                .stroke(
                    Color(.ledgerRed),
                    style: StrokeStyle(lineWidth: 4 * scale, lineCap: .round, lineJoin: .round)
                )
        }
        .frame(width: width, height: HandDrawnIllustrationCanvas.size.height * scale)
        .accessibilityHidden(true)
        .onAppear {
            if reduceMotion {
                trendProgress = 1
            } else {
                withAnimation(.easeInOut(duration: 0.55).delay(0.35)) {
                    trendProgress = 1
                }
            }
        }
    }
}

/// 手绘放大镜的各个部分。
private struct HandDrawnMagnifierShape: Shape {
    /// 放大镜插画的组成部分。
    enum Part {
        /// 墨线画的镜框和手柄。
        case frame
        /// 镜片里淡色的一行字迹。
        case details
        /// 镜片里被找到、用红笔划出的那一行。
        case mark
    }

    /// 当前绘制的部分。
    let part: Part

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch part {
        case .frame:
            // 镜框一笔画完，收笔处越过起笔点一小段；手柄另起一笔，略微出头。
            path.addArc(
                center: CGPoint(x: 52, y: 44),
                radius: 27,
                startAngle: .degrees(-112),
                endAngle: .degrees(262),
                clockwise: false
            )
            path.move(to: CGPoint(x: 70, y: 63.5))
            path.addCurve(to: CGPoint(x: 96, y: 87), control1: CGPoint(x: 79, y: 70), control2: CGPoint(x: 87, y: 80))
        case .details:
            path.move(to: CGPoint(x: 37, y: 37))
            path.addCurve(to: CGPoint(x: 64, y: 36.5), control1: CGPoint(x: 46, y: 36), control2: CGPoint(x: 56, y: 38))
        case .mark:
            path.move(to: CGPoint(x: 37, y: 50))
            path.addCurve(to: CGPoint(x: 68, y: 49), control1: CGPoint(x: 47, y: 48.6), control2: CGPoint(x: 58, y: 51))
        }
        return HandDrawnIllustrationCanvas.fit(path, in: rect)
    }
}

/// 搜索空状态使用的手绘放大镜：墨线画出的镜框，镜片里用账本红划出找到的那一行。
///
/// 墨线使用系统主文字色，随浅色、深色外观自动切换；出现时红线会画一遍。
struct HandDrawnMagnifierIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 插画宽度，高度按设计画布比例确定。
    var width: CGFloat = 112

    /// 红线的书写进度。
    @State private var markProgress: CGFloat = 0

    var body: some View {
        let scale = width / HandDrawnIllustrationCanvas.size.width
        let stroke = StrokeStyle(lineWidth: 3 * scale, lineCap: .round, lineJoin: .round)

        ZStack {
            HandDrawnMagnifierShape(part: .frame)
                .stroke(Color.primary, style: stroke)
            HandDrawnMagnifierShape(part: .details)
                .stroke(Color.primary.opacity(0.3), style: stroke)
            HandDrawnMagnifierShape(part: .mark)
                .trim(from: 0, to: markProgress)
                .stroke(
                    Color(.ledgerRed),
                    style: StrokeStyle(lineWidth: 4 * scale, lineCap: .round, lineJoin: .round)
                )
        }
        .frame(width: width, height: HandDrawnIllustrationCanvas.size.height * scale)
        .accessibilityHidden(true)
        .onAppear {
            if reduceMotion {
                markProgress = 1
            } else {
                withAnimation(.easeInOut(duration: 0.45).delay(0.35)) {
                    markProgress = 1
                }
            }
        }
    }
}

#Preview {
    VStack(spacing: 40) {
        HandDrawnCardIllustration()
        HandDrawnTrendIllustration()
        HandDrawnMagnifierIllustration()
    }
    .padding(40)
}
