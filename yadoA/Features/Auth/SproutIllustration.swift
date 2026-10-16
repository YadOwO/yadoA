import SwiftUI

/// 登录页中央的手绘插画：一笔墨线画出地面、破土的芽和两片叶子，芽尖顶着一颗账本红的豆子。
///
/// 呼应“芽豆”的名字。出现时墨线先一笔画完，豆子再弹出并给一次轻震，随后在芽尖上轻轻浮动；
/// 点一下豆子会弹跳一下。墨线使用系统主文字色，随浅色、深色外观自动切换。
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
    /// 点按豆子的次数，驱动弹跳与震动。
    @State private var tapCount = 0

    var body: some View {
        let scale = size / SproutGeometry.canvas
        let line = StrokeStyle(lineWidth: 4.8 * scale, lineCap: .round, lineJoin: .round)

        ZStack(alignment: .topLeading) {
            SproutLineShape()
                .trim(from: 0, to: lineProgress)
                .stroke(Color.primary, style: line)

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
                .onTapGesture { tapCount += 1 }
        }
        .frame(width: size, height: size)
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.8), trigger: isBeanVisible) { _, visible in visible }
        .sensoryFeedback(.impact(weight: .light), trigger: tapCount)
        .accessibilityHidden(true)
        .onAppear(perform: play)
    }

    /// 墨线书写 → 豆子弹出 → 闪光短线 → 循环浮动；开启“减弱动态效果”时直接显示最终画面。
    private func play() {
        guard lineProgress == 0 else { return }
        if reduceMotion {
            lineProgress = 1
            isBeanVisible = true
            sparkleProgress = 1
            return
        }
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.easeInOut(duration: 1.5)) {
                lineProgress = 1
            }
            try? await Task.sleep(for: .milliseconds(1350))
            withAnimation(.spring(duration: 0.5, bounce: 0.55)) {
                isBeanVisible = true
            }
            try? await Task.sleep(for: .milliseconds(220))
            withAnimation(.easeOut(duration: 0.35)) {
                sparkleProgress = 1
            }
            try? await Task.sleep(for: .milliseconds(400))
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                isFloating = true
            }
        }
    }
}

/// 芽豆插画在 240×240 设计画布上的几何定义。
private enum SproutGeometry {
    /// 设计画布边长。
    static let canvas: CGFloat = 240

    /// 豆子的圆心。
    static let beanCenter = CGPoint(x: 112, y: 62)

    /// 豆子的半径。
    static let beanRadius: CGFloat = 22

    /// 把设计画布上的路径等比缩放到目标区域。
    static func fit(_ path: Path, in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / canvas
        return path.applying(
            CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale)
        )
    }
}

/// 插画的墨线：地面 → 根须 → 破土的茎 → 两片叶子，按书写顺序排列。
private struct SproutLineShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()

        // 地面：一条略有起伏的横线。
        path.move(to: CGPoint(x: 42, y: 199))
        path.addCurve(to: CGPoint(x: 118, y: 196), control1: CGPoint(x: 70, y: 191), control2: CGPoint(x: 94, y: 203))
        path.addCurve(to: CGPoint(x: 192, y: 197), control1: CGPoint(x: 144, y: 189), control2: CGPoint(x: 170, y: 203))

        // 根须：从茎底向下分出两笔。
        path.move(to: CGPoint(x: 117, y: 198))
        path.addCurve(to: CGPoint(x: 101, y: 217), control1: CGPoint(x: 115, y: 207), control2: CGPoint(x: 109, y: 213))
        path.move(to: CGPoint(x: 120, y: 198))
        path.addCurve(to: CGPoint(x: 138, y: 214), control1: CGPoint(x: 124, y: 206), control2: CGPoint(x: 131, y: 211))

        // 茎：自地面向上，微微摆动，止于豆子底部。
        path.move(to: CGPoint(x: 118, y: 196))
        path.addCurve(to: CGPoint(x: 116, y: 120), control1: CGPoint(x: 104, y: 170), control2: CGPoint(x: 128, y: 142))
        path.addCurve(to: CGPoint(x: 113, y: 85), control1: CGPoint(x: 108, y: 106), control2: CGPoint(x: 111, y: 93))

        // 左叶：从茎上绕出一片，再回到茎上。
        path.move(to: CGPoint(x: 114, y: 150))
        path.addCurve(to: CGPoint(x: 50, y: 140), control1: CGPoint(x: 92, y: 126), control2: CGPoint(x: 60, y: 124))
        path.addCurve(to: CGPoint(x: 114, y: 150), control1: CGPoint(x: 66, y: 158), control2: CGPoint(x: 98, y: 162))
        // 左叶的叶脉。
        path.move(to: CGPoint(x: 62, y: 141))
        path.addQuadCurve(to: CGPoint(x: 104, y: 147), control: CGPoint(x: 84, y: 140))

        // 右叶。
        path.move(to: CGPoint(x: 118, y: 128))
        path.addCurve(to: CGPoint(x: 188, y: 108), control1: CGPoint(x: 138, y: 102), control2: CGPoint(x: 174, y: 96))
        path.addCurve(to: CGPoint(x: 118, y: 128), control1: CGPoint(x: 176, y: 130), control2: CGPoint(x: 142, y: 140))

        return SproutGeometry.fit(path, in: rect)
    }
}

/// 豆子左上方的三道闪光短线，像刚冒出来时闪了一下。
private struct SproutSparkleShape: Shape {
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
