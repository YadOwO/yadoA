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

        app.staticTexts["Cash"].firstMatch.tap()

        XCTAssertTrue(app.navigationBars["Account Details"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["account-detail-name"].label, "Cash")
        XCTAssertEqual(app.staticTexts["account-detail-type"].label, "Type, Cash")

        let detailAmount = app.staticTexts["account-detail-amount"]
        XCTAssertTrue(detailAmount.waitForExistence(timeout: 2))
        XCTAssertTrue(detailAmount.label.contains("40"))
        XCTAssertTrue(detailAmount.label.contains("¥"))
    }
}
