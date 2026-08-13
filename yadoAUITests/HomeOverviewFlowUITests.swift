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
}
