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

    /// 跨账户记账搜索页面；搜索只针对记账流水，因此归在记账页下。
    case search

    /// 统一收支详情入口。
    case transactionDetail(UUID)
}

/// 账户导航栈支持的二级页面。
enum AccountsRoute: Hashable {
    /// 指定账户的详情页面。
    case detail(UUID)

    /// 账户历史中的统一收支详情入口。
    case transactionDetail(UUID)
}

/// 应用根级导航：记账、图表、账户与“我的”四个一级入口。
struct AppTabView: View {
    @Environment(\.locale) private var locale
    @Environment(\.modelContext) private var modelContext
    /// 用户选择的启动页面；对应 Tab 排在底部导航第一位，修改后立即重建并重排。
    @AppStorage(AppStartPage.storageKey) private var startPage: AppStartPage = .home
    /// 冷启动时落在用户选择的启动页面；之后在设置里修改不会打断当前所在 Tab。
    @State private var selectedTab: AppTab = AppStartPage.stored().tab
    @State private var homePath: [HomeRoute] = []
    @State private var accountsPath: [AccountsRoute] = []
    /// 记账页语音记账的共享状态；麦克风可能在 Tab Bar 附属栏里，与记账页的会话卡片分属两处，由这里统一持有。
    @State private var voice = VoiceBookkeepingState()

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(AppTab.ordered(startingWith: startPage.tab), id: \.self) { tab in
                Tab(value: tab) {
                    content(for: tab)
                } label: {
                    Label(tab.title(locale: locale), systemImage: tab.symbolName)
                }
            }
        }
        .tabBarMinimizeOnScrollDownIfAvailable()
        // 麦克风只在记账页根页面出现，进入二级页面或切到其他 Tab 时收起
        .voiceMicAccessoryIfAvailable(isEnabled: selectedTab == .home && homePath.isEmpty, voice: voice)
        // 系统 Tab Bar 原地重排时图标与标题会错位，顺序变化时整体重建；
        // 各导航路径保存在本视图，重建后仍然保留。
        .id(startPage)
    }

    /// 各一级 Tab 的根页面及其导航栈。
    @ViewBuilder
    private func content(for tab: AppTab) -> some View {
        switch tab {
        case .home:
            NavigationStack(path: $homePath) {
                HomeView()
                    .navigationDestination(for: HomeRoute.self) { route in
                        switch route {
                        case .expenseEntry:
                            DiningExpenseEntryView { draft in
                                let repository = LocalExpenseRepository(
                                    container: modelContext.container
                                )
                                try repository.save(draft)
                            }
                            .secondaryPage()
                        case .search:
                            BookkeepingSearchView { transactionID in
                                homePath.append(.transactionDetail(transactionID))
                            }
                            .secondaryPage()
                        case let .transactionDetail(transactionID):
                            BookkeepingTransactionDetailView(transactionID: transactionID)
                                .secondaryPage()
                        }
                    }
            }
            .environment(voice)
        case .charts:
            NavigationStack {
                ChartView {
                    // 记账入口只在记账页导航栈里，切过去后直接进入记一笔页面。
                    selectedTab = .home
                    homePath = [.expenseEntry]
                }
            }
        case .accounts:
            NavigationStack(path: $accountsPath) {
                AccountListView()
                    .navigationDestination(for: AccountsRoute.self) { route in
                        switch route {
                        case let .detail(accountID):
                            AccountDetailView(accountID: accountID)
                                .secondaryPage()
                        case let .transactionDetail(transactionID):
                            BookkeepingTransactionDetailView(transactionID: transactionID)
                                .secondaryPage()
                        }
                    }
            }
        case .profile:
            NavigationStack {
                ProfileView()
            }
        }
    }
}

#Preview {
    AppTabView()
        .environment(AuthStore())
        .modelContainer(
            for: [Account.self, AccountTransaction.self, BookkeepingPreference.self],
            inMemory: true
        )
}
