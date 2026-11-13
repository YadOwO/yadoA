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
    /// 隐私政策同意状态：中国大陆地区同意之前不联网，不同意进入离线模式；其他地区不受限制。
    @State private var privacyAgreement: PrivacyAgreementStore
    /// 全局登录状态，注入环境后由“我的”页读取；不参与本地账本的读写。
    @State private var authStore: AuthStore
    /// 当前账号的 AI 点数，“我的”入口、AI 点数页和语音记账共用；凭证与账号取自 `authStore`。
    @State private var aiPoints: AIPointsStore
    /// 意见反馈的未读回复数，“我的”入口和 Tab 角标共用；凭证与账号取自 `authStore`。
    @State private var feedback: FeedbackStore
    /// 芽豆系列的产品目录，“我的”入口和「更多芽豆产品」页共用；公开数据，与登录状态无关。
    @State private var seriesCatalog: SeriesCatalogStore

    init() {
        // 同意状态最先建好，后面所有会联网的 store 都要靠它判断能不能发请求
        let privacyAgreement = Self.makePrivacyAgreement()
        _privacyAgreement = State(initialValue: privacyAgreement)
        let isNetworkAllowed = { privacyAgreement.allowsNetwork }
        let authStore = AuthStore(isNetworkAllowed: isNetworkAllowed)
        _authStore = State(initialValue: authStore)
        _aiPoints = State(initialValue: AIPointsStore(authStore: authStore, isNetworkAllowed: isNetworkAllowed))
        _feedback = State(initialValue: FeedbackStore(authStore: authStore, isNetworkAllowed: isNetworkAllowed))
        _seriesCatalog = State(initialValue: SeriesCatalogStore(isNetworkAllowed: isNetworkAllowed))
        // Release 同样启用；诊断只存本机，只有用户在意见反馈里勾选后才上传
        MetricKitCollector.shared.start()
        #if DEBUG
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
                if AIChatUITestFixture.isEnabled {
                    try AIChatUITestFixture.seed(in: container.modelContainer)
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

    /// 创建隐私政策同意状态。
    ///
    /// Debug 构建的 UI 自动化（`--ui-testing-in-memory`）下默认不需要同意，现有用例不会出现同意卡；
    /// 传 `--ui-testing-privacy-agreement` 模拟中国大陆地区，再传 `--ui-testing-privacy-agreement-reset` 清掉上次的选择。
    /// Release 构建忽略这些参数。
    private static func makePrivacyAgreement() -> PrivacyAgreementStore {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing-in-memory") {
            if arguments.contains("--ui-testing-privacy-agreement-reset") {
                PrivacyAgreementStore.reset(in: .standard)
            }
            return PrivacyAgreementStore(requiresAgreement: arguments.contains("--ui-testing-privacy-agreement"))
        }
        #endif
        return PrivacyAgreementStore()
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
            .environment(privacyAgreement)
            .environment(authStore)
            .environment(aiPoints)
            .environment(feedback)
            .environment(seriesCatalog)
            .modifier(AppDisplayPreferencesModifier())
        }
    }
}
