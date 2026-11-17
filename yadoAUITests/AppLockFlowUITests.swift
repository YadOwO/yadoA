import XCTest

/// 验证应用锁的冷启动锁屏、回前台重新上锁和切换器遮挡；全程用假验证器，不弹系统的面容 ID 或密码界面。
///
/// 真实的面容 ID、失败三次退回密码、App 切换器的截图效果需真机验收。
final class AppLockFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testColdStartShowsLockScreenUntilUnlocked() {
        let app = launchAppLockInEnglish()
        let lockScreen = lockScreenElement(in: app)
        XCTAssertTrue(lockScreen.waitForExistence(timeout: 5))
        // 验证通过前主界面根本没有挂载
        XCTAssertFalse(app.buttons["home-add-expense"].exists)

        app.buttons["app-lock-unlock"].tap()

        XCTAssertTrue(app.buttons["home-add-expense"].waitForExistence(timeout: 5))
        XCTAssertTrue(lockScreen.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testImmediateTimeoutRelocksAfterBackground() {
        let app = launchAppLockInEnglish()
        unlock(app)

        XCUIDevice.shared.press(.home)
        app.activate()

        let lockScreen = lockScreenElement(in: app)
        XCTAssertTrue(lockScreen.waitForExistence(timeout: 5))
        app.buttons["app-lock-unlock"].tap()
        XCTAssertTrue(lockScreen.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home-add-expense"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testOneMinuteTimeoutSkipsLockOnQuickReturn() {
        let app = launchAppLockInEnglish(oneMinute: true)
        unlock(app)

        XCUIDevice.shared.press(.home)
        app.activate()

        // 1 分钟内回来不上锁；给锁屏一点出现的时间，再确认它没有出现
        XCTAssertFalse(lockScreenElement(in: app).waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["home-add-expense"].exists)
    }

    /// 下拉通知中心会让 App 进入非活跃但不进后台；依赖 springboard 的手势坐标，不同机型可能要调整。
    @MainActor
    func testPrivacyCoverAppearsWhileInactive() {
        let app = launchAppLockInEnglish()
        unlock(app)
        let cover = app.descendants(matching: .any)["app-privacy-cover"].firstMatch
        XCTAssertFalse(cover.exists)

        // 从屏幕左上边缘往下拖，拉出通知中心
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let start = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.0))
        let end = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.8))
        start.press(forDuration: 0.1, thenDragTo: end)

        XCTAssertTrue(cover.waitForExistence(timeout: 5))

        // 往上滑收起通知中心；回到前台后遮挡消失，且离开的时间不到后台，不会重新上锁
        let swipeStart = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        let swipeEnd = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
        swipeStart.press(forDuration: 0.1, thenDragTo: swipeEnd)
        if cover.exists {
            app.activate()
        }
        XCTAssertTrue(cover.waitForNonExistence(timeout: 5))
    }

    /// 锁屏元素；根视图是无障碍容器，用 any 类型按标识查找。
    @MainActor
    private func lockScreenElement(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["app-lock-screen"].firstMatch
    }

    /// 在锁屏上点「解锁」，等主界面出现。
    @MainActor
    private func unlock(_ app: XCUIApplication) {
        let unlock = app.buttons["app-lock-unlock"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 5))
        unlock.tap()
        XCTAssertTrue(app.buttons["home-add-expense"].waitForExistence(timeout: 5))
        XCTAssertTrue(lockScreenElement(in: app).waitForNonExistence(timeout: 5))
    }
}
