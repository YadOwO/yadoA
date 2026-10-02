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
}
