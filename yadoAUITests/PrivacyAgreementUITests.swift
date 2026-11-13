import XCTest

/// 验证中国大陆地区首次启动的隐私政策同意卡：先于引导出现、同意后进入引导且不再弹出、不同意进入离线模式、离线时可重新同意。
///
/// 中国大陆地区靠启动参数模拟（`--ui-testing-privacy-agreement`），不依赖系统地区；真机抓包验收「同意前没有任何请求」由人工完成。
final class PrivacyAgreementUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFirstLaunchShowsAgreementCardBeforeOnboarding() {
        let app = launchPrivacyAgreementInEnglish(reset: true, onboarding: true)

        XCTAssertTrue(app.descendants(matching: .any)["privacy-agreement-card"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["privacy-agreement-agree"].exists)
        XCTAssertTrue(app.buttons["privacy-agreement-decline"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["privacy-agreement-links"].firstMatch.exists)
        // 选择之前引导不显示
        XCTAssertFalse(app.buttons["onboarding-enter"].exists)
    }

    @MainActor
    func testAgreeEntersOnboardingAndNeverShowsAgain() {
        let app = launchPrivacyAgreementInEnglish(reset: true, onboarding: true)
        let agree = app.buttons["privacy-agreement-agree"]
        XCTAssertTrue(agree.waitForExistence(timeout: 5))

        agree.tap()

        waitForDisappearance(of: app.buttons["privacy-agreement-agree"])
        // 开场动画播完后才出现进入按钮
        XCTAssertTrue(app.buttons["onboarding-enter"].waitForExistence(timeout: 15))

        app.terminate()
        let relaunched = launchPrivacyAgreementInEnglish(reset: false)
        XCTAssertTrue(relaunched.tabBars.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(relaunched.buttons["privacy-agreement-agree"].exists)
    }

    @MainActor
    func testDeclineEntersOfflineMode() {
        let app = launchPrivacyAgreementInEnglish(reset: true)
        declineAgreement(in: app)
        openProfileTab(in: app)

        XCTAssertTrue(app.buttons["profile-offline-agree"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["profile-sign-in"].exists)
        XCTAssertFalse(app.buttons["profile-ai-points"].exists)
        XCTAssertFalse(app.buttons["profile-sync"].exists)
        XCTAssertFalse(app.buttons["profile-feedback"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["voice-mic"].firstMatch.exists)
    }

    @MainActor
    func testReagreeFromOfflineRestoresOnlineFeatures() {
        let app = launchPrivacyAgreementInEnglish(reset: true)
        declineAgreement(in: app)
        openProfileTab(in: app)

        let reagree = app.buttons["profile-offline-agree"]
        XCTAssertTrue(reagree.waitForExistence(timeout: 3))
        reagree.tap()

        let agree = app.buttons["privacy-agreement-agree"]
        XCTAssertTrue(agree.waitForExistence(timeout: 5))
        agree.tap()

        waitForDisappearance(of: app.buttons["privacy-agreement-agree"])
        XCTAssertTrue(app.buttons["profile-sign-in"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["profile-offline-agree"].exists)
    }

    /// 在同意卡上点「不同意」，并等同意卡消失。
    ///
    /// - Parameter app: 已启动的应用。
    @MainActor
    private func declineAgreement(in app: XCUIApplication) {
        let decline = app.buttons["privacy-agreement-decline"]
        XCTAssertTrue(decline.waitForExistence(timeout: 5))
        decline.tap()
        waitForDisappearance(of: app.buttons["privacy-agreement-decline"])
    }

    /// 切到「我的」Tab，并等页头出现。
    ///
    /// - Parameter app: 已启动的应用。
    @MainActor
    private func openProfileTab(in app: XCUIApplication) {
        let profileTab = app.tabBars.buttons["Profile"]
        XCTAssertTrue(profileTab.waitForExistence(timeout: 5))
        profileTab.tap()
        XCTAssertTrue(app.staticTexts["profile-user-name"].waitForExistence(timeout: 3))
    }

    /// 等元素从界面上消失。
    ///
    /// - Parameter element: 要消失的元素。
    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 5) {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        wait(for: [gone], timeout: timeout)
    }
}
