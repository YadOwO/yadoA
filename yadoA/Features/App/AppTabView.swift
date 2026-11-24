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

/// 记账页导航支持的二级页面；宽屏两栏时显示在右栏，见 `TabSplitNavigation`。
enum HomeRoute: Hashable, TabSplitRoute {
    /// 新增支出页面。
    case expenseEntry

    /// 从一笔已有流水“再记一笔”：带着预填好的草稿进入新增页面。
    case repeatEntry(DiningExpenseDraft)

    /// 跨账户记账搜索页面；搜索只针对记账流水，因此归在记账页下。
    case search

    /// 统一收支详情入口。
    case transactionDetail(UUID)

    /// 记一笔页面底部有保存栏，两栏时右栏是它就收起语音麦克风。
    var hasOwnBottomBar: Bool {
        switch self {
        case .expenseEntry, .repeatEntry:
            true
        case .search, .transactionDetail:
            false
        }
    }
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

/// 账户导航支持的二级页面；宽屏两栏时显示在右栏，见 `TabSplitNavigation`。
enum AccountsRoute: Hashable, TabSplitRoute {
    /// 指定账户的详情页面。
    case detail(UUID)

    /// 账户历史中的统一收支详情入口。
    case transactionDetail(UUID)

    /// 资产分析：从账户页汇总卡片进入，按净资产、资产、负债三个 tab 看走势、资产负债率、构成和排行。
    case assetAnalysis

    /// 芽豆有物的物品估值详情：从账户页「芽豆有物」那一行或资产分析的排行进入；只有已授权数据联动、有估值时才有入口。
    case itemValuation

    /// 账户的二级页面都没有自己的底栏，两栏时语音麦克风常显。
    var hasOwnBottomBar: Bool {
        false
    }
}

/// “我的”导航支持的二级页面；宽屏两栏时显示在右栏，见 `TabSplitNavigation`。
///
/// 根页面进入的二级页面都走路径导航：根导航据路径判断是否停在一级页面，决定语音入口是否显示；
/// 在设置页修改启动页面会重建 TabView，路径保存在根导航，重建后仍停留在原处。
enum ProfileRoute: Hashable, TabSplitRoute {
    /// 账单页面。
    case bills

    /// 分类管理页面。
    case categories

    /// 周期记账页面。
    case recurringRules

    /// 云端同步页面。
    case sync

    /// 数据联动：授权芽豆有物的物品购入价汇总、查看估值、调整估值设置；登录、联网、hub 打开了来源时才有入口。
    case dataLinks

    /// AI 点数页面：余额、明细与设置入口、扣点规则。
    case aiPoints

    /// AI 点数的到期明细：从 AI 点数页的到期提示进入，列出每批点数的来源与到期时间。
    case aiPointLots

    /// AI 点数的明细：从 AI 点数页进入，分页列出每一笔点数的增减。
    case aiCreditEntries

    /// 快捷语音的模型选择：从 AI 点数页进入，介绍各模型档位的特点与每句扣的点数，点选后保存在本机；AI 对话的模型在聊天页选。
    case aiModelTier

    /// “帮助改进 AI”：从 AI 点数页进入，开关和上报说明在同一页；只在提供它的环境（dev）有入口和页面，见 `AuthConfig.isAITraceConsentAvailable`。
    case aiTraceConsent

    /// AI 记账说明：从 AI 点数页进入，查看发给 AI 的内容、撤回或重新同意。
    case aiProcessingConsent

    /// 每日签到：连签天数、待开礼包、各档礼包进度和签到日历；登录后才有入口。
    case checkIn

    /// 设置页面。
    case settings

    /// 账号与安全：从设置页「账号」分组进入，登录方式、绑定邮箱和注销芽豆账号；登录后才有入口。
    ///
    /// 必须走路径导航：退出登录后设置页的入口会消失，若用 `NavigationLink { }` 直接包页面，页面会随入口一起被移除，
    /// 注销弹层、登录了另一个账号的提示都会被一起关掉；走路径时页面留在栈里，由页面自己在弹层和提示关掉后返回。
    case accountSecurity

    /// 意见反馈：与芽豆团队的对话，登录后才有入口。
    case feedback

    /// 更多芽豆产品：芽豆系列其他 App 的列表；目录里有其他产品时才有入口。
    case moreProducts

    /// 开发调试页面；只在 DEBUG 包有入口和页面。
    case developer

    /// 意见反馈底部有输入栏、AI 记账说明底部有同意按钮，两栏时右栏最上面是它们就收起语音麦克风。
    var hasOwnBottomBar: Bool {
        switch self {
        case .feedback, .aiProcessingConsent:
            true
        case .bills, .categories, .recurringRules, .sync, .dataLinks, .aiPoints, .aiPointLots, .aiCreditEntries,
             .aiModelTier, .aiTraceConsent, .checkIn, .settings, .accountSecurity, .moreProducts, .developer:
            false
        }
    }

    /// 路由对应的页面。
    @MainActor @ViewBuilder
    var destination: some View {
        switch self {
        case .bills:
            BillView()
        case .categories:
            CategoryManagementView()
        case .recurringRules:
            RecurringRuleListView()
        case .sync:
            SyncSettingsView()
        case .dataLinks:
            DataLinksView()
        case .aiPoints:
            AIPointsView()
        case .aiPointLots:
            AIPointLotsView()
        case .aiCreditEntries:
            AICreditEntriesView()
        case .aiModelTier:
            AIModelTierView(scope: .quickVoice)
        case .aiTraceConsent:
            if AuthConfig.isAITraceConsentAvailable {
                AITraceConsentView()
            } else {
                EmptyView()
            }
        case .aiProcessingConsent:
            AIProcessingConsentView()
        case .checkIn:
            CheckInView()
        case .settings:
            SettingsView()
        case .accountSecurity:
            AccountSecurityView()
        case .feedback:
            FeedbackView()
        case .moreProducts:
            SeriesProductsView()
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
///
/// 记账、账户、“我的”在宽屏（例如 iPhone Duo 打开横拿）上是列表 + 详情两栏，其余情况与原来的导航栈一致，见 `TabSplitNavigation`。
struct AppTabView: View {
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    /// 全局登录状态；换账号或退出登录时重新查询意见反馈的未读数。
    @Environment(AuthStore.self) private var authStore
    /// 意见反馈的未读回复数，显示在「我的」Tab 的角标上；预览中没有注入时为 nil。
    @Environment(FeedbackStore.self) private var feedback: FeedbackStore?
    /// 隐私政策同意状态；离线模式下不显示语音入口，也不刷新未读数。预览中没有注入时为 nil，按允许联网处理。
    @Environment(PrivacyAgreementStore.self) private var privacyAgreement: PrivacyAgreementStore?
    /// 用户选择的启动页面；对应 Tab 排在底部导航第一位，修改后立即重建并重排。
    @AppStorage(AppStartPage.storageKey) private var startPage: AppStartPage = .home
    /// 冷启动时落在用户选择的启动页面；之后在设置里修改不会打断当前所在 Tab。
    @State private var selectedTab: AppTab = Self.launchTab
    /// 首次引导是否已完成；引导写入或跳过时变为 true，此时落到引导里选的启动页面。
    @AppStorage(OnboardingStore.completedKey) private var isOnboardingCompleted = false
    @State private var homePath: [HomeRoute] = []
    @State private var chartsPath: [ChartsRoute] = []
    @State private var accountsPath: [AccountsRoute] = []
    @State private var profilePath: [ProfileRoute] = []
    /// 语音记账的共享状态；麦克风可能在 Tab Bar 附属栏里，与各一级页面的会话卡片分属两处，由这里统一持有。
    @State private var voice = VoiceBookkeepingState()
    /// 余额走势的数据缓存，账户页、资产分析页和账户详情共用；切 Tab 时保留，回来不用重新汇总流水。
    @State private var balanceHistory = BalanceHistoryStore()
    /// 记账、账户、“我的”是否展开成两栏；由当前显示的两栏容器按可用宽度回报，几个 Tab 宽度相同，共用一个值。
    @State private var isSplitExpanded = false

    /// 冷启动落在哪个 Tab：用户选的启动页面；Debug 构建截 App Store 宣传图时按截图场景指定。
    private static var launchTab: AppTab {
        #if DEBUG
        if let tab = AppStoreScreenshotFixture.initialTab { return tab }
        #endif
        return AppStartPage.stored().tab
    }

    /// 是否允许联网；没注入同意状态时按允许处理。
    private var isNetworkAllowed: Bool {
        privacyAgreement?.allowsNetwork ?? true
    }

    /// 当前 Tab 的一级页面是否露在外面；语音入口和会话卡片只在一级页面出现。
    ///
    /// 各一级页面进入二级页面都走路径导航：单栏时路径为空即停在一级页面；两栏时左栏一直是一级页面，
    /// 只有右栏最上面的页面自带底栏时收起，规则见 `TabSplitLayout.showsRootAccessory(path:isExpanded:)`。图表始终是单栏。
    private var isAtTabRoot: Bool {
        switch selectedTab {
        case .home:
            TabSplitLayout.showsRootAccessory(path: homePath, isExpanded: isSplitExpanded)
        case .charts:
            chartsPath.isEmpty
        case .accounts:
            TabSplitLayout.showsRootAccessory(path: accountsPath, isExpanded: isSplitExpanded)
        case .profile:
            TabSplitLayout.showsRootAccessory(path: profilePath, isExpanded: isSplitExpanded)
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
        // 麦克风在四个一级页面常显，进入二级页面时收起；离线模式（没同意隐私政策）下不显示
        .voiceMicAccessoryIfAvailable(isEnabled: isAtTabRoot && isNetworkAllowed, voice: voice)
        // 系统 Tab Bar 原地重排时图标与标题会错位，顺序变化时整体重建；
        // 各导航路径保存在本视图，重建后仍然保留。
        .id(startPage)
        // 会话、计时与弹层挂在 .id 外面，重排 Tab 时不会重建
        .voiceBookkeepingHost(voice)
        // 走势缓存挂在语音弹层外面：账户 Tab 和语音卡片、AI 对话里弹出的账户详情都要读它
        .environment(balanceHistory)
        // App 启动、回到前台、换账号或退出登录时刷新意见反馈的未读数；退出登录时清零
        .task(id: FeedbackUnreadTrigger(
            userID: authStore.userID,
            isActive: scenePhase == .active,
            isNetworkAllowed: isNetworkAllowed
        )) {
            guard scenePhase == .active else { return }
            await feedback?.refreshUnread()
        }
        // 当前 Tab 往下进页面时收起会话卡片；只按导航路径变深判断，切到停在二级页面的 Tab 不算
        .onChange(of: homePath.count) { oldDepth, newDepth in
            closeVoiceCardIfPushed(on: .home, from: oldDepth, to: newDepth)
        }
        .onChange(of: chartsPath.count) { oldDepth, newDepth in
            closeVoiceCardIfPushed(on: .charts, from: oldDepth, to: newDepth)
        }
        .onChange(of: accountsPath.count) { oldDepth, newDepth in
            closeVoiceCardIfPushed(on: .accounts, from: oldDepth, to: newDepth)
        }
        .onChange(of: profilePath.count) { oldDepth, newDepth in
            closeVoiceCardIfPushed(on: .profile, from: oldDepth, to: newDepth)
        }
        // 卡片上点了一笔流水：回到记账页根页面，由记账页取走请求并定位；路径变浅不会收起卡片。
        // 两栏时记账页一直在左栏，右栏（可能是填到一半的记一笔）不用动
        .onChange(of: voice.pendingLocate) { _, change in
            guard change != nil else { return }
            if !isSplitExpanded {
                homePath = []
            }
            selectedTab = .home
        }
        // 引导盖在首页上，写入时首页不整棵重建，只在这里切到选好的启动页面；挂在 .id 外面，重排 Tab 时不会漏掉
        .onChange(of: isOnboardingCompleted) { _, isCompleted in
            guard isCompleted else { return }
            selectedTab = startPage.tab
        }
    }

    /// 当前 Tab 往下进了页面时收起语音卡片；对话段不结束，内容仍在聊天页。
    ///
    /// 只是切到一个停在二级页面的 Tab 时路径不变，卡片保留：卡片和麦克风随页面收起，回到一级页面时卡片还在，
    /// 闲置计时照常进行。从图表点“记一笔”会同时切到记账页并进入记账表单，这时记账页路径变深，同样收起卡片。
    /// - Parameters:
    ///   - tab: 路径发生变化的 Tab。
    ///   - oldDepth: 变化前的导航深度。
    ///   - newDepth: 变化后的导航深度。
    private func closeVoiceCardIfPushed(on tab: AppTab, from oldDepth: Int, to newDepth: Int) {
        guard tab == selectedTab, newDepth > oldDepth else { return }
        voice.closeCard()
    }

    /// 记账页路由对应的页面；右栏根页面和右栏里推入的页面共用。
    ///
    /// - Parameter route: 记账页路由。
    @ViewBuilder
    private func homeDestination(_ route: HomeRoute) -> some View {
        switch route {
        case .expenseEntry:
            HomeExpenseEntryPage(draft: nil)
        case let .repeatEntry(draft):
            HomeExpenseEntryPage(draft: draft)
        case .search:
            // 搜索页里点开的详情在右栏里往下推
            BookkeepingSearchView { transactionID in
                homePath.append(.transactionDetail(transactionID))
            }
        case let .transactionDetail(transactionID):
            BookkeepingTransactionDetailView(transactionID: transactionID)
        }
    }

    /// 各一级 Tab 的根页面及其导航。
    ///
    /// 记账、账户、“我的”用两栏容器：窄屏收成一栏，与原来的导航栈一致；宽屏左栏是一级页面、右栏是二级页面。图表始终是单栏导航栈。
    @ViewBuilder
    private func content(for tab: AppTab) -> some View {
        switch tab {
        case .home:
            TabSplitNavigation(path: $homePath, onExpandedChange: { isSplitExpanded = $0 }) {
                HomeView { draft in
                    // 长按流水选「再记一笔」：两栏时换掉右栏
                    homePath = TabSplitPath.opening(HomeRoute.repeatEntry(draft))
                }
            } placeholder: {
                TabDetailPlaceholder(messageKey: "app.split.placeholder.home") {
                    HandDrawnSlipIllustration()
                }
            } destination: { route in
                homeDestination(route)
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
            TabSplitNavigation(path: $accountsPath, onExpandedChange: { isSplitExpanded = $0 }) {
                AccountListView()
                    .voiceBookkeepingDock()
            } placeholder: {
                TabDetailPlaceholder(messageKey: "app.split.placeholder.accounts") {
                    HandDrawnCardIllustration()
                }
            } destination: { route in
                switch route {
                case let .detail(accountID):
                    AccountDetailView(accountID: accountID)
                case let .transactionDetail(transactionID):
                    BookkeepingTransactionDetailView(transactionID: transactionID)
                case .assetAnalysis:
                    AssetAnalysisView()
                case .itemValuation:
                    ItemValuationDetailView()
                }
            }
        case .profile:
            TabSplitNavigation(path: $profilePath, onExpandedChange: { isSplitExpanded = $0 }) {
                ProfileView()
                    .voiceBookkeepingDock()
            } placeholder: {
                TabDetailPlaceholder(messageKey: "app.split.placeholder.profile") {
                    // 与“我的”页末尾的品牌落款同一个标记，深浅色各有一份
                    Image(.brandMark)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 56, height: 56)
                        .accessibilityHidden(true)
                }
            } destination: { route in
                route.destination
            }
        }
    }
}

/// 记账页导航里的新增页面，保存到本地账本。
///
/// 作为右栏根页面时，保存或关闭后用容器的关闭动作清空路径：两栏展开时 `dismiss()` 对右栏根页面没有效果。
/// 不是右栏根页面时（取不到关闭动作）沿用页面自己的 `dismiss()`。
private struct HomeExpenseEntryPage: View {
    @Environment(\.modelContext) private var modelContext
    /// 右栏根页面关掉自己的动作；不是右栏根页面时为 nil。
    @Environment(\.tabDetailClose) private var closeDetail

    /// 预填好的草稿；为空时新建一笔。
    let draft: DiningExpenseDraft?

    var body: some View {
        DiningExpenseEntryView(draft: draft, onFinish: finishAction) { draft in
            let repository = LocalExpenseRepository(
                container: modelContext.container
            )
            try repository.save(draft)
        }
        // 关闭动作已经交给 onFinish，表单里的弹层不再继承
        .environment(\.tabDetailClose, nil)
    }

    /// 保存或关闭后的收尾：右栏根页面清空路径，其他情况交给页面自己的 `dismiss()`。
    private var finishAction: (@MainActor () -> Void)? {
        guard let closeDetail else { return nil }
        return { closeDetail() }
    }
}

/// 触发刷新意见反馈未读数的条件：账号变化、App 回到前台，或同意隐私政策后允许联网。
private struct FeedbackUnreadTrigger: Equatable {
    /// 当前登录账号；退出登录时为 nil。
    let userID: String?

    /// App 是否在前台。
    let isActive: Bool

    /// 是否允许联网；同意隐私政策后变为 true，立即重新刷新一次。
    let isNetworkAllowed: Bool
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
