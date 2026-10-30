//
//  ContentView.swift
//  yadoA
//
//  Created by webull_yado on 2026/8/12.
//

import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var screenshotRouter = ScreenshotBookkeepingRouter.shared
    /// 整屏登录页的展示状态，任何页面需要登录时都通过它打开。
    @State private var signInPresentation = SignInPresentation()
    /// 首次引导；已完成或跳过过时为 nil。引导盖在首页上，撕下最后一页时露出底下的首页。
    ///
    /// 引导写入时首页不能整棵重建，否则盖在上面的引导会跟着重建、从头再放一遍；启动页面的落点和 Tab 顺序由首页自己跟上。
    @State private var onboarding: OnboardingStore? = OnboardingStore.isCompleted() ? nil : OnboardingStore()

    var body: some View {
        AppTabView()
            // 引导盖着时，底下的首页不响应 VoiceOver
            .accessibilityHidden(onboarding != nil)
            // 引导结束时在语音入口旁边浮出一句提示
            .overlay {
                VoiceEntryHint()
            }
            .overlay {
                if let onboarding {
                    OnboardingView(store: onboarding) {
                        self.onboarding = nil
                    }
                    .transition(.identity)
                }
            }
            .background {
                ScreenshotBookkeepingPresenter(
                    request: screenshotRouter.request,
                    container: modelContext.container,
                    onFinish: { screenshotRouter.request = nil }
                )
                .frame(width: 0, height: 0)
            }
            // 放在 syncEngineHost 里面，才能读到它注入的同步引擎
            .bookkeepingLifecycleHost()
            .signInPageHost()
            .syncEngineHost()
            .environment(signInPresentation)
    }
}
