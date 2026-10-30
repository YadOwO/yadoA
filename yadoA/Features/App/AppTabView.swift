import SwiftData
import SwiftUI

/// 应用当前提供的一级导航入口。
enum AppTab: String, CaseIterable, Hashable {
    /// 记账页入口：按月展示收支总览与流水记录。
    case home

    /// 周、月、年支出图表入口。
    case charts

    /// 本地账户管理入口。
    case accounts

    /// “我的”入口：承载账户、显示、备份等本机设置。
    case profile

    /// 用户未选择启动页面时默认展示记账页。
    static let initial: AppTab = .home

    /// Tab 标题对应的稳定本地化键。
    var titleLocalizationKey: String {
        switch self {
        case .home:
            "app.tab.home"
        case .charts:
            "app.tab.charts"
        case .accounts:
            "account.list.title"
        case .profile:
            "profile.title"
        }
    }

    /// Tab 使用的系统语义图标。
    var symbolName: String {
        switch self {
        case .home:
            "book"
        case .charts:
            "chart.bar.xaxis"
        case .accounts:
            "creditcard"
        case .profile:
            "person.crop.circle"
        }
    }

    /// 按启动页面重排底部导航：启动页面排第一，其余保持原有相对顺序，“我的”始终在最右。
    ///
    /// - Parameter first: 用户选择的启动页面对应的 Tab。
    /// - Returns: 底部导航从左到右的 Tab 顺序。
    static func ordered(startingWith first: AppTab) -> [AppTab] {
        guard first != .profile else { return allCases }
        return [first] + allCases.filter { $0 != first }
    }

    /// 当前语言环境下的 Tab 标题。
    func title(locale: Locale = .current) -> String {
        AccountLocalization.string(titleLocalizationKey, locale: locale)
    }
}

/// 记账页导航栈支持的二级页面。
enum HomeRoute: Hashable {
    /// 新增支出页面。
    case expenseEntry

    /// 从一笔已有流水“再记一笔”：带着预填好的草稿进入新增页面。
    case repeatEntry(DiningExpenseDraft)

    /// 跨账户记账搜索页面；搜索只针对记账流水，因此归在记账页下。
    case search

    /// 统一收支详情入口。
    case transactionDetail(UUID)
}

/// 图表导航栈支持的二级页面。
enum ChartsRoute: Hashable {
    /// 分类统计页面，沿用图表当前的收支类型、周期与业务日锚点。
    case categoryBreakdown(entryType: BookkeepingEntryType, period: ChartPeriod, anchorDay: Int)

    /// 路由对应的页面。
    @MainActor @ViewBuilder
    var destination: some View {
        switch self {
        case let .categoryBreakdown(entryType, period, anchorDay):
            CategoryBreakdownView(entryType: entryType, period: period, anchorDay: anchorDay)
        }
    }
}

/// 账户导航栈支持的二级页面。
enum AccountsRoute: Hashable {
    /// 指定账户的详情页面。
    case detail(UUID)

    /// 账户历史中的统一收支详情入口。
    case transactionDetail(UUID)
}

/// “我的”导航栈支持的二级页面。
///
/// 根页面进入的二级页面都走路径导航：根导航据路径判断是否停在一级页面，决定语音入口是否显示；
/// 在设置页修改启动页面会重建 TabView，路径保存在根导航，重建后仍停留在原处。
enum ProfileRoute: Hashable {
    /// 账单页面。
    case bills

    /// 分类管理页面。
    case categories

    /// 云端同步页面。
    case sync

    /// AI 点数页面：余额、扣点规则与点数明细。
    case aiPoints

    /// AI 点数的到期明细：从 AI 点数页的到期提示进入，列出每批点数的来源与到期时间。
    case aiPointLots

    /// AI 模型选择：从 AI 点数页进入，介绍各模型档位的特点与每句扣的点数，点选后保存在本机。
    case aiModelTier

    /// 设置页面。
    case settings

    /// 意见反馈：与芽豆团队的对话，登录后才有入口。
    case feedback

    /// 开发调试页面；只在 DEBUG 包有入口和页面。
    case developer

    /// 路由对应的页面。
    @MainActor @ViewBuilder
    var destination: some View {
        switch self {
        case .bills:
            BillView()
        case .categories:
            CategoryManagementView()
        case .sync:
            SyncSettingsView()
        case .aiPoints:
            AIPointsView()
        case .aiPointLots:
            AIPointLotsView()
        case .aiModelTier:
            AIModelTierView()
        case .settings:
            SettingsView()
        case .feedback:
            FeedbackView()
        case .developer:
            #if DEBUG
            DeveloperView()
            #else
            EmptyView()
            #endif
        }
    }
}

/// 应用根级导航：记账、图表、账户与“我的”四个一级入口。
struct AppTabView: View {
    @Environment(\.locale) private var locale
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    /// 全局登录状态；换账号或退出登录时重新查询意见反馈的未读数。
    @Environment(AuthStore.self) private var authStore
    /// 意见反馈的未读回复数，显示在「我的」Tab 的角标上；预览中没有注入时为 nil。
    @Environment(FeedbackStore.self) private var feedback: FeedbackStore?
    /// 用户选择的启动页面；对应 Tab 排在底部导航第一位，修改后立即重建并重排。
    @AppStorage(AppStartPage.storageKey) private var startPage: AppStartPage = .home
    /// 冷启动时落在用户选择的启动页面；之后在设置里修改不会打断当前所在 Tab。
    @State private var selectedTab: AppTab = AppStartPage.stored().tab
    /// 首次引导是否已完成；引导写入或跳过时变为 true，此时落到引导里选的启动页面。
    @AppStorage(OnboardingStore.completedKey) private var isOnboardingCompleted = false
    @State private var homePath: [HomeRoute] = []
    @State private var chartsPath: [ChartsRoute] = []
    @State private var accountsPath: [AccountsRoute] = []
    @State private var profilePath: [ProfileRoute] = []
    /// 语音记账的共享状态；麦克风可能在 Tab Bar 附属栏里，与各一级页面的会话卡片分属两处，由这里统一持有。
    @State private var voice = VoiceBookkeepingState()

    /// 当前 Tab 是否停在一级页面；语音入口和会话卡片只在一级页面出现。
    ///
    /// 各一级页面进入二级页面都走路径导航，路径为空即停在一级页面。
    private var isAtTabRoot: Bool {
        switch selectedTab {
        case .home: homePath.isEmpty
        case .charts: chartsPath.isEmpty
        case .accounts: accountsPath.isEmpty
        case .profile: profilePath.isEmpty
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(AppTab.ordered(startingWith: startPage.tab), id: \.self) { tab in
                Tab(value: tab) {
                    content(for: tab)
                } label: {
                    Label(tab.title(locale: locale), systemImage: tab.symbolName)
                }
                // 意见反馈有未读回复时在「我的」上显示条数，为 0 时不显示角标
                .badge(tab == .profile ? feedback?.unreadCount ?? 0 : 0)
            }
        }
        .tabBarMinimizeOnScrollDownIfAvailable()
        // 麦克风在四个一级页面常显，进入二级页面时收起
        .voiceMicAccessoryIfAvailable(isEnabled: isAtTabRoot, voice: voice)
        // 系统 Tab Bar 原地重排时图标与标题会错位，顺序变化时整体重建；
        // 各导航路径保存在本视图，重建后仍然保留。
        .id(startPage)
        // 会话、计时与弹层挂在 .id 外面，重排 Tab 时不会重建
        .voiceBookkeepingHost(voice)
        // App 启动、回到前台、换账号或退出登录时刷新意见反馈的未读数；退出登录时清零
        .task(id: FeedbackUnreadTrigger(userID: authStore.userID, isActive: scenePhase == .active)) {
            guard scenePhase == .active else { return }
            await feedback?.refreshUnread()
        }
        // 当前 Tab 往下进页面时结束会话；只按导航路径变深判断，切到停在二级页面的 Tab 不算
        .onChange(of: homePath.count) { oldDepth, newDepth in
            endVoiceSessionIfPushed(on: .home, from: oldDepth, to: newDepth)
        }
        .onChange(of: chartsPath.count) { oldDepth, newDepth in
            endVoiceSessionIfPushed(on: .charts, from: oldDepth, to: newDepth)
        }
        .onChange(of: accountsPath.count) { oldDepth, newDepth in
            endVoiceSessionIfPushed(on: .accounts, from: oldDepth, to: newDepth)
        }
        .onChange(of: profilePath.count) { oldDepth, newDepth in
            endVoiceSessionIfPushed(on: .profile, from: oldDepth, to: newDepth)
        }
        // 卡片上点了一笔流水：回到记账页根页面，由记账页取走请求并定位；路径变浅不会结束会话
        .onChange(of: voice.pendingLocate) { _, change in
            guard change != nil else { return }
            homePath = []
            selectedTab = .home
        }
        // 引导盖在首页上，写入时首页不整棵重建，只在这里切到选好的启动页面；挂在 .id 外面，重排 Tab 时不会漏掉
        .onChange(of: isOnboardingCompleted) { _, isCompleted in
            guard isCompleted else { return }
            selectedTab = startPage.tab
        }
    }

    /// 当前 Tab 往下进了页面时结束语音会话。
    ///
    /// 只是切到一个停在二级页面的 Tab 时路径不变，会话保留：卡片和麦克风随页面收起，回到一级页面时卡片还在，
    /// 闲置计时照常进行。从图表点“记一笔”会同时切到记账页并进入记账表单，这时记账页路径变深，同样结束会话。
    /// - Parameters:
    ///   - tab: 路径发生变化的 Tab。
    ///   - oldDepth: 变化前的导航深度。
    ///   - newDepth: 变化后的导航深度。
    private func endVoiceSessionIfPushed(on tab: AppTab, from oldDepth: Int, to newDepth: Int) {
        guard tab == selectedTab, newDepth > oldDepth else { return }
        voice.endSession()
    }

    /// 记账页导航栈里的新增页面，保存到本地账本。
    ///
    /// - Parameter draft: 预填好的草稿；为空时新建一笔。
    private func expenseEntry(draft: DiningExpenseDraft? = nil) -> some View {
        DiningExpenseEntryView(draft: draft) { draft in
            let repository = LocalExpenseRepository(
                container: modelContext.container
            )
            try repository.save(draft)
        }
    }

    /// 各一级 Tab 的根页面及其导航栈。
    @ViewBuilder
    private func content(for tab: AppTab) -> some View {
        switch tab {
        case .home:
            NavigationStack(path: $homePath) {
                HomeView { draft in
                    homePath.append(.repeatEntry(draft))
                }
                .navigationDestination(for: HomeRoute.self) { route in
                    switch route {
                    case .expenseEntry:
                        expenseEntry()
                    case let .repeatEntry(draft):
                        expenseEntry(draft: draft)
                    case .search:
                        BookkeepingSearchView { transactionID in
                            homePath.append(.transactionDetail(transactionID))
                        }
                    case let .transactionDetail(transactionID):
                        BookkeepingTransactionDetailView(transactionID: transactionID)
                    }
                }
            }
        case .charts:
            NavigationStack(path: $chartsPath) {
                ChartView {
                    // 记账入口只在记账页导航栈里，切过去后直接进入记一笔页面。
                    selectedTab = .home
                    homePath = [.expenseEntry]
                }
                .voiceBookkeepingDock()
                .navigationDestination(for: ChartsRoute.self) { route in
                    route.destination
                }
            }
        case .accounts:
            NavigationStack(path: $accountsPath) {
                AccountListView()
                    .voiceBookkeepingDock()
                    .navigationDestination(for: AccountsRoute.self) { route in
                        switch route {
                        case let .detail(accountID):
                            AccountDetailView(accountID: accountID)
                        case let .transactionDetail(transactionID):
                            BookkeepingTransactionDetailView(transactionID: transactionID)
                        }
                    }
            }
        case .profile:
            NavigationStack(path: $profilePath) {
                ProfileView()
                    .voiceBookkeepingDock()
                    .navigationDestination(for: ProfileRoute.self) { route in
                        route.destination
                    }
            }
        }
    }
}

/// 触发刷新意见反馈未读数的条件：账号变化，或 App 回到前台。
private struct FeedbackUnreadTrigger: Equatable {
    /// 当前登录账号；退出登录时为 nil。
    let userID: String?

    /// App 是否在前台。
    let isActive: Bool
}

#Preview {
    AppTabView()
        .environment(AuthStore())
        .environment(SignInPresentation())
        .modelContainer(
            for: [Account.self, AccountTransaction.self, BookkeepingPreference.self],
            inMemory: true
        )
}
