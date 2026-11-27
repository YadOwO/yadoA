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

    /// 使用备份提醒夹具启动：隔离内存存储里有 20 笔十天前的流水，没备份过也没暂缓，账户页顶部会出现备份提醒卡片。
    ///
    /// 假设模拟器上这个 dev 包没有开启云同步。
    @MainActor
    func launchBackupReminderFixtureInEnglish() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing-in-memory",
            "--ui-testing-backup-reminder-fixture",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        app.launch()
        return app
    }

    /// 模拟中国大陆地区启动，需要先同意隐私政策；使用隔离内存存储和固定英文环境。
    ///
    /// 地区靠启动参数模拟，不依赖系统地区。
    ///
    /// - Parameters:
    ///   - reset: 是否清掉上次保存的同意或不同意选择；重启验证「以后不再弹出」时传 false。
    ///   - onboarding: 是否从头演示首次引导；默认视为引导已完成。
    /// - Returns: 已启动的应用。
    @MainActor
    func launchPrivacyAgreementInEnglish(reset: Bool, onboarding: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing-in-memory",
            "--ui-testing-privacy-agreement",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        if reset {
            app.launchArguments.append("--ui-testing-privacy-agreement-reset")
        }
        if onboarding {
            app.launchArguments.append("--ui-testing-onboarding")
        }
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

    /// 使用隔离 Home 夹具、已开启的应用锁和固定英文环境启动应用。
    ///
    /// 应用锁用假验证器：不弹系统的面容 ID 或密码界面，也不自动验证，靠点「解锁」按钮解锁。
    ///
    /// - Parameters:
    ///   - oneMinute: 上锁时长是否为 1 分钟；默认「立即」。
    ///   - extraArguments: 额外的启动参数，例如截图记账夹具的参数。
    /// - Returns: 已启动的应用，停在锁屏。
    @MainActor
    func launchAppLockInEnglish(oneMinute: Bool = false, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing-in-memory",
            "--ui-testing-home-fixture",
            "--ui-testing-app-lock"
        ]
        if oneMinute {
            app.launchArguments.append("--ui-testing-app-lock-one-minute")
        }
        app.launchArguments += extraArguments
        app.launchArguments += [
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

    /// 使用 AI 对话夹具和固定英文环境启动应用：写入一轮本机对话记录，启动后直接打开聊天页。
    @MainActor
    func launchAIChatFixtureInEnglish() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing-in-memory",
            "--ui-testing-ai-chat-fixture",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        app.launch()
        return app
    }

    /// 使用 AI 记账说明夹具和固定英文环境启动应用：启动后直接弹出“AI 记账说明”，不发请求。
    @MainActor
    func launchAIConsentFixtureInEnglish() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing-in-memory",
            "--ui-testing-ai-consent-fixture",
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
        let window = XCUIApplication().windows.firstMatch.frame
        // 完全在屏幕外的元素没有可用的点击点，直接读 isHittable 会报错，先用位置排除。
        let isVisible = { element.exists && window.contains(element.frame) && element.isHittable }
        for _ in 0..<maxSwipes {
            if isVisible() { return true }
            swipe(container)
        }
        return isVisible()
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
