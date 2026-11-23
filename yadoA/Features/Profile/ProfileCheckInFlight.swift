import SwiftUI

/// 签到奖励的一次飞行：「+N 点」从页头的签到气泡飞到「AI 点数」那一行。
///
/// 坐标都在「我的」页滚动内容的命名坐标空间里（`ProfileView.contentCoordinateSpace`），滚动时跟着内容一起走。
struct CheckInRewardFlight: Identifiable, Equatable {
    /// 每次飞行一个新标识，连续两次签到（例如换账号）不会复用上一次的动画状态。
    let id = UUID()

    /// 这次签到获得的点数。
    let points: Int

    /// 起点：签到气泡的中心。
    let from: CGPoint

    /// 终点：「AI 点数」行尾数字附近。
    let to: CGPoint
}

/// 签到时先按住不变的行尾文字：「AI 点数」「每日签到」两行停在签到前的样子，等奖励飞到后再依次放开，
/// 让数字从旧值滚到新值，用户看得到点数和连签天数是怎么变的。
struct CheckInHeldRows: Equatable {
    /// 「AI 点数」行签到前的行尾文字和颜色；为 nil 时已放开，显示最新余额。
    var points: HeldValue?

    /// 「每日签到」行签到前的行尾文字和颜色；为 nil 时已放开，显示最新的连签天数或待开礼包。
    var streak: HeldValue?

    /// 按住的一行行尾：文字和它当时的颜色。
    struct HeldValue: Equatable {
        /// 行尾文字。
        let text: String

        /// 行尾颜色；为 nil 时是默认的灰色。
        let tint: Color?
    }
}

/// 奖励落到后用强调色提示一下的行。
enum CheckInRewardRow: Hashable {
    /// 「AI 点数」行。
    case points

    /// 「每日签到」行。
    case streak
}

/// 飞行中的「+N 点」小签：出现后沿一道向上拱起的弧线飞到终点，边飞边缩小，快到时淡出。
///
/// 只做装饰，不参与读屏：点数已由签到气泡播报过。开启「减弱动态效果」时页面不会创建它。
struct CheckInRewardToken: View {
    @Environment(\.locale) private var locale

    /// 这次飞行。
    let flight: CheckInRewardFlight

    /// 从起点飞到终点的时长。
    static let duration = 0.65

    /// 飞行进度，0 在起点，1 在终点。
    @State private var progress: CGFloat = 0

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "leaf.fill")
                .font(.caption2.weight(.semibold))
            Text(String(
                format: AccountLocalization.string("profile.checkIn.gained", locale: locale),
                locale: locale,
                flight.points.formatted(.number.locale(locale))
            ))
            .font(.system(.caption, design: .serif, weight: .semibold))
            .monospacedDigit()
        }
        .foregroundStyle(Color(.ledgerGreen))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color(.paperBackground)))
        .overlay(Capsule().stroke(Color.primary.opacity(0.25), lineWidth: 1))
        .fixedSize()
        .modifier(CheckInRewardFlightPath(from: flight.from, to: flight.to, progress: progress))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(.easeInOut(duration: Self.duration)) { progress = 1 }
        }
    }
}

/// 按进度把小签摆到弧线上：二次贝塞尔曲线，控制点在起点上方，先向上扬起再落向终点。
private struct CheckInRewardFlightPath: ViewModifier, Animatable {
    /// 起点。
    let from: CGPoint

    /// 终点。
    let to: CGPoint

    /// 飞行进度，0...1。
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 - 0.25 * progress)
            // 最后 15% 的路程里淡出，像是落进了那一行
            .opacity(progress < 0.85 ? 1 : max(0, Double((1 - progress) / 0.15)))
            .position(point(at: progress))
    }

    /// 弧线上某一进度的位置。
    ///
    /// - Parameter t: 进度，0...1。
    private func point(at t: CGFloat) -> CGPoint {
        let control = CGPoint(x: (from.x + to.x) / 2, y: min(from.y, to.y) - 60)
        let u = 1 - t
        return CGPoint(
            x: u * u * from.x + 2 * u * t * control.x + t * t * to.x,
            y: u * u * from.y + 2 * u * t * control.y + t * t * to.y
        )
    }
}
