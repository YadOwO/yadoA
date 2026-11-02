import XCTest

/// 通过隔离内存账本验证入口、模式切换、年份筛选和空账单。
final class BillFlowUITests: XCTestCase {
    @MainActor
    func testMonthlyAndYearlyBills() throws {
        let app = launchExportFixtureInEnglish()
        openBills(in: app)
        XCTAssertTrue(app.navigationBars["Bills"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["bill-year-selector"].exists)
        XCTAssertTrue(app.staticTexts["bill-summary-balance"].label.contains("87.50"))
        app.buttons["bill-period-picker-yearly"].tap()
        XCTAssertFalse(app.buttons["bill-year-selector"].exists)
        XCTAssertTrue(app.staticTexts["All-time balance"].exists)
        XCTAssertTrue(app.staticTexts["bill-summary-balance"].label.contains("87.50"))
        app.buttons["bill-period-picker-monthly"].tap()
        XCTAssertTrue(app.buttons["bill-year-selector"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["profile-bills"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testYearSelectionPersistsAcrossModes() throws {
        let app = launchHomeFixtureInEnglish()
        openBills(in: app)
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
        app.buttons["bill-period-picker-yearly"].tap()
        XCTAssertFalse(selector.exists)
        app.buttons["bill-period-picker-monthly"].tap()
        XCTAssertEqual(selector.value as? String, selectedYear)
    }

    @MainActor
    func testEmptyBills() throws {
        let app = launchIsolatedAppInEnglish()
        openBills(in: app)
        XCTAssertTrue(app.staticTexts["No bills yet"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["bill-summary-balance"].label.contains("0.00"))
        app.buttons["bill-period-picker-yearly"].tap()
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
            openBills(in: app)
            XCTAssertTrue(app.staticTexts["bill-summary-balance"].waitForExistence(timeout: 3))
            attachScreenshot(of: app, name: accessibility ? "Bills - Accessibility English" : "Bills - Chinese")
            if accessibility {
                app.swipeUp()
                attachScreenshot(of: app, name: "Bills - Accessibility rows")
            } else {
                app.buttons["bill-period-picker-yearly"].tap()
                XCTAssertFalse(app.buttons["bill-year-selector"].exists)
                attachScreenshot(of: app, name: "Bills - Yearly Chinese")
            }
            app.terminate()
        }
    }

    /// 账单入口在“我的”里：先切到“我的”，再点账单行。
    @MainActor
    private func openBills(in app: XCUIApplication) {
        let profile = app.tabBars.buttons.element(boundBy: app.tabBars.buttons.count - 1)
        XCTAssertTrue(profile.waitForExistence(timeout: 3))
        profile.tap()
        let entry = app.buttons["profile-bills"]
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        entry.tap()
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
