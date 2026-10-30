import XCTest

/// 记账页搜索入口、实时搜索、时间筛选和只读详情的 UI 自动化覆盖。
final class BookkeepingSearchFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testHomeSearchEntryOpensSearchPage() throws {
        let app = launchBookkeepingSearchFixtureInEnglish()

        XCTAssertEqual(app.tabBars.buttons.count, 4)
        openSearch(in: app)
        XCTAssertTrue(app.staticTexts["Recent categories"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["bookkeeping-search-type-expense"].exists)
        XCTAssertTrue(app.buttons["bookkeeping-search-preset-thisMonth"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Search landing"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// 点击真实类别建议应直接展示结果，无需输入或提交搜索词。
    @MainActor
    func testCategorySuggestionStartsSearch() throws {
        let app = launchBookkeepingSearchFixtureInEnglish()
        openSearch(in: app)
        let suggestion = app.buttons["bookkeeping-search-suggestion-Dining"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 3))
        suggestion.tap()
        let result = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'bookkeeping-search-result-'")
        ).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 3))
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "Dining")
    }

    /// 无结果时应显示输入内容，清除日期筛选不能丢失关键词。
    @MainActor
    func testNoResultsCanClearDateFilterWithoutClearingQuery() throws {
        let app = launchBookkeepingSearchFixtureInEnglish()
        openSearch(in: app)
        dateFilterButton(in: app).tap()
        app.buttons["bookkeeping-search-filter-confirm"].tap()
        let searchField = app.searchFields.firstMatch
        searchField.tap()
        searchField.typeText("missing entry")
        XCTAssertTrue(app.staticTexts["No entries match “missing entry”."].waitForExistence(timeout: 3))
        let clearFilter = app.buttons["bookkeeping-search-empty-range-clear"]
        XCTAssertTrue(clearFilter.waitForExistence(timeout: 3))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Search no results with date filter"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        clearFilter.tap()
        XCTAssertTrue(clearFilter.waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.buttons["bookkeeping-search-filter"].value as? String, "Any time")
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "missing entry")
        XCTAssertTrue(app.staticTexts["No entries match “missing entry”."].exists)
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
        dateFilterButton(in: app).tap()

        XCTAssertTrue(app.navigationBars["Date Filter"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["bookkeeping-search-filter-confirm"].exists)
        XCTAssertTrue(app.buttons["bookkeeping-search-filter-cancel"].exists)
        app.buttons["bookkeeping-search-filter-cancel"].tap()

        let filterButton = dateFilterButton(in: app)
        XCTAssertEqual(filterButton.value as? String, "Any time")
        filterButton.tap()
        XCTAssertTrue(app.datePickers["bookkeeping-search-filter-start"].exists)
        XCTAssertTrue(app.datePickers["bookkeeping-search-filter-end"].exists)
        app.buttons["bookkeeping-search-filter-confirm"].tap()

        XCTAssertNotEqual(app.buttons["bookkeeping-search-filter"].value as? String, "Any time")
        dateFilterButton(in: app).tap()
        app.buttons["bookkeeping-search-filter-clear"].tap()
        XCTAssertTrue(app.staticTexts["Recent categories"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["bookkeeping-search-filter"].value as? String, "Any time")
    }

    /// 筛选标签点一下选中并直接出结果，再点一下取消并回到初始页。
    @MainActor
    func testFilterChipsToggleResults() throws {
        let app = launchBookkeepingSearchFixtureInEnglish()
        openSearch(in: app)

        let expense = app.buttons["bookkeeping-search-type-expense"]
        XCTAssertTrue(expense.waitForExistence(timeout: 3))
        expense.tap()
        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH 'bookkeeping-search-result-'")
            ).firstMatch.waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.staticTexts["bookkeeping-search-summary"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Search results with type filter"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        expense.tap()
        XCTAssertTrue(app.staticTexts["Recent categories"].waitForExistence(timeout: 3))
    }

    /// 点开过结果的关键词会出现在最近搜索里，点一下即可再次搜索，也可以整体清除。
    @MainActor
    func testOpenedQueryAppearsInRecentSearches() throws {
        let app = launchBookkeepingSearchFixtureInEnglish()
        openSearch(in: app)

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))
        searchField.tap()
        searchField.typeText("Archived meal")
        let result = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'bookkeeping-search-result-'")
        ).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 3))
        result.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let field = app.searchFields.firstMatch
        field.tap()
        field.buttons["Clear text"].tap()
        let recent = app.buttons["bookkeeping-search-recent-Archived meal"]
        XCTAssertTrue(recent.waitForExistence(timeout: 3))
        recent.tap()
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "Archived meal")

        app.searchFields.firstMatch.buttons["Clear text"].tap()
        app.buttons["bookkeeping-search-recent-clear"].tap()
        XCTAssertTrue(recent.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testActiveDetailOpensFullEditorAndCanCancel() throws {
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
        XCTAssertTrue(app.tabBars.firstMatch.exists, "二级详情页保留 Tab Bar")
        XCTAssertFalse(
            app.searchFields.firstMatch.exists,
            "进入详情后不应继续展示搜索界面"
        )
        let edit = app.buttons["bookkeeping-detail-edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 2))
        edit.tap()
        XCTAssertTrue(app.navigationBars["Edit Transaction"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.textViews["expense-edit-note"].exists || app.textFields["expense-edit-note"].exists)
        XCTAssertFalse(app.textFields["expense-edit-title"].exists, "编辑页不再有标题输入框")
        app.buttons["expense-edit-cancel"].tap()

        // 详情返回搜索页，再返回记账页，Tab Bar 一直保留。
        app.navigationBars["Transaction Details"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Search"].waitForExistence(timeout: 3))
        app.navigationBars["Search"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(app.tabBars.buttons.count, 4)
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

    /// 「按日期筛选」排在横向筛选条末尾，窄屏上要先把筛选条左滑到它可点击。
    @MainActor
    private func dateFilterButton(in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons["bookkeeping-search-filter"]
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        let bar = app.descendants(matching: .any).matching(identifier: "bookkeeping-search-filter-bar").firstMatch
        XCTAssertTrue(scroll(to: button, in: bar, by: { $0.swipeLeft() }, maxSwipes: 3))
        return button
    }

    @MainActor
    private func openSearch(in app: XCUIApplication) {
        let searchEntry = app.buttons["home-search"]
        XCTAssertTrue(searchEntry.waitForExistence(timeout: 3))
        searchEntry.tap()
        XCTAssertTrue(app.navigationBars["Search"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.tabBars.firstMatch.exists, "搜索是记账页的二级页面，保留 Tab Bar")
    }
}
