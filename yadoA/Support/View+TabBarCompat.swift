import SwiftUI

extension View {
    /// 标记从一级 Tab 页面进入的二级及更深页面，并隐藏底部 Tab Bar。
    func secondaryPage() -> some View {
        toolbarVisibility(.hidden, for: .tabBar)
    }

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
    /// 其他情况（iOS 18、iOS 26.0、iPad）不挂附属栏，麦克风仍由记账页自己悬浮显示，见 `VoiceMicPlacement`。
    /// - Parameters:
    ///   - isEnabled: 是否显示；只在记账页根页面显示。
    ///   - voice: 与记账页会话卡片共享的语音状态。
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
