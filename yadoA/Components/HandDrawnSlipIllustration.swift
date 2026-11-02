import SwiftUI

/// 手绘小票的墨线部分；`ruledLines` 为假时画纸张轮廓，为真时画纸上的三行字迹。
private struct HandDrawnSlipShape: Shape {
    /// 插画的设计画布，所有坐标按它等比缩放。
    static let canvas = CGSize(width: 120, height: 100)

    /// 是否绘制纸上的横线而不是纸张轮廓。
    let ruledLines: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if ruledLines {
            path.move(to: CGPoint(x: 41, y: 31))
            path.addCurve(to: CGPoint(x: 68, y: 31), control1: CGPoint(x: 50, y: 30), control2: CGPoint(x: 60, y: 32))
            path.move(to: CGPoint(x: 41, y: 45))
            path.addCurve(to: CGPoint(x: 78, y: 45), control1: CGPoint(x: 53, y: 44), control2: CGPoint(x: 66, y: 46))
            path.move(to: CGPoint(x: 41, y: 59))
            path.addCurve(to: CGPoint(x: 58, y: 59), control1: CGPoint(x: 47, y: 58.2), control2: CGPoint(x: 53, y: 59.8))
        } else {
            // 四条边各自起笔，转角处略微出头，保留手画时线条对不齐的感觉。
            path.move(to: CGPoint(x: 27, y: 15))
            path.addCurve(to: CGPoint(x: 90, y: 15.5), control1: CGPoint(x: 46, y: 12.5), control2: CGPoint(x: 70, y: 13.5))
            path.move(to: CGPoint(x: 88.5, y: 13))
            path.addCurve(to: CGPoint(x: 90, y: 83), control1: CGPoint(x: 90.5, y: 34), control2: CGPoint(x: 88, y: 58))
            // 底边是撕下小票的锯齿。
            path.addLines([
                CGPoint(x: 90, y: 83), CGPoint(x: 81.5, y: 76.5), CGPoint(x: 73, y: 84),
                CGPoint(x: 64.5, y: 77), CGPoint(x: 56, y: 84.5), CGPoint(x: 47.5, y: 77.5),
                CGPoint(x: 39, y: 84.5), CGPoint(x: 29.5, y: 78)
            ])
            path.addCurve(to: CGPoint(x: 30, y: 13), control1: CGPoint(x: 31.5, y: 58), control2: CGPoint(x: 28, y: 36))
        }

        let scale = min(rect.width / Self.canvas.width, rect.height / Self.canvas.height)
        return path.applying(
            CGAffineTransform(
                translationX: rect.midX - Self.canvas.width / 2 * scale,
                y: rect.midY - Self.canvas.height / 2 * scale
            )
            .scaledBy(x: scale, y: scale)
        )
    }
}

/// 空状态使用的手绘小票：墨线画出的纸张，加一笔账本红对勾。
///
/// 墨线使用系统主文字色，随浅色、深色外观自动切换；出现时对勾会写一遍。
struct HandDrawnSlipIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 插画宽度，高度按设计画布比例确定。
    var width: CGFloat = 112

    /// 对勾的书写进度。
    @State private var tickProgress: CGFloat = 0

    var body: some View {
        let scale = width / HandDrawnSlipShape.canvas.width
        let stroke = StrokeStyle(lineWidth: 3 * scale, lineCap: .round, lineJoin: .round)

        ZStack(alignment: .topLeading) {
            HandDrawnSlipShape(ruledLines: false)
                .stroke(Color.primary, style: stroke)
            HandDrawnSlipShape(ruledLines: true)
                .stroke(Color.primary.opacity(0.3), style: stroke)
            // 对勾压在小票右下角，位置与笔宽按画布比例换算。
            HandDrawnTick(progress: tickProgress)
                .frame(width: 41.4 * scale)
                .offset(x: 67.6 * scale, y: 59.1 * scale)
        }
        .frame(width: width, height: HandDrawnSlipShape.canvas.height * scale)
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

#Preview {
    HandDrawnSlipIllustration()
        .padding(40)
}
