import XCTest

/// 分类管理：新增自定义分类、删除分类（迁移或一并删除流水），以及记账面板里的联动。
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
        XCTAssertTrue(name.waitForNonExistence(timeout: 3))
        // 新分类追加在列表末尾，预置分类较多时在首屏之外，需要先滚下去。
        let createdRow = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'category-row-custom.' AND label CONTAINS 'Coffee'")
        ).firstMatch
        XCTAssertTrue(scroll(to: createdRow, in: app.collectionViews.firstMatch, by: { $0.swipeUp() }))

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

    /// 没有流水的预置分类：左滑只有「删除」，二次确认后直接消失。
    @MainActor
    func testDeletingPresetWithoutEntriesConfirmsOnce() throws {
        let app = launchHomeFixtureInEnglish()
        openCategoryManagement(in: app)

        // 预置分类不可编辑，行不是按钮；「购物」排在第二位且夹具里没有流水，始终在首屏内。
        let shopping = app.descendants(matching: .any)["category-row-shopping"]
        XCTAssertTrue(shopping.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["category-row-shopping"].exists, "预置分类不应进入编辑页")
        shopping.swipeLeft()
        XCTAssertFalse(app.buttons["Hide"].exists, "不再提供隐藏")
        app.buttons["Delete"].tap()

        let confirm = app.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertTrue(shopping.waitForNonExistence(timeout: 3))
    }

    /// 左滑点「删除」后在确认框取消，分类仍留在列表里。
    @MainActor
    func testCancellingDeletionKeepsCategory() throws {
        let app = launchHomeFixtureInEnglish()
        openCategoryManagement(in: app)

        let shopping = app.descendants(matching: .any)["category-row-shopping"]
        XCTAssertTrue(shopping.waitForExistence(timeout: 3))
        shopping.swipeLeft()
        app.buttons["Delete"].tap()

        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 3))
        XCTAssertTrue(shopping.exists, "取消确认后分类不应从列表消失")
    }

    /// 有流水的分类：删除页默认迁移，可改为一并删除流水，再确认一次后删除。
    @MainActor
    func testDeletingCategoryWithEntriesCanDeleteEntries() throws {
        let app = launchHomeFixtureInEnglish()
        openCategoryManagement(in: app)

        let dining = app.descendants(matching: .any)["category-row-dining"]
        XCTAssertTrue(dining.waitForExistence(timeout: 3))
        dining.swipeLeft()
        app.buttons["Delete"].tap()

        let migrate = app.buttons["category-delete-option-migrate"]
        XCTAssertTrue(migrate.waitForExistence(timeout: 3))
        XCTAssertTrue(migrate.isSelected, "默认迁移流水")
        // 删除页是半屏弹层，「其他」排在目标列表末尾不在可视区，只确认迁移目标分组出现即可。
        let migrationTarget = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'category-migration-target-'")
        ).firstMatch
        XCTAssertTrue(migrationTarget.exists)

        app.buttons["category-delete-option-delete"].tap()
        XCTAssertTrue(migrationTarget.waitForNonExistence(timeout: 3))
        app.buttons["category-delete-confirm"].tap()

        let confirm = app.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertTrue(dining.waitForNonExistence(timeout: 3))
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
