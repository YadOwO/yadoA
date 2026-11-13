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
    /// 隐私政策同意状态；预览中没有注入时为 nil，按允许联网处理。
    @Environment(PrivacyAgreementStore.self) private var privacyAgreement: PrivacyAgreementStore?

    var body: some View {
        AppTabView()
            // 引导或同意卡盖着时，底下的首页不响应 VoiceOver
            .accessibilityHidden(onboarding != nil || privacyAgreement?.isCardPresented == true)
            // 引导结束时在语音入口旁边浮出一句提示；离线模式没有语音入口，不提示
            .overlay {
                if privacyAgreement?.allowsNetwork ?? true {
                    VoiceEntryHint()
                }
            }
            // 做完隐私政策的选择之前不显示引导，免得开场动画在同意卡底下先播
            .overlay {
                if let onboarding, privacyAgreement?.needsDecision != true {
                    OnboardingView(store: onboarding) {
                        self.onboarding = nil
                    }
                    .transition(.identity)
                }
            }
            // 同意卡盖在最上层；老用户引导已完成，也会先看到它
            .overlay {
                if let privacyAgreement, privacyAgreement.isCardPresented {
                    PrivacyAgreementView(store: privacyAgreement)
                        .transition(.opacity)
                }
            }
            // 离线模式（没同意隐私政策）时引导跳过账号和登录邀请；引导被重新赋值时也同步一次
            .onChange(
                of: OnboardingOfflineSync(
                    hasOnboarding: onboarding != nil,
                    isOffline: privacyAgreement?.isOfflineMode ?? false
                ),
                initial: true
            ) { _, state in
                onboarding?.setOffline(state.isOffline)
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

/// 引导的离线状态同步条件：引导出现（或被重新赋值）、或离线状态变化时重新同步一次。
private struct OnboardingOfflineSync: Equatable {
    /// 当前是否有引导。
    let hasOnboarding: Bool

    /// 是否处于离线模式（没同意隐私政策）。
    let isOffline: Bool
}
