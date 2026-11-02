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
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(scroll(to: createdRow, in: list, by: { $0.swipeUp() }))
        // 向下滚动会把 Tab Bar 收起成只剩当前 Tab，滚回顶部让它展开，再按名称切到记账页。
        list.swipeDown()
        list.swipeDown()

        app.navigationBars.buttons.element(boundBy: 0).tap()
        let ledgerTab = app.tabBars.buttons["Ledger"]
        XCTAssertTrue(ledgerTab.waitForExistence(timeout: 3))
        ledgerTab.tap()
        XCTAssertTrue(app.navigationBars["Ledger"].waitForExistence(timeout: 3))
        app.buttons["home-add-expense"].tap()
        // 夹具里已有支出，预选了最近分类，不再自动弹面板
        let entryCategory = app.buttons["expense-entry-category"]
        XCTAssertTrue(entryCategory.waitForExistence(timeout: 3))
        entryCategory.tap()
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
        let deleteAction = revealDeleteAction(on: shopping, in: app)
        XCTAssertFalse(app.buttons["Hide"].exists, "不再提供隐藏")
        deleteAction.tap()

        let confirm = app.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertTrue(shopping.waitForNonExistence(timeout: 3))
    }

    /// 左滑点「删除」后关闭确认框不删除，分类仍留在列表里。
    @MainActor
    func testCancellingDeletionKeepsCategory() throws {
        let app = launchHomeFixtureInEnglish()
        openCategoryManagement(in: app)

        let shopping = app.descendants(matching: .any)["category-row-shopping"]
        XCTAssertTrue(shopping.waitForExistence(timeout: 3))
        revealDeleteAction(on: shopping, in: app).tap()

        let dialog = app.sheets.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 3))
        dismissConfirmationDialog(dialog, in: app)
        XCTAssertTrue(dialog.waitForNonExistence(timeout: 3))
        XCTAssertTrue(shopping.exists, "取消确认后分类不应从列表消失")
    }

    /// 有流水的分类：删除页默认迁移，可改为一并删除流水，再确认一次后删除。
    @MainActor
    func testDeletingCategoryWithEntriesCanDeleteEntries() throws {
        let app = launchHomeFixtureInEnglish()
        openCategoryManagement(in: app)

        let dining = app.descendants(matching: .any)["category-row-dining"]
        XCTAssertTrue(dining.waitForExistence(timeout: 3))
        revealDeleteAction(on: dining, in: app).tap()

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

    /// 左滑分类行，等滑出的「删除」按钮停稳后返回它。
    ///
    /// 滑出动画还没结束就点击，点击会被列表吞掉，确认框不会弹出；位置连续两次读取一致才算停稳。
    @MainActor
    private func revealDeleteAction(on row: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        row.swipeLeft()
        let action = app.buttons["Delete"]
        XCTAssertTrue(action.waitForExistence(timeout: 3))
        var frame = action.frame
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.15)
            let current = action.frame
            if current == frame { break }
            frame = current
        }
        return action
    }

    /// 不执行任何操作，关闭确认框。
    ///
    /// iOS 18 的确认框是底部操作表，带「取消」按钮；iOS 26 起 iPhone 上改为锚定来源的弹出框，
    /// 系统不再显示 `.cancel` 角色的按钮，只能点框外关闭。此时点在框上下两侧较大空白区的中间，避开框本身。
    @MainActor
    private func dismissConfirmationDialog(_ dialog: XCUIElement, in app: XCUIApplication) {
        let cancel = app.buttons["Cancel"]
        if cancel.exists {
            cancel.tap()
            return
        }
        let screen = app.frame
        let box = dialog.frame
        let y = box.minY - screen.minY > screen.maxY - box.maxY
            ? (screen.minY + box.minY) / 2
            : (box.maxY + screen.maxY) / 2
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: screen.midX, dy: y))
            .tap()
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
