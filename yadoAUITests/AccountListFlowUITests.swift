import XCTest

final class AccountListFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEmptyStateCreatesFirstAccountAndMovesAddActionToToolbar() throws {
        let app = launchIsolatedAppInEnglish()
        openAccountsTab(in: app)

        let emptyAdd = app.buttons["account-list-empty-add"]
        XCTAssertTrue(emptyAdd.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["account-list-toolbar-add"].exists)
        emptyAdd.tap()

        let cashType = app.descendants(matching: .any)["account-creation-type-cash"]
        XCTAssertTrue(cashType.waitForExistence(timeout: 3))
        cashType.tap()

        let amount = app.textFields["account-creation-amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 2))
        amount.tap()
        amount.typeText("40")

        let save = app.buttons["account-creation-save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()

        XCTAssertTrue(app.staticTexts["Cash"].waitForExistence(timeout: 3))
        XCTAssertFalse(emptyAdd.exists)
        XCTAssertTrue(app.buttons["account-list-toolbar-add"].waitForExistence(timeout: 2))

        let summaryCard = app.descendants(matching: .any)["account-list-summary-card"]
        XCTAssertTrue(summaryCard.waitForExistence(timeout: 2))
        XCTAssertFalse(summaryCard.label.isEmpty)
        XCTAssertTrue(summaryCard.label.contains("40"))

        // 系统菜单保留操作标题，但不会保留 SwiftUI 按钮的 identifier。
        let management = app.buttons["Account Management"]
        if !management.exists {
            app.navigationBars["Accounts"].buttons["More"].tap()
        }
        XCTAssertTrue(management.waitForExistence(timeout: 2))
        management.tap()
        XCTAssertTrue(app.buttons["account-management-choose-default"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["account-management-deactivated"].exists)
        app.buttons["account-management-close"].tap()

        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.tabBars.firstMatch.isHittable)
        app.staticTexts["Cash"].firstMatch.tap()

        XCTAssertTrue(app.navigationBars["Account Details"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.tabBars.firstMatch.waitForNonExistence(timeout: 3),
            "进入账户详情后不应继续展示 Tab Bar"
        )
        XCTAssertEqual(app.staticTexts["account-detail-name"].label, "Cash")
        // 账户资料按需展开，余额和调整入口优先保持在首屏。
        let information = app.buttons["Account Information"]
        XCTAssertTrue(information.waitForExistence(timeout: 2))
        information.tap()
        XCTAssertEqual(app.staticTexts["account-detail-type"].label, "Type, Cash")
        information.tap()

        let detailAmount = app.staticTexts["account-detail-amount"]
        XCTAssertTrue(detailAmount.waitForExistence(timeout: 2))
        XCTAssertTrue(detailAmount.label.contains("40"))
        XCTAssertTrue(detailAmount.label.contains("¥"))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Account balance overview"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.buttons["account-detail-adjust-balance"].tap()
        XCTAssertTrue(app.textFields["balance-adjustment-target"].waitForExistence(timeout: 2))
        app.buttons["balance-adjustment-cancel"].tap()
        XCTAssertTrue(detailAmount.waitForExistence(timeout: 2))

        app.navigationBars["Account Details"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(app.tabBars.buttons.count, 4)
    }
}
