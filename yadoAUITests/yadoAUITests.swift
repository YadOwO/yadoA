//
//  yadoAUITests.swift
//  yadoAUITests
//
//  Created by webull_yado on 2026/8/12.
//

import XCTest

final class yadoAUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testInvalidFormCannotSaveAndBackKeepsCreationOpen() throws {
        let app = launchIsolatedAppInEnglish()
        let addAccountButton = app.buttons["account-list-empty-add"]
        XCTAssertTrue(addAccountButton.waitForExistence(timeout: 3))
        addAccountButton.tap()

        let cashType = app.descendants(matching: .any)["account-creation-type-cash"]
        XCTAssertTrue(cashType.waitForExistence(timeout: 3))
        cashType.tap()

        let saveButton = app.buttons["account-creation-save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 2))
        XCTAssertFalse(saveButton.isEnabled)

        let amountField = app.textFields["account-creation-amount"]
        XCTAssertTrue(amountField.waitForExistence(timeout: 2))
        amountField.tap()
        amountField.typeText("40")
        XCTAssertTrue(saveButton.isEnabled)

        app.navigationBars.buttons["Add Account"].tap()
        XCTAssertTrue(cashType.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["account-creation-cancel"].exists)
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            launchIsolatedAppInEnglish()
        }
    }
}
