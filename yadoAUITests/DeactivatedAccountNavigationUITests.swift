import XCTest

/// 验证设置中的停用账户列表只压入对应详情，返回后仍停留在原列表。
final class DeactivatedAccountNavigationUITests: XCTestCase {
    /// 设置弹层中的停用账户流水可以打开详情并返回原账户。
    @MainActor
    func testProfileArchivedTransactionOpensAndReturns() throws {
        let app = launchBookkeepingSearchFixtureInEnglish()
        let profile = app.buttons["home-profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        profile.tap()
        app.staticTexts["Deactivated accounts"].tap()
        assertArchivedTransactionNavigation(in: app)
    }

    /// 账户管理弹层应提供与设置入口相同的流水导航。
    @MainActor
    func testManagementArchivedTransactionOpensAndReturns() throws {
        let app = launchBookkeepingSearchFixtureInEnglish()
        openAccountsTab(in: app)
        var management = app.buttons["account-list-management"]
        // 新系统会把 secondaryAction 收入工具栏的“更多”菜单。
        if !management.exists {
            app.buttons["OverflowBarButtonItem"].tap()
            management = app.buttons["Account Management"]
        }
        XCTAssertTrue(management.waitForExistence(timeout: 3))
        management.tap()
        app.buttons["account-management-deactivated"].tap()
        assertArchivedTransactionNavigation(in: app)
    }

    /// 验证流水详情出现且返回后仍保留停用账户详情。
    @MainActor
    private func assertArchivedTransactionNavigation(in app: XCUIApplication) {
        let account = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "deactivated-account-row-")
        ).firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 3))
        account.tap()
        let transaction = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "account-transaction-detail-")
        ).firstMatch
        XCTAssertTrue(transaction.waitForExistence(timeout: 3))
        transaction.tap()
        XCTAssertTrue(app.navigationBars["Transaction Details"].waitForExistence(timeout: 3))
        app.navigationBars["Transaction Details"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Account Details"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["account-detail-name"].label, "Search inactive account")
    }

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
