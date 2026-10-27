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
    @State private var onboarding: OnboardingStore? = OnboardingStore.isCompleted() ? nil : OnboardingStore()
    /// 引导是否已完成；种下时变为 true，首页随之重建，按引导里选的启动页面落点和排好 Tab。
    @AppStorage(OnboardingStore.completedKey) private var isOnboardingCompleted = false

    var body: some View {
        AppTabView()
            .id(isOnboardingCompleted)
            // 引导盖着时，底下的首页不响应 VoiceOver
            .accessibilityHidden(onboarding != nil)
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
            .signInPageHost()
            .syncEngineHost()
            .environment(signInPresentation)
    }
}
