#if DEBUG
import Foundation
import SwiftData

/// 仅供 UI 自动化使用的 AI 对话夹具：写入一轮本机对话记录，启动后直接打开聊天页。
///
/// 聊天页要登录才能从入口打开，自动化里没有真实账号，所以夹具启用时启动后直接盖上聊天页；只看历史记录，不发请求。
/// 文案与 `ConversationTextSelectionUITests` 里的断言保持一致。
enum AIChatUITestFixture {
    /// 是否启用：只在隔离内存存储下生效，不会碰到真实的对话记录。
    static var isEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-testing-in-memory")
            && arguments.contains("--ui-testing-ai-chat-fixture")
    }

    /// 写入一轮已完成的对话：用户的话加一段回复，没有改动和图片。
    ///
    /// - Parameter container: UI 自动化专用的内存容器。
    /// - Throws: 改动快照编码或容器保存失败时抛出错误。
    static func seed(in container: ModelContainer) throws {
        let snapshot = AIChatTurnSnapshot(
            id: UUID(),
            // 放在一分钟前，不会被启动时的过期清理删掉
            createdAt: Date().addingTimeInterval(-60),
            userText: "Lunch with friends 30",
            imageFileNames: [],
            resultText: "Noted. Anything else to log?",
            isFailed: false,
            isUndone: false,
            changes: []
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false
        context.insert(
            AIChatTurnRecord(snapshot: snapshot, changesData: try JSONEncoder().encode([AIChatChangeSnapshot]()))
        )
        try context.save()
    }
}
#endif
