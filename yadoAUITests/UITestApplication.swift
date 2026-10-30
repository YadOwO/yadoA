import XCTest

extension XCTestCase {
    /// 使用隔离内存存储和固定英文环境启动应用。
    @MainActor
    func launchIsolatedAppInEnglish() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing-in-memory",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-home.summary.amountsVisible", "NO"
        ]
        app.launch()
        return app
    }

    /// 使用隔离 Home 夹具和固定英文环境启动应用。
    @MainActor
    func launchHomeFixtureInEnglish() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing-in-memory",
            "--ui-testing-home-fixture",
            "--ui-testing-reset-home-summary-visibility",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        app.launch()
        return app
    }

    /// 使用数据导出专用夹具和固定英文环境启动应用。
    @MainActor
    func launchExportFixtureInEnglish() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing-in-memory",
            "--ui-testing-export-fixture",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        app.launch()
        return app
    }

    /// 使用数据导出夹具作为现有数据，并启用备份恢复夹具替代系统文件选择器。
    @MainActor
    func launchImportFixtureInEnglish() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing-in-memory",
            "--ui-testing-export-fixture",
            "--ui-testing-import-fixture",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        app.launch()
        return app
    }

    /// 使用记账搜索专用夹具和固定英文环境启动应用。
    @MainActor
    func launchBookkeepingSearchFixtureInEnglish() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing-in-memory",
            "--ui-testing-home-fixture",
            "--ui-testing-bookkeeping-search-fixture",
            "--ui-testing-reset-home-summary-visibility",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        app.launch()
        return app
    }

    /// 在可滚动区域上反复轻扫，直到目标元素进入屏幕、可以点击。
    ///
    /// 列表是懒加载的，屏幕外的行可能还不在无障碍树里，所以每次轻扫后都重新判断。
    /// - Parameters:
    ///   - element: 要滚进可视区的元素。
    ///   - container: 承接轻扫手势的滚动区域。
    ///   - swipe: 每次执行的轻扫，例如 `{ $0.swipeUp() }`。
    ///   - maxSwipes: 最多轻扫次数，避免目标不存在时无限滚动。
    /// - Returns: 目标元素最终是否可点击。
    @MainActor
    @discardableResult
    func scroll(
        to element: XCUIElement,
        in container: XCUIElement,
        by swipe: (XCUIElement) -> Void,
        maxSwipes: Int = 6
    ) -> Bool {
        for _ in 0..<maxSwipes {
            if element.exists && element.isHittable { return true }
            swipe(container)
        }
        return element.exists && element.isHittable
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
