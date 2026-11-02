import SwiftUI

// 二级页面不隐藏 Tab Bar：按 HIG 让用户始终知道自己在哪个一级入口里。
// SwiftUI 的 `toolbarVisibility(.hidden, for: .tabBar)` 要等返回动画结束才把 Tab Bar 放回来，
// 返回时会先空一下再弹出，因此不再使用。
extension View {
    /// 在支持时启用 iOS 26 原生液态玻璃 Tab Bar 的滚动收起行为。
    ///
    /// iOS 18 没有该 API，因此直接返回原视图并保留普通系统 Tab Bar。
    @ViewBuilder
    func tabBarMinimizeOnScrollDownIfAvailable() -> some View {
        if #available(iOS 26.0, *) {
            tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }

    /// 在 iPhone 的 iOS 26.1 及以上把语音麦克风挂到 Tab Bar 附属栏，跟随 Tab Bar 滚动收起。
    ///
    /// 其他情况（iOS 18、iOS 26.0、iPad）不挂附属栏，麦克风由各一级页面自己悬浮显示，见 `VoiceMicPlacement`。
    /// - Parameters:
    ///   - isEnabled: 是否显示；只在一级页面显示，进入二级页面时收起。
    ///   - voice: 与各一级页面会话卡片共享的语音状态。
    @ViewBuilder
    func voiceMicAccessoryIfAvailable(isEnabled: Bool, voice: VoiceBookkeepingState) -> some View {
        if #available(iOS 26.1, *) {
            if VoiceMicPlacement.usesTabBarAccessory {
                tabViewBottomAccessory(isEnabled: isEnabled) {
                    VoiceMicAccessory(voice: voice)
                }
            } else {
                self
            }
        } else {
            self
        }
    }
}
