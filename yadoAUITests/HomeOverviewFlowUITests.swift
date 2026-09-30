import XCTest

/// 首页月份选择和收支显隐的 UI 自动化覆盖。
final class HomeOverviewFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 下拉跳过空月到更晚月份，上拉返回；一轮手势只能切换一次。
    @MainActor
    func testBoundaryPullSwitchesOneMonthAndCanReturn() throws {
        let app = launchHomeFixtureInEnglish()
        let selector = app.buttons["home-month-selector"]
        XCTAssertTrue(selector.waitForExistence(timeout: 3))
        let originalMonth = selector.label
        let list = app.descendants(matching: .any)["home-details-scroll"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 3))

        let start = listCoordinate(in: app, list: list, fraction: 0.1)
        let end = listCoordinate(in: app, list: list, fraction: 0.9)
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        let nextMonth = monthLabel(offset: 3)
        XCTAssertTrue(selector.wait(for: \.label, toEqual: nextMonth, timeout: 4))

        let returnStart = listCoordinate(in: app, list: list, fraction: 0.9)
        let returnEnd = listCoordinate(in: app, list: list, fraction: 0.1)
        returnStart.press(forDuration: 0.1, thenDragTo: returnEnd, withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(selector.wait(for: \.label, toEqual: originalMonth, timeout: 4))
    }

    /// 短列表上的轻微拖动不能因为内容高度不足而误切月份。
    @MainActor
    func testSmallPullKeepsCurrentMonth() throws {
        let app = launchHomeFixtureInEnglish()
        let selector = app.buttons["home-month-selector"]
        XCTAssertTrue(selector.waitForExistence(timeout: 3))
        let originalMonth = selector.label
        let list = app.descendants(matching: .any)["home-details-scroll"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 3))
        let start = listCoordinate(in: app, list: list, fraction: 0.5)
        let end = start.withOffset(CGVector(dx: 0, dy: -35))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", originalMonth),
            object: selector
        )
        changed.isInverted = true
        wait(for: [changed], timeout: 2)
    }

    /// List 的辅助功能边框包含底部安全区，手势只能从记账按钮上方的可见明细区域开始。
    @MainActor
    private func listCoordinate(in app: XCUIApplication, list: XCUIElement, fraction: CGFloat) -> XCUICoordinate {
        let frame = list.frame
        let top = frame.minY + 12
        let bottom = min(frame.maxY, app.buttons["home-add-expense"].frame.minY - 20)
        return list.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: frame.width * 0.5, dy: top - frame.minY + (bottom - top) * fraction)
        )
    }

    /// 与英文夹具一致的当前月偏移标题，包含月份按钮的辅助功能前缀。
    private func monthLabel(offset: Int) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(byAdding: .month, value: offset, to: Date())!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return "Selected month, \(formatter.string(from: date))"
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
    func testTransactionTapOpensSharedDetailAndFullEditor() throws {
        let app = launchHomeFixtureInEnglish()
        let transaction = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'home-transaction-'")
        ).firstMatch

        XCTAssertTrue(transaction.waitForExistence(timeout: 3))
        transaction.tap()

        XCTAssertTrue(app.navigationBars["Transaction Details"].waitForExistence(timeout: 3))
        app.buttons["bookkeeping-detail-edit"].tap()
        XCTAssertTrue(app.navigationBars["Edit Transaction"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["expense-edit-title"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.textFields["expense-edit-amount"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["expense-edit-save"].exists)
        XCTAssertTrue(app.datePickers["expense-edit-date"].exists)
        XCTAssertTrue(app.textViews["expense-edit-note"].exists || app.textFields["expense-edit-note"].exists)
    }

    @MainActor
    func testAddExpenseSelectsCategoryAndShowsItOnHome() throws {
        let app = launchHomeFixtureInEnglish()
        XCTAssertTrue(app.buttons["home-add-expense"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.tabBars.firstMatch.isHittable)
        app.buttons["home-add-expense"].tap()

        XCTAssertTrue(app.navigationBars["Select Category"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.tabBars.firstMatch.waitForNonExistence(timeout: 3),
            "进入记账流程后不应继续展示 Tab Bar"
        )

        let travel = app.buttons["expense-category-travel"]
        XCTAssertTrue(travel.waitForExistence(timeout: 2))
        travel.tap()

        let category = app.buttons["expense-entry-category"]
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
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(app.tabBars.buttons.count, 4)
    }

    @MainActor
    func testAddIncomeSelectsCategoryAndShowsItOnHome() throws {
        let app = launchHomeFixtureInEnglish()
        XCTAssertTrue(app.buttons["home-add-expense"].waitForExistence(timeout: 3))
        app.buttons["home-add-expense"].tap()

        XCTAssertTrue(app.navigationBars["Select Category"].waitForExistence(timeout: 3))
        let income = app.segmentedControls["bookkeeping-category-entry-type"].buttons["Income"]
        XCTAssertTrue(income.waitForExistence(timeout: 2))
        income.tap()

        XCTAssertTrue(app.navigationBars["Select Income Category"].waitForExistence(timeout: 2))
        let salary = app.buttons["income-category-salary"]
        XCTAssertTrue(salary.waitForExistence(timeout: 2))
        salary.tap()

        app.buttons["expense-entry-account"].tap()
        let account = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'expense-account-selection-row-'")
        ).firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 2))
        account.tap()

        let amount = app.textFields["expense-entry-amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 2))
        amount.tap()
        amount.typeText("500")

        let save = app.buttons["expense-entry-save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()

        XCTAssertTrue(app.staticTexts["Salary"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 3))
    }

    @MainActor
    func testAddExpenseCannotSaveAfterCancellingInitialCategorySelection() throws {
        let app = launchHomeFixtureInEnglish()
        XCTAssertTrue(app.buttons["home-add-expense"].waitForExistence(timeout: 3))
        app.buttons["home-add-expense"].tap()

        XCTAssertTrue(app.navigationBars["Select Category"].waitForExistence(timeout: 3))
        app.buttons["Cancel"].tap()

        XCTAssertTrue(app.buttons["expense-entry-category"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["expense-entry-save"].isEnabled)
    }
}
