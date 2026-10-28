//
//  yadoAApp.swift
//  yadoA
//
//  Created by webull_yado on 2026/8/12.
//

import SwiftData
import SwiftUI

@main
struct yadoAApp: App {
    /// 仅由 UI 自动化参数显式启用的隔离内存容器；生产启动不会创建它。
    private let uiTestingDataContainer: AccountDataContainer?
    /// 全局登录状态，注入环境后由“我的”页读取；不参与本地账本的读写。
    @State private var authStore: AuthStore
    /// 当前账号的 AI 点数，“我的”入口、AI 点数页和语音记账共用；凭证与账号取自 `authStore`。
    @State private var aiPoints: AIPointsStore

    init() {
        let authStore = AuthStore()
        _authStore = State(initialValue: authStore)
        _aiPoints = State(initialValue: AIPointsStore(authStore: authStore))
        #if DEBUG
        // yadoA-local / yadoA Scheme 通过启动环境变量指定是否为本地开发包，以及 AI 服务和同步服务的本地地址
        AIServiceEnvironment.applyLaunchEnvironment(ProcessInfo.processInfo.environment)
        DeveloperTools.applyLaunchEnvironment(ProcessInfo.processInfo.environment)
        SyncServiceEnvironment.applyLaunchEnvironment(ProcessInfo.processInfo.environment)
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-in-memory") {
            do {
                // 设计预览沿用隔离启动路径，示例收支不会写入真实账本。
                let container = ProcessInfo.processInfo.arguments.contains("--ui-testing-home-design-preview")
                    ? AccountDataContainer(
                        modelContainer: try HomeDesignPreviewData.makeContainer(),
                        storage: .inMemory
                    )
                    : try AccountDataContainer.inMemory()
                // 最近搜索存在 UserDefaults 里，隔离启动时清掉，避免上一次自动化的搜索词串进来。
                UserDefaults.standard.removeObject(forKey: BookkeepingSearchHistory.storageKey)
                // 启动页面偏好同样存在 UserDefaults 里，隔离启动时恢复为记账页，保证自动化落点与 Tab 顺序稳定。
                UserDefaults.standard.removeObject(forKey: AppStartPage.storageKey)
                // 首次引导会盖住首页，自动化默认跳过；显式传入参数时从头演示引导
                UserDefaults.standard.removeObject(forKey: OnboardingStore.progressKey)
                UserDefaults.standard.set(
                    !ProcessInfo.processInfo.arguments.contains("--ui-testing-onboarding"),
                    forKey: OnboardingStore.completedKey
                )
                if ProcessInfo.processInfo.arguments.contains("--ui-testing-home-fixture") {
                    if ProcessInfo.processInfo.arguments.contains("--ui-testing-reset-home-summary-visibility") {
                        UserDefaults.standard.set(false, forKey: "home.summary.amountsVisible")
                    }
                    try HomeUITestFixture.seed(in: container.modelContainer)
                }
                if ProcessInfo.processInfo.arguments.contains("--ui-testing-export-fixture") {
                    try HomeUITestFixture.seedExport(in: container.modelContainer)
                }
                if ProcessInfo.processInfo.arguments.contains("--ui-testing-bookkeeping-search-fixture") {
                    try HomeUITestFixture.seedBookkeepingSearch(in: container.modelContainer)
                }
                uiTestingDataContainer = container
                if ScreenshotShortcutUITestFixture.isEnabled,
                   ProcessInfo.processInfo.arguments.contains("--ui-testing-screenshot-cold-start") {
                    try ScreenshotBookkeepingRouter.shared.receive(ScreenshotShortcutUITestFixture.imageData())
                }
            } catch {
                // UI 自动化绝不能因隔离容器失败而转入生产文件存储。
                fatalError("Unable to create isolated UI testing store: \(error)")
            }
        } else {
            uiTestingDataContainer = nil
        }
        #else
        // Release 构建始终使用生产文件存储，忽略任何自动化启动参数。
        uiTestingDataContainer = nil
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let uiTestingDataContainer {
                    ContentView()
                        .modelContainer(uiTestingDataContainer.modelContainer)
                } else {
                    LocalDataBootstrapView {
                        ContentView()
                    }
                }
            }
            .environment(authStore)
            .environment(aiPoints)
            .modifier(AppDisplayPreferencesModifier())
        }
    }
}
