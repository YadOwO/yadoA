import Foundation

/// 开发调试相关的开关。
enum DeveloperTools {
    /// 是否显示「开发」页面入口、记录语音耗时：所有 DEBUG 包（Debug、DebugProd）都显示，Release 包始终隐藏。
    static var isEnabled: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
