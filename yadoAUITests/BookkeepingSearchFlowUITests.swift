import XCTest

/// 根级搜索入口、实时搜索、时间筛选和只读详情的 UI 自动化覆盖。
final class BookkeepingSearchFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSearchTabOpensSearchPage() throws {
        let app = launchBookkeepingSearchFixtureInEnglish()

        XCTAssertEqual(app.tabBars.buttons.count, 4)
        openSearch(in: app)
        XCTAssertTrue(app.staticTexts["Search your bookkeeping"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testSearchUpdatesWithoutSubmitAndSeparatesNoResultsState() throws {
        let app = launchBookkeepingSearchFixtureInEnglish()
        openSearch(in: app)

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))
        searchField.tap()
        searchField.typeText("火锅")

        let result = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'bookkeeping-search-result-'")
        ).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 3))

        searchField.buttons["Clear text"].tap()
        searchField.typeText("no matching bookkeeping")
        XCTAssertTrue(app.staticTexts["No matching entries"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testTimeFilterCanCancelAndApplyClosedRange() throws {
        let app = launchBookkeepingSearchFixtureInEnglish()
        openSearch(in: app)
        app.buttons["bookkeeping-search-filter"].tap()

        XCTAssertTrue(app.navigationBars["Date Filter"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["bookkeeping-search-filter-confirm"].exists)
        XCTAssertTrue(app.buttons["bookkeeping-search-filter-cancel"].exists)
        app.buttons["bookkeeping-search-filter-cancel"].tap()

        let filterButton = app.buttons["bookkeeping-search-filter"]
        XCTAssertTrue(filterButton.waitForExistence(timeout: 2))
        XCTAssertEqual(filterButton.value as? String, "Any time")
        app.buttons["bookkeeping-search-filter"].tap()
        app.segmentedControls.buttons["Custom range"].tap()
        XCTAssertTrue(app.datePickers["bookkeeping-search-filter-start"].exists)
        XCTAssertTrue(app.datePickers["bookkeeping-search-filter-end"].exists)
        app.buttons["bookkeeping-search-filter-confirm"].tap()

        XCTAssertTrue(app.otherElements["bookkeeping-search-applied-range"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["bookkeeping-search-range-clear"].exists)
        app.buttons["bookkeeping-search-range-clear"].tap()
        XCTAssertTrue(app.staticTexts["Search your bookkeeping"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testActiveDetailOffersNonWritingEditPlaceholder() throws {
        let app = launchBookkeepingSearchFixtureInEnglish()
        openSearch(in: app)

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))
        searchField.tap()
        searchField.typeText("火锅")

        let result = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'bookkeeping-search-result-'")
        ).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 3))
        result.tap()

        XCTAssertTrue(app.navigationBars["Transaction Details"].waitForExistence(timeout: 3))
        XCTAssertFalse(
            app.searchFields.firstMatch.exists,
            "进入详情后不应继续展示搜索界面"
        )
        let edit = app.buttons["bookkeeping-detail-edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 2))
        edit.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 2))
    }

    @MainActor
    func testDeactivatedAndOrphanAccountsRemainReadOnlyResults() throws {
        let app = launchBookkeepingSearchFixtureInEnglish()
        openSearch(in: app)

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))
        searchField.tap()
        searchField.typeText("Archived meal")
        let inactiveResult = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'bookkeeping-search-result-'")
        ).firstMatch
        XCTAssertTrue(inactiveResult.waitForExistence(timeout: 3))
        inactiveResult.tap()
        XCTAssertFalse(app.buttons["bookkeeping-detail-edit"].exists)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        let field = app.searchFields.firstMatch
        field.tap()
        field.buttons["Clear text"].tap()
        field.typeText("Orphan meal")
        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH 'bookkeeping-search-result-'")
            ).firstMatch.waitForExistence(timeout: 3)
        )
    }

    @MainActor
    private func openSearch(in app: XCUIApplication) {
        let searchTab = app.tabBars.buttons["Search"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 3))
        searchTab.tap()
        XCTAssertTrue(app.navigationBars["Search"].waitForExistence(timeout: 3))
    }
}
