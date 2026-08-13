import XCTest

extension XCTestCase {
    /// 使用隔离内存存储和固定英文环境启动应用。
    @MainActor
    func launchIsolatedAppInEnglish() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing-in-memory",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        app.launch()
        return app
    }

    /// 从默认首页切换到账户 Tab，并等待账户页完成展示。
    @MainActor
    func openAccountsTab(in app: XCUIApplication) {
        let accountsTab = app.tabBars.buttons["Accounts"]
        XCTAssertTrue(accountsTab.waitForExistence(timeout: 3))
        accountsTab.tap()
        XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 3))
    }
}
