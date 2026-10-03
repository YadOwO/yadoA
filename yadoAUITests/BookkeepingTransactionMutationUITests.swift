import XCTest

/// 用真实页面验证编辑、删除确认及三个详情入口的一致性。
final class BookkeepingTransactionMutationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSearchEditChangesAccountAndRefreshesDetail() throws {
        let app = launchBookkeepingSearchFixtureInEnglish()
        openSearchFixtureDetail(in: app)
        capture(app, name: "Transaction receipt")
        app.buttons["bookkeeping-detail-edit"].tap()
        XCTAssertTrue(app.navigationBars["Edit Transaction"].waitForExistence(timeout: 3))
        capture(app, name: "Full transaction editor")

        replaceText(app.textFields["expense-edit-title"], with: "Unsaved draft")
        app.buttons["expense-edit-cancel"].tap()
        let discard = app.buttons["Discard Changes"]
        XCTAssertTrue(discard.waitForExistence(timeout: 3))
        discard.tap()
        XCTAssertTrue(app.navigationBars["Edit Transaction"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["bookkeeping-detail-title"].label.contains("Search legacy title"))
        app.buttons["bookkeeping-detail-edit"].tap()
        XCTAssertTrue(app.segmentedControls["expense-edit-type"].waitForExistence(timeout: 3))
        app.segmentedControls["expense-edit-type"].buttons["Income"].tap()
        app.buttons["expense-edit-category"].tap()
        app.buttons["Refund"].tap()

        replaceText(app.textFields["expense-edit-title"], with: "Corrected lunch")
        replaceText(app.textFields["expense-edit-amount"], with: "40.50")
        app.buttons["expense-edit-account"].tap()
        let target = app.buttons["Home fixture account"]
        XCTAssertTrue(target.waitForExistence(timeout: 3))
        target.tap()
        let note = app.textViews["expense-edit-note"].exists
            ? app.textViews["expense-edit-note"] : app.textFields["expense-edit-note"]
        replaceText(note, with: "Refund confirmed")
        app.datePickers["expense-edit-date"].tap()
        let day = app.staticTexts["15"].firstMatch
        XCTAssertTrue(day.waitForExistence(timeout: 3))
        day.tap()
        // 紧凑日期弹层点选后点击标题回到表单。
        app.navigationBars["Edit Transaction"].staticTexts["Edit Transaction"].tap()
        app.buttons["expense-edit-save"].tap()

        XCTAssertTrue(app.navigationBars["Transaction Details"].waitForExistence(timeout: 3))
        let title = app.staticTexts["bookkeeping-detail-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        XCTAssertEqual(title.label, "Title, Corrected lunch")
        XCTAssertTrue(app.staticTexts["bookkeeping-detail-account"].label.contains("Home fixture account"))
        XCTAssertTrue(app.staticTexts["bookkeeping-detail-amount"].label.contains("40.50"))
        XCTAssertTrue(app.staticTexts["bookkeeping-detail-category"].label.contains("Refund"))
        XCTAssertTrue(app.staticTexts["bookkeeping-detail-type"].label.contains("Income"))
        XCTAssertTrue(app.staticTexts["bookkeeping-detail-date"].label.contains("15"))
        XCTAssertEqual(app.descendants(matching: .any)["bookkeeping-detail-note"].label, "Note, Refund confirmed")
        capture(app, name: "Updated transaction detail")
        app.navigationBars["Transaction Details"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 3))
        openAccountsTab(in: app)
        app.buttons.containing(.staticText, identifier: "Search active account").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["account-detail-amount"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["account-detail-amount"].label.contains("130.00"))
    }

    @MainActor
    func testDeleteCanCancelThenRemovesSearchResult() throws {
        let app = launchBookkeepingSearchFixtureInEnglish()
        openSearchFixtureDetail(in: app)
        app.swipeUp()
        let delete = app.buttons["bookkeeping-detail-delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        let confirmation = app.alerts["Delete this transaction?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        capture(app, name: "Delete confirmation")
        confirmation.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Transaction Details"].exists)
        delete.tap()
        confirmation.buttons["Delete Transaction"].tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["No matching entries"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testAccountHistoryUsesSharedDetailAndRefreshesAfterIncomeDeletion() throws {
        let app = launchExportFixtureInEnglish()
        openAccountsTab(in: app)
        app.buttons.containing(.staticText, identifier: "Export active account").firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Account Details"].waitForExistence(timeout: 3))
        app.swipeUp()
        let income = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'account-transaction-detail-' AND label CONTAINS %@",
            "Export fixture income"
        )).firstMatch
        XCTAssertTrue(income.waitForExistence(timeout: 3))
        income.tap()
        XCTAssertTrue(app.navigationBars["Transaction Details"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["bookkeeping-detail-edit"].exists)
        app.swipeUp()
        app.buttons["bookkeeping-detail-delete"].tap()
        app.alerts["Delete this transaction?"].buttons["Delete Transaction"].tap()
        XCTAssertTrue(app.navigationBars["Account Details"].waitForExistence(timeout: 3))
        XCTAssertTrue(income.waitForNonExistence(timeout: 3))
        app.swipeDown()
        XCTAssertTrue(app.staticTexts["account-detail-amount"].label.contains("80.00"))
        let balance = app.staticTexts["account-detail-amount"].label
        XCTAssertTrue(balance.contains("-") || balance.contains("−"))
        capture(app, name: "Account after income deletion")
    }

    /// 打开只有一条匹配记录的搜索详情，避免依赖随机 UUID。
    @MainActor
    private func openSearchFixtureDetail(in app: XCUIApplication) {
        app.tabBars.buttons["Search"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("火锅")
        let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'bookkeeping-search-result-'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 3))
        result.tap()
        XCTAssertTrue(app.navigationBars["Transaction Details"].waitForExistence(timeout: 3))
    }

    /// 优先使用系统编辑菜单全选，避免新系统把 Command-A 忽略后直接插入旧内容前。
    @MainActor
    private func replaceText(_ field: XCUIElement, with text: String) {
        XCTAssertTrue(field.exists)
        field.tap()
        field.press(forDuration: 1)
        let selectAll = XCUIApplication().descendants(matching: .any)["Select All"].firstMatch
        if selectAll.waitForExistence(timeout: 2) {
            selectAll.tap()
        } else {
            field.typeKey("a", modifierFlags: .command)
        }
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text)
    }

    /// 把关键界面留在测试结果里，供视觉检查。
    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
