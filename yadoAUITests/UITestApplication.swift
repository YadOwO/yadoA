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
}
