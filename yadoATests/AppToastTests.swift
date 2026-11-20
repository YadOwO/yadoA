import Foundation
import Testing
@testable import yadoA

/// 轻提示（`AppToast`）的取值：默认图标、停留时长，以及相同文案的两条提示互不相等。
@Suite("轻提示")
@MainActor
struct AppToastTests {
    @Test("成功默认带对勾，失败默认带感叹号，说明默认不带图标")
    func defaultSymbols() {
        #expect(AppToast.success("ok").systemImage == "checkmark.circle.fill")
        #expect(AppToast.error("failed").systemImage == "exclamationmark.circle.fill")
        #expect(AppToast.info("note").systemImage == nil)
        #expect(AppToast.success("sent", systemImage: "paperplane.fill").systemImage == "paperplane.fill")
    }

    @Test("失败停留 4 秒，成功和说明停留 2.5 秒")
    func durationsFollowStyle() {
        #expect(AppToast.error("failed").duration == .seconds(4))
        #expect(AppToast.success("ok").duration == .milliseconds(2500))
        #expect(AppToast.info("note").duration == .milliseconds(2500))
    }

    @Test("文案相同的两条提示也是两条：各有各的 id，连着弹时会重新弹出、重新计时")
    func sameMessageIsStillANewToast() {
        let first = AppToast.success("验证码已发送")
        let second = AppToast.success("验证码已发送")
        #expect(first.id != second.id)
        #expect(first != second)
        #expect(first == first)
    }

    @Test("无障碍标识默认 app-toast，可以按页面改")
    func accessibilityIdentifiers() {
        #expect(AppToast.info("note").accessibilityIdentifier == "app-toast")
        #expect(AppToast.error("failed", accessibilityIdentifier: "sign-in-error").accessibilityIdentifier == "sign-in-error")
    }
}
