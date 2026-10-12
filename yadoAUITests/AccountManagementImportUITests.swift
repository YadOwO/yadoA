import XCTest

/// 验证账户管理中的备份恢复入口、替换确认门与恢复后的列表刷新。
final class AccountManagementImportUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testRestoreRequiresConfirmationThenReplacesExistingAccounts() throws {
        let app = launchImportFixtureInEnglish()
        openAccountsTab(in: app)
        XCTAssertTrue(app.staticTexts["Export active account"].waitForExistence(timeout: 3))

        let management = app.buttons["account-list-management"]
        XCTAssertTrue(management.waitForExistence(timeout: 3))
        management.tap()

        let restore = app.buttons["account-management-import-data"]
        XCTAssertTrue(restore.waitForExistence(timeout: 3))

        // 取消确认不应修改数据。
        restore.tap()
        XCTAssertTrue(app.alerts["Restore this backup?"].waitForExistence(timeout: 3))
        app.buttons["account-management-import-cancel"].tap()
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 1))

        restore.tap()
        let confirm = app.buttons["account-management-import-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()

        XCTAssertTrue(app.alerts["Backup restored"].waitForExistence(timeout: 3))
        app.buttons["account-management-import-done"].tap()

        app.buttons["account-management-close"].tap()
        XCTAssertTrue(app.staticTexts["Restored account"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Export active account"].exists)
    }
}
