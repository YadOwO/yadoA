import Foundation

/// 开发调试相关的开关。
enum DeveloperTools {
    /// 是否显示「开发」页面入口、记录语音耗时：所有 DEBUG 包（Debug、DebugProd）都显示，Release 包始终隐藏。
    ///
    /// 截 App Store 宣传图时按 Release 处理，画面里不出现开发用的入口和耗时。
    static var isEnabled: Bool {
        #if DEBUG
        !AppStoreScreenshotFixture.isEnabled
        #else
        false
        #endif
    }
}
