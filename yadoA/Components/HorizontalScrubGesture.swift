import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// 在图表上左右滑动逐点查看的手势：横着滑才接手，竖着滑交给页面滚动。
///
/// SwiftUI 的拖动手势放在可滚动页面里，要么挡住页面滚动，要么和滚动同时进行；
/// 这里借 iOS 18 起的 `UIGestureRecognizerRepresentable` 用 UIKit 识别器先判断方向，再决定由谁接手。
struct HorizontalScrubGesture: UIGestureRecognizerRepresentable {
    /// 滑动开始和移动时调用，参数是手指在所挂视图里的位置。
    let onChanged: (_ location: CGPoint) -> Void

    /// 手指抬起或被系统打断时调用。
    let onEnded: () -> Void

    func makeUIGestureRecognizer(context: Context) -> HorizontalScrubGestureRecognizer {
        HorizontalScrubGestureRecognizer()
    }

    func handleUIGestureRecognizerAction(_ recognizer: HorizontalScrubGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed:
            onChanged(context.converter.location(in: .local))
        case .ended, .cancelled:
            onEnded()
        default:
            break
        }
    }
}

/// 只认横向滑动的识别器：手指挪开一小段后，横向为主才开始，竖向为主就放弃。
///
/// 页面滚动、侧滑返回这类拖动都要等它判断完方向，所以在图表上横着滑不会带着页面一起动，
/// 竖着滑也只比平时晚几个点开始滚动。
final class HorizontalScrubGestureRecognizer: UIGestureRecognizer {
    /// 判断方向前手指至少要挪开的距离，与系统拖动开始前的容差相近。
    private static let decisionDistance: CGFloat = 8

    /// 手指按下的位置；还没按下时为 `nil`。
    private var startLocation: CGPoint?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard state == .possible else { return }
        // 双指缩放、多指操作不当成查看走势
        guard startLocation == nil, touches.count == 1, let touch = touches.first else {
            state = .failed
            return
        }
        startLocation = touch.location(in: view)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        switch state {
        case .possible:
            guard let startLocation, let location = touches.first?.location(in: view) else { return }
            let horizontal = location.x - startLocation.x
            let vertical = location.y - startLocation.y
            guard hypot(horizontal, vertical) >= Self.decisionDistance else { return }
            state = abs(horizontal) > abs(vertical) ? .began : .failed
        case .began, .changed:
            state = .changed
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        finish(as: .ended)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        finish(as: .cancelled)
    }

    override func reset() {
        super.reset()
        startLocation = nil
    }

    /// 其他拖动（页面滚动、侧滑返回）都等这个识别器先判断方向：它放弃了才轮到它们。
    override func shouldBeRequiredToFail(by otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        otherGestureRecognizer is UIPanGestureRecognizer
    }

    /// 手指离开时收尾：滑动中的按结束或取消处理，还没开始的直接放弃，让点按等手势照常识别。
    ///
    /// - Parameter endState: 正在滑动时要进入的状态，`.ended` 或 `.cancelled`。
    private func finish(as endState: UIGestureRecognizer.State) {
        switch state {
        case .began, .changed:
            state = endState
        case .possible:
            state = .failed
        default:
            break
        }
    }
}
