import XCTest

/// 验证账户管理中的导出入口与敏感信息确认门。
final class AccountManagementExportUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testExportEntryShowsWarningAndCancelLeavesManagementUnchanged() throws {
        let app = launchExportFixtureInEnglish()
        openAccountsTab(in: app)

        let management = app.buttons["account-list-management"]
        XCTAssertTrue(management.waitForExistence(timeout: 3))
        management.tap()

        let export = app.buttons["account-management-export-data"]
        XCTAssertTrue(export.waitForExistence(timeout: 3))
        export.tap()

        let confirm = app.buttons["account-management-export-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["account-management-export-cancel"].exists)
        XCTAssertTrue(app.staticTexts["Export your data?"].exists)

        app.buttons["account-management-export-cancel"].tap()

        XCTAssertTrue(export.waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["account-management-export-confirm"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(app.buttons["Save to Files"].exists)
    }
}
