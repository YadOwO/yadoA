import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// 只看有没有手指按在会话卡片上，自己不识别任何手势：卡片里的滚动、按钮、结果行和长按选字都照常响应。
///
/// SwiftUI 的手势挂在卡片上，要么和里面的按钮、滚动抢，要么长按选字时收不到；
/// 这里借 iOS 18 起的 `UIGestureRecognizerRepresentable` 挂一个永远不会识别成功的 UIKit 识别器，只用它收到的按下和抬起。
struct VoiceCardTouchObserver: UIGestureRecognizerRepresentable {
    /// 手指按下时传 true；抬起、被滚动接手或被系统打断时传 false。
    let onTouchingChange: (Bool) -> Void

    func makeUIGestureRecognizer(context: Context) -> VoiceCardTouchRecognizer {
        let recognizer = VoiceCardTouchRecognizer()
        // 不识别，也不截留或推迟触摸，卡片里的控件收到的触摸和没挂时一样
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesEnded = false
        recognizer.onTouchingChange = onTouchingChange
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: VoiceCardTouchRecognizer, context: Context) {
        recognizer.onTouchingChange = onTouchingChange
    }
}

/// 只报告按下和抬起的识别器：按下时报告，手指离开时放弃识别，在 `reset()` 里报告松手。
///
/// 卡片里的滚动接手时，这个识别器会被系统直接判为失败、收不到抬起，但之后一定会走 `reset()`，所以松手统一在那里报告。
final class VoiceCardTouchRecognizer: UIGestureRecognizer {
    /// 按下和松手时调用。
    var onTouchingChange: (Bool) -> Void = { _ in }

    /// 是否已经报告过按下、还没报告松手。
    private var isTouching = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard !isTouching else { return }
        isTouching = true
        onTouchingChange(true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        state = .failed
    }

    override func reset() {
        super.reset()
        guard isTouching else { return }
        isTouching = false
        onTouchingChange(false)
    }
}
