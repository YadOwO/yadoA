import XCTest

/// 分类管理：新增自定义分类、隐藏预置分类，以及记账面板里的联动。
final class CategoryManagementFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 从「我的」新增一个自定义分类后，记账面板末尾出现它。
    @MainActor
    func testCreatedCategoryAppearsInEntryPicker() throws {
        let app = launchHomeFixtureInEnglish()
        openCategoryManagement(in: app)

        app.buttons["category-management-add"].tap()
        let name = app.textFields["category-edit-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["category-edit-save"].isEnabled, "未填写名称和图标时不能保存")
        name.tap()
        name.typeText("Coffee")

        app.buttons["category-edit-symbol"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("coffee")
        let symbol = app.buttons["category-symbol-cup.and.saucer"]
        XCTAssertTrue(symbol.waitForExistence(timeout: 3))
        symbol.tap()

        let save = app.buttons["category-edit-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.staticTexts["Coffee"].waitForExistence(timeout: 3))

        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons.element(boundBy: 0).tap()
        app.buttons["home-add-expense"].tap()
        XCTAssertTrue(app.navigationBars["Select Category"].waitForExistence(timeout: 3))
        let created = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'expense-category-custom.'")
        ).firstMatch
        XCTAssertTrue(created.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["expense-category-manage"].exists)
    }

    /// 同名分类在输入时就提示并禁用保存。
    @MainActor
    func testDuplicateNameIsReportedWhileTyping() throws {
        let app = launchHomeFixtureInEnglish()
        openCategoryManagement(in: app)

        app.buttons["category-management-add"].tap()
        let name = app.textFields["category-edit-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        name.typeText("Travel")

        XCTAssertTrue(app.staticTexts["category-edit-name-issue"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["category-edit-save"].isEnabled)
    }

    /// 预置分类左滑只有「隐藏」，隐藏后移入「已隐藏」区并可恢复。
    @MainActor
    func testHidingPresetMovesItToHiddenSection() throws {
        let app = launchHomeFixtureInEnglish()
        openCategoryManagement(in: app)

        let pets = app.buttons["category-row-pets"]
        XCTAssertTrue(pets.waitForExistence(timeout: 3))
        pets.swipeLeft()
        XCTAssertFalse(app.buttons["Delete"].exists, "预置分类不应提供删除")
        app.buttons["Hide"].tap()

        let restore = app.buttons["category-unhide-pets"]
        XCTAssertTrue(restore.waitForExistence(timeout: 3))
        restore.tap()
        XCTAssertTrue(restore.waitForNonExistence(timeout: 3))
    }

    /// 打开「我的 › 分类管理」。
    @MainActor
    private func openCategoryManagement(in app: XCUIApplication) {
        let profile = app.tabBars.buttons["Profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        profile.tap()
        let entry = app.buttons["profile-category-management"]
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        entry.tap()
        XCTAssertTrue(app.navigationBars["Categories"].waitForExistence(timeout: 3))
    }
}
