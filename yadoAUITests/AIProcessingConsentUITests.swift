import XCTest

/// 验证首次使用 AI 前弹出的“AI 记账说明”：内容完整、能关掉，关掉后不发请求也不打开聊天页。
///
/// 自动化里没有真实账号，从按住说话和聊天入口走不到弹层，所以用夹具在启动后直接弹出。
/// 登录后的真实流程（首次按住说话弹说明、点聊天入口同意后打开聊天页、换账号重新弹、撤回后重新弹）
/// 以及深色外观下的显示，需要真机验收。
final class AIProcessingConsentUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testConsentSheetShowsFullExplanation() {
        let app = launchAIConsentFixtureInEnglish()

        XCTAssertTrue(app.staticTexts["About AI Bookkeeping"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["What Gets Sent"].exists)
        XCTAssertTrue(app.staticTexts["Who Receives It"].exists)
        XCTAssertTrue(app.staticTexts["Voice"].exists)
        XCTAssertTrue(app.staticTexts["Purpose and Retention"].exists)
        XCTAssertTrue(app.buttons["ai-consent-agree"].exists)
        XCTAssertTrue(app.buttons["ai-consent-decline"].exists)
    }

    @MainActor
    func testDeclineDismissesSheetWithoutOpeningChat() {
        let app = launchAIConsentFixtureInEnglish()
        let decline = app.buttons["ai-consent-decline"]
        XCTAssertTrue(decline.waitForExistence(timeout: 5))

        decline.tap()

        waitForDisappearance(of: app.buttons["ai-consent-agree"])
        XCTAssertTrue(app.descendants(matching: .any)["voice-mic"].firstMatch.waitForExistence(timeout: 5))
        // 没有出现登录提示，也没有打开聊天页
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["voice-chat-field"].firstMatch.exists)
    }

    @MainActor
    func testAgreeDismissesSheetWithoutOpeningChat() {
        let app = launchAIConsentFixtureInEnglish()
        let agree = app.buttons["ai-consent-agree"]
        XCTAssertTrue(agree.waitForExistence(timeout: 5))

        agree.tap()

        // 夹具没有同意后要接着做的事，只关掉弹层
        waitForDisappearance(of: app.buttons["ai-consent-decline"])
        XCTAssertFalse(app.descendants(matching: .any)["voice-chat-field"].firstMatch.exists)
    }

    /// 等元素从界面上消失。
    ///
    /// - Parameter element: 要消失的元素。
    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 5) {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        wait(for: [gone], timeout: timeout)
    }
}
