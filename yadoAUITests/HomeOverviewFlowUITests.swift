import XCTest

/// 首页月份选择和收支显隐的 UI 自动化覆盖。
final class HomeOverviewFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFixtureShowsHomeDataAndMonthPickerCanCancel() throws {
        let app = launchHomeFixtureInEnglish()

        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["home-month-selector"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["home-summary-visibility"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["home-add-expense"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.otherElements["home-details-empty"].exists)

        app.buttons["home-month-selector"].tap()
        XCTAssertTrue(app.navigationBars["Select Month"].waitForExistence(timeout: 3))

        let cancel = app.buttons["home-month-picker-cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 2))
        cancel.tap()
        XCTAssertTrue(app.buttons["home-month-selector"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testSummaryVisibilityTogglesWithoutChangingHomeStructure() throws {
        let app = launchHomeFixtureInEnglish()
        let visibility = app.buttons["home-summary-visibility"]
        XCTAssertTrue(visibility.waitForExistence(timeout: 3))
        let expense = app.staticTexts["home-summary-expense"]
        XCTAssertTrue(expense.waitForExistence(timeout: 2))
        let hiddenValue = expense.value as? String
        XCTAssertFalse(hiddenValue?.contains("48.71") == true)

        visibility.tap()

        let visibleValue = NSPredicate(format: "value CONTAINS %@", "48.71")
        let visibleExpectation = XCTNSPredicateExpectation(
            predicate: visibleValue,
            object: expense
        )
        wait(for: [visibleExpectation], timeout: 3)
        XCTAssertTrue(app.buttons["home-month-selector"].exists)
    }

    @MainActor
    func testTransactionTapOpensQuickEditForTitleAndAmount() throws {
        let app = launchHomeFixtureInEnglish()
        let transaction = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'home-transaction-'")
        ).firstMatch

        XCTAssertTrue(transaction.waitForExistence(timeout: 3))
        transaction.tap()

        XCTAssertTrue(app.navigationBars["Edit Expense"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["expense-edit-title"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.textFields["expense-edit-amount"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["expense-edit-save"].exists)
    }

    @MainActor
    func testAddExpenseSelectsCategoryAndShowsItOnHome() throws {
        let app = launchHomeFixtureInEnglish()
        XCTAssertTrue(app.buttons["home-add-expense"].waitForExistence(timeout: 3))
        app.buttons["home-add-expense"].tap()

        let category = app.buttons["expense-entry-category"]
        XCTAssertTrue(category.waitForExistence(timeout: 3))
        category.tap()
        XCTAssertTrue(app.navigationBars["Select Category"].waitForExistence(timeout: 2))

        let travel = app.buttons["expense-category-travel"]
        XCTAssertTrue(travel.waitForExistence(timeout: 2))
        travel.tap()
        XCTAssertTrue(category.waitForExistence(timeout: 2))

        app.buttons["expense-entry-account"].tap()
        let account = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'expense-account-selection-row-'")
        ).firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 2))
        account.tap()

        let amount = app.textFields["expense-entry-amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 2))
        amount.tap()
        amount.typeText("12.34")

        let save = app.buttons["expense-entry-save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()

        XCTAssertTrue(app.staticTexts["Travel"].waitForExistence(timeout: 3))
    }
}
