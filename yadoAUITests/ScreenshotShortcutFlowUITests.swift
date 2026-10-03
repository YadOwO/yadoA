import XCTest

/// 验证应用内交接与手动保存；系统快捷指令授权和背部双击需真机验收。
final class ScreenshotShortcutFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testColdStartCanPreviewAndCancelWithoutSaving() {
        let app = launchScreenshotFixture(coldStart: true)
        assertScreenshotReceived(in: app)
        app.buttons["screenshot-entry-close"].tap()
        XCTAssertTrue(app.buttons["home-add-expense"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testIntentWhileSetupIsPresentedAndRepeatAfterClosing() {
        let app = launchScreenshotFixture(coldStart: false)
        app.buttons["home-profile"].tap()
        app.buttons["profile-screenshot-shortcut"].tap()
        let invoke = app.buttons["screenshot-shortcut-test-invoke"]
        app.swipeUp()
        XCTAssertTrue(invoke.waitForExistence(timeout: 5))
        invoke.tap()
        assertScreenshotReceived(in: app)
        app.buttons["screenshot-entry-close"].tap()

        // 原设置页面应仍然存在，关闭一次录入后可以再次运行。
        XCTAssertTrue(invoke.waitForExistence(timeout: 5))
        invoke.tap()
        assertScreenshotReceived(in: app)
    }

    @MainActor
    func testScreenshotRequiresManualInputAndSavesThroughExistingForm() {
        let app = launchScreenshotFixture(coldStart: true)
        XCTAssertTrue(app.buttons["screenshot-entry-close"].waitForExistence(timeout: 5))
        let save = app.buttons["expense-entry-save"]
        XCTAssertFalse(save.isEnabled)
        app.buttons["expense-entry-category"].tap()
        app.buttons["expense-category-dining"].tap()
        let amount = app.textFields["expense-entry-amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 3))
        amount.tap()
        amount.typeText("12.50")
        app.buttons["Done"].tap()
        app.buttons["expense-entry-account"].tap()
        let account = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "expense-account-selection-row-")).firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 3))
        account.tap()
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.buttons["home-add-expense"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["screenshot-entry-close"].exists)
    }

    /// 同时验证接收提示、真实图片预览，以及没有自动填写金额。
    @MainActor
    private func assertScreenshotReceived(in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["screenshot-entry-close"].waitForExistence(timeout: 8))
        let preview = app.descendants(matching: .any)["screenshot-entry-preview"].firstMatch
        XCTAssertTrue(preview.exists)
        preview.tap()
        XCTAssertTrue(app.images["screenshot-entry-image"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["expense-entry-save"].isEnabled)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 使用现有账本夹具和独立内存容器，避免测试写入真实数据。
    @MainActor
    private func launchScreenshotFixture(coldStart: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-in-memory", "--ui-testing-home-fixture", "--ui-testing-screenshot-shortcut",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ]
        if coldStart { app.launchArguments.append("--ui-testing-screenshot-cold-start") }
        app.launch()
        return app
    }
}
