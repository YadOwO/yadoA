import XCTest

/// 验证图表收支切换、周期切换及本地化空数据展示。
final class ChartIncomeFlowUITests: XCTestCase {
    /// 当前月收支分别汇总，收入支持全部周期并可切回支出。
    @MainActor
    func testSwitchesIncomeAcrossPeriodsAndPreservesSelectedMonth() throws {
        let app = launchExportFixtureInEnglish()
        app.tabBars.buttons["Charts"].tap()
        let summary = app.staticTexts["chart-summary-card"]
        XCTAssertTrue(summary.waitForExistence(timeout: 3))
        XCTAssertTrue(summary.label.contains("12.50"))
        let types = app.segmentedControls["chart-entry-type-picker"]
        let periods = app.segmentedControls["chart-period-picker"]
        let selectedMonth = app.buttons["chart-time-selector"].label

        types.buttons["Income"].tap()
        XCTAssertTrue(summary.label.contains("Income overview"))
        XCTAssertTrue(summary.label.contains("100.00"))
        XCTAssertFalse(summary.label.contains("12.50"))
        XCTAssertEqual(app.buttons["chart-time-selector"].label, selectedMonth)
        XCTAssertTrue(app.staticTexts["Daily income"].exists)
        attachScreenshot(of: app, name: "Income month - English")

        periods.buttons["Week"].tap()
        XCTAssertTrue(summary.label.contains("100.00"))
        XCTAssertTrue(app.staticTexts["Daily income"].exists)
        periods.buttons["Year"].tap()
        XCTAssertTrue(summary.label.contains("100.00"))
        XCTAssertTrue(app.staticTexts["Monthly income"].exists)
        periods.buttons["Month"].tap()
        app.buttons["Previous period"].tap()
        let previousMonth = app.buttons["chart-time-selector"].label
        XCTAssertNotEqual(previousMonth, selectedMonth)
        XCTAssertTrue(summary.label.contains("0.00"))
        types.buttons["Expense"].tap()
        XCTAssertEqual(app.buttons["chart-time-selector"].label, previousMonth)
        XCTAssertTrue(summary.label.contains("Spending overview"))
        XCTAssertTrue(summary.label.contains("0.00"))
        app.buttons["Next period"].tap()
        XCTAssertTrue(summary.label.contains("12.50"))
    }

    /// 中文环境下，没有收入时仍能查看零值概览和趋势；外观由模拟器设置决定。
    @MainActor
    func testEmptyIncomeInChinese() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing-in-memory", "--ui-testing-home-fixture",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"
        ]
        app.launch()
        app.tabBars.buttons["图表"].tap()
        let types = app.segmentedControls["chart-entry-type-picker"]
        XCTAssertTrue(types.waitForExistence(timeout: 3))
        types.buttons["收入"].tap()
        let summary = app.staticTexts["chart-summary-card"]
        XCTAssertTrue(summary.waitForExistence(timeout: 3))
        XCTAssertTrue(summary.label.contains("收入概览"))
        XCTAssertTrue(summary.label.contains("总收入"))
        XCTAssertTrue(summary.label.contains("0.00"))
        XCTAssertTrue(app.staticTexts["每日收入"].exists)
        attachScreenshot(of: app, name: "Empty income - Chinese")
    }

    /// 保存实际模拟器页面，便于检查布局与外观。
    @MainActor
    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
