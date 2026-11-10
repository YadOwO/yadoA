#if DEBUG
import Foundation

/// 仅供 UI 自动化使用的 AI 记账说明夹具：启动后直接弹出“AI 记账说明”，不发请求。
///
/// UI 自动化没有真实账号，从按住说话和聊天入口走不到说明弹层，所以夹具启用时启动后直接弹出；
/// 夹具没有“同意后接着做的事”，同意或暂不使用都只是关掉弹层。
enum AIProcessingConsentUITestFixture {
    /// 是否启用：只在隔离内存存储下生效，不会碰到真实数据。
    static var isEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-testing-in-memory")
            && arguments.contains("--ui-testing-ai-consent-fixture")
    }
}
#endif
