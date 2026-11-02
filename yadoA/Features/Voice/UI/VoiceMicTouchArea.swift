import SwiftUI
import UIKit

/// 麦克风的透明触摸层：直接从 UIKit 触摸事件启动按住计时，不经过 SwiftUI 拖动手势识别。
struct VoiceMicTouchArea: UIViewRepresentable {
    /// 是否只在内切圆内接收触摸；圆形按钮为 true，附属栏这类整条按钮为 false，整个矩形都可按。
    var isCircular = true

    /// 手指按下时尝试开始输入；返回 false 时忽略整次触摸，即使中途恢复空闲也不开始。
    let onPressBegan: () -> Bool

    /// 相对按下位置的竖直位移，向上为负。
    let onPressMoved: (CGFloat) -> Void

    /// 正常松手，交给控制器决定发送还是上滑取消。
    let onPressEnded: () -> Void

    /// 系统中断触摸或控件被移除时丢弃本次输入。
    let onPressCancelled: () -> Void

    /// 创建只接收触摸、不绘制内容和无障碍元素的原生控件。
    func makeUIView(context: Context) -> VoiceMicTouchControl {
        let control = VoiceMicTouchControl()
        control.backgroundColor = .clear
        control.isOpaque = false
        control.isAccessibilityElement = false
        return control
    }

    /// 刷新回调，不打断正在跟踪的触摸；VoiceOver 仍由外层 SwiftUI 按钮负责。
    func updateUIView(_ control: VoiceMicTouchControl, context: Context) {
        control.isCircular = isCircular
        control.onPressBegan = onPressBegan
        control.onPressMoved = onPressMoved
        control.onPressEnded = onPressEnded
        control.onPressCancelled = onPressCancelled
    }

    /// 移除控件时终止尚未结束的触摸，避免计时或收音留在后台继续。
    static func dismantleUIView(_ control: VoiceMicTouchControl, coordinator: ()) {
        control.cancelTracking(with: nil)
    }
}

/// 原生触摸跟踪：按钮区域内按下即回调，移出按钮后仍跟踪，松手前更新最终位移。
final class VoiceMicTouchControl: UIControl {
    /// 是否只在内切圆内接收触摸。
    var isCircular = true

    /// 按下时尝试开始输入，只有被接受的触摸才继续跟踪。
    var onPressBegan: (() -> Bool)?

    /// 移动时上报相对按下位置的竖直位移。
    var onPressMoved: ((CGFloat) -> Void)?

    /// 正常松手时结束输入。
    var onPressEnded: (() -> Void)?

    /// 系统取消触摸时丢弃输入。
    var onPressCancelled: (() -> Void)?

    /// 按下时的窗口坐标，不受按钮缩放和卡片布局变化影响；nil 表示没有接受的触摸。
    private var initialTouchY: CGFloat?

    /// 圆形按钮只在圆内接收新的触摸，不占用四角的列表点击区域；整条按钮整个矩形都可按。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        isCircular ? UIBezierPath(ovalIn: bounds).contains(point) : bounds.contains(point)
    }

    /// 触摸按下立即启动控制器的按住计时；忙碌时返回 false，忽略整次触摸。
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard initialTouchY == nil else { return false }
        let touchY = touch.location(in: nil).y
        guard onPressBegan?() == true else { return false }
        initialTouchY = touchY
        return true
    }

    /// 手指移出圆形范围也继续跟踪，上滑取消后还可以移回恢复发送。
    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard let initialTouchY else { return false }
        onPressMoved?(touch.location(in: nil).y - initialTouchY)
        return true
    }

    /// 松手前使用最终触摸位置更新取消状态，避免遗漏最后一次移动。
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        let initialTouchY = self.initialTouchY
        self.initialTouchY = nil
        super.endTracking(touch, with: event)
        guard let initialTouchY else { return }
        if let touch {
            onPressMoved?(touch.location(in: nil).y - initialTouchY)
        }
        onPressEnded?()
    }

    /// 系统中断或移除控件时只取消，不走松手发送；重复取消不会重复回调。
    override func cancelTracking(with event: UIEvent?) {
        let wasTracking = initialTouchY != nil
        initialTouchY = nil
        super.cancelTracking(with: event)
        if wasTracking {
            onPressCancelled?()
        }
    }
}
