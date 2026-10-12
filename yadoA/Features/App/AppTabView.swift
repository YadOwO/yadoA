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

    /// 跨账户记账搜索入口，使用系统原生搜索 Tab 外观。
    case search

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
        case .search:
            "bookkeeping.search.title"
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
        case .search:
            "magnifyingglass"
        }
    }

    /// 按启动页面重排底部导航：启动页面排第一，其余保持原有相对顺序，搜索始终在最后。
    ///
    /// - Parameter first: 用户选择的启动页面对应的 Tab。
    /// - Returns: 底部导航从左到右的 Tab 顺序。
    static func ordered(startingWith first: AppTab) -> [AppTab] {
        guard first != .search else { return allCases }
        return [first] + allCases.filter { $0 != first }
    }

    /// 当前语言环境下的 Tab 标题。
    func title(locale: Locale = .current) -> String {
        AccountLocalization.string(titleLocalizationKey, locale: locale)
    }
}

/// 记账页导航栈支持的二级页面。
enum HomeRoute: Hashable {
    /// 记账页临时账单入口。
    case bills

    /// 新增支出页面。
    case expenseEntry

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

/// 搜索导航栈支持的二级页面。
enum SearchRoute: Hashable {
    /// 指定流水的详情页面。
    case transactionDetail(UUID)
}

/// 应用根级导航，Tab 外观与搜索入口布局跟随系统版本。
struct AppTabView: View {
    @Environment(\.locale) private var locale
    @Environment(\.modelContext) private var modelContext
    /// 用户选择的启动页面；对应 Tab 排在底部导航第一位，修改后立即重排。
    @AppStorage(AppStartPage.storageKey) private var startPage: AppStartPage = .home
    /// 冷启动时落在用户选择的启动页面；之后在设置里修改不会打断当前所在 Tab。
    @State private var selectedTab: AppTab = AppStartPage.stored().tab
    @State private var homePath: [HomeRoute] = []
    @State private var accountsPath: [AccountsRoute] = []
    @State private var searchPath: [SearchRoute] = []

    var body: some View {
        TabView(selection: $selectedTab) {
            // 以 Tab 自身作为稳定标识，重排时保留各导航栈与已弹出的设置页。
            ForEach(AppTab.ordered(startingWith: startPage.tab), id: \.self) { tab in
                Tab(value: tab, role: tab == .search ? .search : nil) {
                    content(for: tab)
                } label: {
                    Label(tab.title(locale: locale), systemImage: tab.symbolName)
                }
            }
        }
        .tabBarMinimizeOnScrollDownIfAvailable()
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
                        case .bills:
                            BillView()
                                .secondaryPage()
                        case .expenseEntry:
                            DiningExpenseEntryView { draft in
                                let repository = LocalExpenseRepository(
                                    container: modelContext.container
                                )
                                try repository.save(draft)
                            }
                            .secondaryPage()
                        case let .transactionDetail(transactionID):
                            BookkeepingTransactionDetailView(transactionID: transactionID)
                                .secondaryPage()
                        }
                    }
            }
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
        case .search:
            NavigationStack(path: $searchPath) {
                BookkeepingSearchView { transactionID in
                    searchPath.append(.transactionDetail(transactionID))
                }
                .navigationDestination(for: SearchRoute.self) { route in
                    switch route {
                    case let .transactionDetail(transactionID):
                        BookkeepingTransactionDetailView(transactionID: transactionID)
                            .secondaryPage()
                    }
                }
            }
        }
    }
}

#Preview {
    AppTabView()
        .modelContainer(
            for: [Account.self, AccountTransaction.self, BookkeepingPreference.self],
            inMemory: true
        )
}
