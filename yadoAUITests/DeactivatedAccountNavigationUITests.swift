import XCTest

/// 验证设置中的停用账户列表只压入对应详情，返回后仍停留在原列表。
final class DeactivatedAccountNavigationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testProfileArchivedAccountOpensDetailsAndReturnsToOriginalList() throws {
        let app = launchExportFixtureInEnglish()

        let profile = app.buttons["home-profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        profile.tap()
        app.staticTexts["Deactivated accounts"].tap()

        let account = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "deactivated-account-row-")
        ).firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 3))
        account.tap()

        XCTAssertTrue(app.navigationBars["Account Details"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["account-detail-name"].label, "Export archived account")
        XCTAssertTrue(app.buttons["account-detail-restore"].exists)

        app.navigationBars["Account Details"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(account.waitForExistence(timeout: 3))
        app.navigationBars["Deactivated accounts"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["profile-default-account"].waitForExistence(timeout: 3))
    }
}
