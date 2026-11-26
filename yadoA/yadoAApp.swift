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
    /// 面容 ID / 密码应用锁：冷启动和从后台回来超时后先验证才能看账本，并在切换器里遮住界面；只在本机完成，不涉及联网。
    @State private var appLock: AppLockController
    /// 全局登录状态，注入环境后由“我的”页读取；不参与本地账本的读写。
    @State private var authStore: AuthStore
    /// 当前账号的 AI 点数，“我的”入口、AI 点数页和语音记账共用；凭证与账号取自 `authStore`。
    @State private var aiPoints: AIPointsStore
    /// 点数充值：在售商品、购买与交易入账，只在登录后出现；入账后刷新 `aiPoints` 的余额。
    @State private var aiPointsShop: AIPointsShop
    /// 意见反馈的未读回复数，“我的”入口和 Tab 角标共用；凭证与账号取自 `authStore`。
    @State private var feedback: FeedbackStore
    /// 芽豆系列的产品目录，“我的”入口和「更多芽豆产品」页共用；公开数据，与登录状态无关。
    @State private var seriesCatalog: SeriesCatalogStore
    /// 数据联动状态：授权、物品估值汇总缓存和估值设置；授权以 hub 为准，凭证与账号取自 `authStore`。
    @State private var dataLinks: DataLinkStore

    init() {
        // 同意状态最先建好，后面所有会联网的 store 都要靠它判断能不能发请求
        let privacyAgreement = Self.makePrivacyAgreement()
        _privacyAgreement = State(initialValue: privacyAgreement)
        _appLock = State(initialValue: Self.makeAppLock())
        let isNetworkAllowed = { privacyAgreement.allowsNetwork }
        let authStore = AuthStore(isNetworkAllowed: isNetworkAllowed)
        _authStore = State(initialValue: authStore)
        let aiPoints = AIPointsStore(authStore: authStore, isNetworkAllowed: isNetworkAllowed)
        _aiPoints = State(initialValue: aiPoints)
        _aiPointsShop = State(
            initialValue: AIPointsShop(authStore: authStore, aiPoints: aiPoints, isNetworkAllowed: isNetworkAllowed)
        )
        _feedback = State(initialValue: FeedbackStore(authStore: authStore, isNetworkAllowed: isNetworkAllowed))
        _seriesCatalog = State(initialValue: SeriesCatalogStore(isNetworkAllowed: isNetworkAllowed))
        _dataLinks = State(initialValue: DataLinkStore(authStore: authStore, isNetworkAllowed: isNetworkAllowed))
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
                // 上次备份时间存在 UserDefaults 里，隔离启动时清掉，避免上一次自动化的备份记录让提醒卡片不出现。
                UserDefaults.standard.removeObject(forKey: BackupReminderStore.lastExportedAtKey)
                if BackupReminderUITestFixture.isEnabled {
                    // 暂缓记录同样要清掉，保证夹具启动时卡片一定显示；再写入够多、够久的流水。
                    UserDefaults.standard.removeObject(forKey: BackupReminderStore.snoozedUntilKey)
                    try BackupReminderUITestFixture.seed(in: container.modelContainer)
                } else {
                    // 其他用例的夹具流水可能凑够 20 笔，卡片会冒出来干扰原有用例，所以把暂缓期设到无限远。
                    UserDefaults.standard.set(
                        Date.distantFuture.timeIntervalSince1970,
                        forKey: BackupReminderStore.snoozedUntilKey
                    )
                }
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
                // App Store 宣传图的演示账本
                if AppStoreScreenshotFixture.isEnabled {
                    try AppStoreScreenshotFixture.seed(in: container.modelContainer)
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

    /// 创建应用锁状态机。
    ///
    /// Debug 构建的 UI 自动化（`--ui-testing-in-memory`）下改用假验证器，并关闭自动验证，
    /// 靠点「解锁」按钮解锁，锁屏才不会一闪而过；同时清掉上次自动化留下的锁设置，现有 UI 测试不会被锁住。
    /// 其他情况一律用系统设备主人验证，Release 构建忽略这些参数。
    private static func makeAppLock() -> AppLockController {
        // 系统验证界面上的原因说明每次现读语言偏好，用户在 App 内切换语言后立即生效
        let localizedReason: () -> String = {
            let language = UserDefaults.standard.string(forKey: AppLanguage.storageKey)
                .flatMap(AppLanguage.init(rawValue:)) ?? .system
            return AccountLocalization.string(
                "app_lock.reason",
                locale: language.resolvedLocale(systemLocale: .current)
            )
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-in-memory") {
            AppLockUITestFixture.prepare(.standard)
            return AppLockController(
                authenticator: AppLockUITestFixture.Authenticator(),
                autoAuthenticates: false,
                localizedReason: localizedReason
            )
        }
        #endif
        return AppLockController(authenticator: DeviceOwnerAuthenticator(), localizedReason: localizedReason)
    }

    var body: some Scene {
        WindowGroup {
            // 开了锁的冷启动验证通过前不挂载主界面；首次解锁后主界面一直留在视图树里，重新上锁只在独立窗口里盖住
            AppLockGate(controller: appLock) {
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
            }
            .environment(privacyAgreement)
            .environment(authStore)
            .environment(aiPoints)
            .environment(aiPointsShop)
            .environment(feedback)
            .environment(seriesCatalog)
            .environment(dataLinks)
            .environment(appLock)
            .modifier(AppDisplayPreferencesModifier())
            // 付了款还没入账的交易：启动时开始监听交易更新，并在启动和每次换账号登录后补传
            .task { aiPointsShop.startObservingTransactions() }
            .task(id: authStore.userID) { await aiPointsShop.processUnfinishedTransactions() }
            // 冷启动、换账号、同意隐私政策后刷新联动列表；没登录或不允许联网时 store 里什么都不发
            .task(
                id: DataLinkRefreshTrigger(
                    isAuthenticated: authStore.isAuthenticated,
                    userID: authStore.userID,
                    isNetworkAllowed: privacyAgreement.allowsNetwork
                )
            ) {
                await dataLinks.refreshLinks()
            }
        }
    }
}

/// 触发刷新联动列表的条件：账号变化，或同意隐私政策后允许联网。
private struct DataLinkRefreshTrigger: Hashable {
    /// 本地是否持有有效凭证；读它是为了登录状态一变就重新求值。
    let isAuthenticated: Bool

    /// 当前登录账号；退出登录时为 nil。
    let userID: String?

    /// 是否允许联网；同意隐私政策后变为 true，立即重新刷新一次。
    let isNetworkAllowed: Bool
}
