import AppIntents
import UniformTypeIdentifiers

/// 接收上一步的截屏结果，在应用内打开待用户确认的记账表单。
struct ScreenshotBookkeepingIntent: AppIntent {
    static let title: LocalizedStringResource = "shortcut.screenshot.action"
    static let description = IntentDescription("shortcut.screenshot.description")
    static let openAppWhenRun = true

    /// 使用系统文件参数直接接收图片，不经过相册或剪贴板。
    @Parameter(
        title: "shortcut.screenshot.input",
        supportedContentTypes: [.image],
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var screenshot: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("shortcut.screenshot.summary \(\.$screenshot)")
    }

    /// 前台执行保证和 SwiftUI 使用同一进程；冷启动时请求保留到根视图出现。
    @MainActor
    func perform() async throws -> some IntentResult {
        try ScreenshotBookkeepingRouter.shared.receive(screenshot.data)
        return .result()
    }
}

/// 让系统索引截图记账动作；完整的两步工作流仍需在快捷指令中配置。
struct YadoAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ScreenshotBookkeepingIntent(),
            phrases: ["Record a screenshot with \(.applicationName)"],
            shortTitle: "shortcut.screenshot.action",
            systemImageName: "viewfinder"
        )
    }
}
