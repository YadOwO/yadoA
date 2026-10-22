import CoreGraphics
import Testing
@testable import yadoA

/// 麦克风触摸层的可按范围：圆形按钮不占四角，Tab Bar 附属栏里的整条按钮整个矩形都可按。
@Suite("麦克风触摸范围")
@MainActor
struct VoiceMicTouchControlTests {
    @Test("圆形按钮只在圆内接收触摸")
    func circularIgnoresCorners() {
        let control = VoiceMicTouchControl(frame: CGRect(x: 0, y: 0, width: 64, height: 64))

        #expect(control.point(inside: CGPoint(x: 32, y: 32), with: nil))
        #expect(!control.point(inside: CGPoint(x: 2, y: 2), with: nil))
    }

    @Test("整条按钮两端和四角都能按")
    func rectangularAcceptsWholeBounds() {
        let control = VoiceMicTouchControl(frame: CGRect(x: 0, y: 0, width: 300, height: 48))
        control.isCircular = false

        #expect(control.point(inside: CGPoint(x: 2, y: 2), with: nil))
        #expect(control.point(inside: CGPoint(x: 296, y: 24), with: nil))
        #expect(!control.point(inside: CGPoint(x: 310, y: 24), with: nil))
    }
}
