import XCTest

/// 通过隔离内存账本验证入口、模式切换、年份筛选和空账单。
final class BillFlowUITests: XCTestCase {
    @MainActor
    func testMonthlyAndYearlyBills() throws {
        let app = launchExportFixtureInEnglish()
        app.buttons["home-bills"].tap()
        XCTAssertTrue(app.navigationBars["Bills"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["bill-year-selector"].exists)
        XCTAssertTrue(app.staticTexts["bill-summary-balance"].label.contains("87.50"))
        let picker = app.segmentedControls["bill-period-picker"]
        picker.buttons["Yearly"].tap()
        XCTAssertFalse(app.buttons["bill-year-selector"].exists)
        XCTAssertTrue(app.staticTexts["All-time balance"].exists)
        XCTAssertTrue(app.staticTexts["bill-summary-balance"].label.contains("87.50"))
        picker.buttons["Monthly"].tap()
        XCTAssertTrue(app.buttons["bill-year-selector"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["home-bills"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testYearSelectionPersistsAcrossModes() throws {
        let app = launchHomeFixtureInEnglish()
        app.buttons["home-bills"].tap()
        let selector = app.buttons["bill-year-selector"]
        XCTAssertTrue(selector.waitForExistence(timeout: 3))
        let originalYear = selector.value as? String
        selector.tap()
        let options = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "[0-9]{4}"))
        let anotherYear = options.allElementsBoundByIndex.first { $0.label != originalYear }
            ?? options.allElementsBoundByIndex.first
        let option = try XCTUnwrap(anotherYear, app.debugDescription)
        let selectedYear = option.label
        option.tap()
        XCTAssertEqual(selector.value as? String, selectedYear)
        app.segmentedControls["bill-period-picker"].buttons["Yearly"].tap()
        XCTAssertFalse(selector.exists)
        app.segmentedControls["bill-period-picker"].buttons["Monthly"].tap()
        XCTAssertEqual(selector.value as? String, selectedYear)
    }

    @MainActor
    func testEmptyBills() throws {
        let app = launchIsolatedAppInEnglish()
        app.buttons["home-bills"].tap()
        XCTAssertTrue(app.staticTexts["No bills yet"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["bill-summary-balance"].label.contains("0.00"))
        app.segmentedControls["bill-period-picker"].buttons["Yearly"].tap()
        XCTAssertTrue(app.staticTexts["No bills yet"].exists)
        XCTAssertFalse(app.buttons["bill-year-selector"].exists)
    }

    /// 保留中文正常字号与英文辅助功能字号的真实渲染截图。
    @MainActor
    func testBillLayouts() throws {
        for accessibility in [false, true] {
            let app = XCUIApplication()
            app.launchArguments += [
                "--ui-testing-in-memory", "--ui-testing-home-design-preview",
                "-AppleLanguages", accessibility ? "(en)" : "(zh-Hans)",
                "-AppleLocale", accessibility ? "en_US" : "zh_CN"
            ]
            if accessibility {
                app.launchArguments += [
                    "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"
                ]
            }
            app.launch()
            app.buttons["home-bills"].tap()
            XCTAssertTrue(app.staticTexts["bill-summary-balance"].waitForExistence(timeout: 3))
            attachScreenshot(of: app, name: accessibility ? "Bills - Accessibility English" : "Bills - Chinese")
            if accessibility {
                app.swipeUp()
                attachScreenshot(of: app, name: "Bills - Accessibility rows")
            } else {
                app.segmentedControls["bill-period-picker"].buttons["年账单"].tap()
                XCTAssertFalse(app.buttons["bill-year-selector"].exists)
                attachScreenshot(of: app, name: "Bills - Yearly Chinese")
            }
            app.terminate()
        }
    }

    /// 保存实际渲染结果，检查金额与表头在不同字号下是否重叠。
    @MainActor
    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
