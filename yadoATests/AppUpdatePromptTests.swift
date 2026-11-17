import Foundation
import Testing
@testable import yadoA

/// 验证「需要更新」提示：每次启动只弹一次、426 判定、App Store 地址拼法。
@Suite("升级提示")
@MainActor
struct AppUpdatePromptTests {
    @Test("每次启动只弹一次：弹出后用户关掉，再次触发也不会重新弹出")
    func presentsOnlyOncePerLaunch() {
        // 用新实例而不是 .shared，避免和其他测试共用状态。
        let prompt = AppUpdatePrompt()
        #expect(!prompt.isPresented)
        #expect(!prompt.hasPrompted)

        prompt.present()
        #expect(prompt.isPresented)
        #expect(prompt.hasPrompted)

        // 模拟用户点掉提示。
        prompt.isPresented = false
        prompt.present()
        #expect(!prompt.isPresented)
        #expect(prompt.hasPrompted)
    }

    @Test("服务端要求升级的状态码是 426")
    func upgradeRequiredStatusCodeIs426() {
        #expect(AppUpdatePrompt.upgradeRequiredStatusCode == 426)
    }

    @Test("检查响应：426 判为需要升级，200 不是")
    func checkUpgradeRequiredMatchesStatusCode() throws {
        let url = try #require(URL(string: "https://example.com/api"))
        let upgradeRequired = try #require(
            HTTPURLResponse(url: url, statusCode: 426, httpVersion: nil, headerFields: nil)
        )
        let ok = try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        )

        // 判定为 426 时内部会异步通知 shared，这里只断言返回值，不碰 shared 的状态。
        #expect(AppUpdatePrompt.checkUpgradeRequired(upgradeRequired))
        #expect(!AppUpdatePrompt.checkUpgradeRequired(ok))
    }

    @Test("App Store 地址：只有纯 ASCII 数字 ID 才拼出产品页，其余一律为 nil")
    func buildsAppStoreProductURL() {
        #expect(AppStoreLink.productURL(id: "1234567890")?.absoluteString == "https://apps.apple.com/app/id1234567890")
        #expect(AppStoreLink.productURL(id: nil) == nil)
        #expect(AppStoreLink.productURL(id: "") == nil)
        #expect(AppStoreLink.productURL(id: "id123?x=1") == nil)
        // 全角数字不是 ASCII 数字。
        #expect(AppStoreLink.productURL(id: "１２３") == nil)

        // 当前没配置 App Store ID，提示里不显示跳转按钮。
        #expect(AppUpdatePrompt.appStoreURL == nil)
    }
}
