import XCTest

/// 验证分类统计入口、继承筛选、交互和本地化，并保留实际页面截图。
final class CategoryBreakdownFlowUITests: XCTestCase {
    /// 从收入年视图进入，切换筛选后返回仍保留原图表上下文。
    @MainActor
    func testInheritsFiltersAndNavigatesBack() throws {
        let app = launchExportFixtureInEnglish()
        app.tabBars.buttons["Charts"].tap()
        app.segmentedControls["chart-entry-type-picker"].buttons["Income"].tap()
        app.segmentedControls["chart-period-picker"].buttons["Year"].tap()
        let originalPeriod = app.staticTexts["chart-time-selector"].label
        let entry = app.buttons["chart-category-breakdown-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), app.debugDescription)
        entry.tap()

        XCTAssertTrue(app.navigationBars["Category breakdown"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.segmentedControls["chart-entry-type-picker"].buttons["Income"].isSelected)
        XCTAssertTrue(app.segmentedControls["chart-period-picker"].buttons["Year"].isSelected)
        XCTAssertEqual(app.staticTexts["chart-time-selector"].label, originalPeriod)
        let total = app.descendants(matching: .any)["category-breakdown-total"].firstMatch
        XCTAssertTrue(total.label.contains("100.00"))
        XCTAssertTrue(app.buttons["category-breakdown-legend-income.salary"].value as? String != nil)

        app.segmentedControls["chart-period-picker"].buttons["Week"].tap()
        XCTAssertTrue(total.label.contains("100.00"))
        app.segmentedControls["chart-period-picker"].buttons["Month"].tap()
        app.buttons["Previous period"].tap()
        XCTAssertTrue(app.staticTexts["category-breakdown-empty"].exists)
        XCTAssertTrue(total.label.contains("0.00"))
        app.buttons["Next period"].tap()
        app.segmentedControls["chart-entry-type-picker"].buttons["Expense"].tap()
        XCTAssertTrue(total.label.contains("12.50"))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["chart-category-breakdown-entry"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.segmentedControls["chart-entry-type-picker"].buttons["Income"].isSelected)
        XCTAssertTrue(app.segmentedControls["chart-period-picker"].buttons["Year"].isSelected)
    }

    /// 多分类数据覆盖图例点选和浅深色截图；使用隔离内存账本。
    @MainActor
    func testCategorySelectionAndAppearance() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing-in-memory", "--ui-testing-home-design-preview",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"
        ]
        app.launch()
        app.tabBars.buttons["图表"].tap()
        let entry = app.buttons["chart-category-breakdown-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), app.debugDescription)
        entry.tap()
        XCTAssertTrue(app.navigationBars["分类统计"].waitForExistence(timeout: 3))
        attachScreenshot(of: app, name: "Category breakdown - Initial Chinese")
        let total = app.descendants(matching: .any)["category-breakdown-total"].firstMatch
        XCTAssertTrue(total.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(total.label.contains("479.80"))
        let shopping = app.buttons["category-breakdown-legend-expense.shopping"].firstMatch
        XCTAssertTrue(shopping.exists)
        shopping.tap()
        XCTAssertTrue(total.label.contains("268.00"))
        shopping.tap()
        XCTAssertTrue(total.label.contains("479.80"))
        attachScreenshot(of: app, name: "Category breakdown - Chinese")
        let donut = app.descendants(matching: .any)["category-breakdown-donut"].firstMatch
        let shoppingSector = donut.coordinate(withNormalizedOffset: CGVector(
            dx: 0.5 + min(donut.frame.width, donut.frame.height) * 0.42 / donut.frame.width,
            dy: 0.5
        ))
        shoppingSector.tap()
        XCTAssertTrue(total.label.contains("268.00"))
        app.buttons["category-breakdown-legend-expense.dining"].firstMatch.tap()
        XCTAssertTrue(total.label.contains("118.00"))
        shoppingSector.tap()
        XCTAssertTrue(total.label.contains("268.00"))
        shopping.tap()
        app.swipeUp()
        XCTAssertTrue(app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ AND value CONTAINS %@", "日用", "76.80")
        ).firstMatch.exists, app.debugDescription)
        attachScreenshot(of: app, name: "Category ranking - Chinese")
    }

    /// 空账本保持零值和说明，避免绘制没有业务含义的满圆。
    @MainActor
    func testEmptyStateInEnglish() throws {
        let app = launchIsolatedAppInEnglish()
        app.tabBars.buttons["Charts"].tap()
        let entry = app.buttons["chart-category-breakdown-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), app.debugDescription)
        entry.tap()
        XCTAssertTrue(app.staticTexts["category-breakdown-empty"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["category-breakdown-total"].firstMatch.label.contains("0.00"))
        XCTAssertTrue(app.staticTexts["No records in this period"].firstMatch.exists)
        attachScreenshot(of: app, name: "Category breakdown - Empty English")
    }

    /// 辅助功能字号使用可换行的分类明细，仍保留总额和分类选择。
    @MainActor
    func testAccessibilityTextSize() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing-in-memory", "--ui-testing-home-design-preview",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"
        ]
        app.launch()
        app.tabBars.buttons["Charts"].tap()
        let entry = app.buttons["chart-category-breakdown-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), app.debugDescription)
        entry.tap()
        XCTAssertTrue(app.navigationBars["Category breakdown"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["category-breakdown-donut"].exists)
        let shopping = app.buttons["category-breakdown-legend-expense.shopping"]
        shopping.tap()
        let total = app.descendants(matching: .any)["category-breakdown-total"].firstMatch
        XCTAssertTrue(total.label.contains("268.00"))
        attachScreenshot(of: app, name: "Category breakdown - Accessibility English")
    }

    /// 保存当前模拟器渲染结果以检查布局与动态外观。
    @MainActor
    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
