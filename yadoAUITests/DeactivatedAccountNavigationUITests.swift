import XCTest

/// 验证账户管理中的停用账户列表只压入对应详情，返回后仍停留在原列表。
final class DeactivatedAccountNavigationUITests: XCTestCase {
    /// 账户管理弹层中的停用账户流水可以打开详情并返回原账户。
    @MainActor
    func testManagementArchivedTransactionOpensAndReturns() throws {
        let app = launchBookkeepingSearchFixtureInEnglish()
        openDeactivatedAccountsFromManagement(in: app)
        assertArchivedTransactionNavigation(in: app)
    }

    /// 从“账户”Tab 打开账户管理弹层，再进入停用账户列表。
    @MainActor
    private func openDeactivatedAccountsFromManagement(in app: XCUIApplication) {
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
    func testManagementArchivedAccountOpensDetailsAndReturnsToOriginalList() throws {
        let app = launchExportFixtureInEnglish()

        openDeactivatedAccountsFromManagement(in: app)

        let account = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "deactivated-account-row-")
        ).firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 3))
        account.tap()

        XCTAssertTrue(app.navigationBars["Account Details"].waitForExistence(timeout: 3))
        // 信用卡名称不可编辑，界面显示机构模板名（夹具用的是花呗），不显示存储里的自定义名。
        XCTAssertEqual(app.staticTexts["account-detail-name"].label, "Huabei")
        XCTAssertTrue(app.buttons["account-detail-restore"].exists)

        app.navigationBars["Account Details"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(account.waitForExistence(timeout: 3))
        app.navigationBars["Deactivated accounts"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["account-management-deactivated"].waitForExistence(timeout: 3))
    }
}
