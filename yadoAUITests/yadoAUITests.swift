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
        openAccountsTab(in: app)
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
    func testAppStartsOnHomeAndCanSwitchToAccounts() throws {
        let app = launchIsolatedAppInEnglish()

        XCTAssertTrue(app.navigationBars["Ledger"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.otherElements["home-details-empty"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["account-list-empty-add"].exists)
        // 空账本没有可搜索的收支，不显示搜索入口。
        XCTAssertFalse(app.buttons["home-search"].exists)
        XCTAssertTrue(app.buttons["home-add-expense"].exists)

        openAccountsTab(in: app)

        XCTAssertTrue(app.buttons["account-list-empty-add"].waitForExistence(timeout: 3))
    }

    /// 空账本的图表页只保留引导，右上角不显示分类统计入口。
    @MainActor
    func testEmptyChartHidesCategoryBreakdownEntry() throws {
        let app = launchIsolatedAppInEnglish()
        app.tabBars.buttons["Charts"].tap()

        XCTAssertTrue(app.otherElements["chart-empty"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["chart-category-breakdown-entry"].exists)
    }

    /// 没有账户时，默认账户选择页提供添加入口，新建的现金账户直接成为默认。
    @MainActor
    func testDefaultAccountSelectionCanAddFirstAccount() throws {
        let app = launchIsolatedAppInEnglish()
        app.tabBars.buttons["Profile"].tap()
        app.buttons["profile-settings"].tap()
        let defaultAccount = app.buttons["profile-default-account"]
        XCTAssertTrue(defaultAccount.waitForExistence(timeout: 3))
        defaultAccount.tap()

        let addButton = app.buttons["default-account-empty-add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 3))
        addButton.tap()

        let cashType = app.descendants(matching: .any)["account-creation-type-cash"]
        XCTAssertTrue(cashType.waitForExistence(timeout: 3))
        cashType.tap()
        let amountField = app.textFields["account-creation-amount"]
        XCTAssertTrue(amountField.waitForExistence(timeout: 2))
        amountField.tap()
        amountField.typeText("40")
        app.buttons["account-creation-save"].tap()

        // 保存后两层 sheet 都关闭，回到设置页并显示新默认账户。
        XCTAssertTrue(defaultAccount.waitForExistence(timeout: 3))
        XCTAssertFalse(addButton.exists)
        XCTAssertFalse(defaultAccount.label.contains("No valid default account"))
    }

    @MainActor
    func testChoosingAccountsAsStartPageMovesItsTabFirst() throws {
        let app = launchIsolatedAppInEnglish()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(app.tabBars.buttons.element(boundBy: 0).label, "Ledger")

        app.tabBars.buttons["Profile"].tap()
        app.buttons["profile-settings"].tap()
        let startPage = app.buttons["profile-start-page"]
        XCTAssertTrue(startPage.waitForExistence(timeout: 3))
        startPage.tap()
        tapMenuOption("Accounts", in: app)

        // 重排 Tab 会重建 TabView，“我的”导航路径保留，仍停留在设置页。
        XCTAssertTrue(startPage.waitForExistence(timeout: 3))
        XCTAssertTrue(startPage.label.contains("Accounts"))
        XCTAssertEqual(app.tabBars.buttons.element(boundBy: 0).label, "Accounts")
        XCTAssertEqual(app.tabBars.buttons.element(boundBy: 1).label, "Ledger")
        XCTAssertEqual(app.tabBars.buttons.count, 4)
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            _ = launchIsolatedAppInEnglish()
        }
    }

    /// 在已弹出的系统菜单里点选指定选项。
    ///
    /// 起始页选项与 Tab 同名，按名称查询会同时命中 Tab 按钮，且各系统版本的元素顺序不同：
    /// iOS 18 上 `firstMatch` 是被菜单遮住、无法点击的 Tab 按钮。这里排除 Tab Bar 范围内的元素，
    /// 只点菜单里的那一项；菜单弹出前只有 Tab 按钮能匹配，所以会一直等到菜单项出现。
    /// - Parameters:
    ///   - label: 菜单选项的显示文字。
    ///   - app: 被测应用。
    ///   - timeout: 等待菜单项出现的最长时间。
    @MainActor
    private func tapMenuOption(_ label: String, in app: XCUIApplication, timeout: TimeInterval = 3) {
        let tabBarFrame = app.tabBars.firstMatch.frame
        let matches = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label))
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let option = matches.allElementsBoundByIndex.first(where: { !$0.frame.intersects(tabBarFrame) }) {
                option.tap()
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        XCTFail("菜单中没有出现「\(label)」选项")
    }
}
