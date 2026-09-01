import SwiftData
import SwiftUI

/// 应用当前提供的一级导航入口。
enum AppTab: String, CaseIterable, Hashable {
    /// 首页财务总览入口。
    case home

    /// 周、月、年支出图表入口。
    case charts

    /// 本地账户管理入口。
    case accounts

    /// 跨账户记账搜索入口；iOS 26 会以系统分割 Search Tab 展示。
    case search

    /// 应用启动时默认展示首页。
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
            "house"
        case .charts:
            "chart.bar.xaxis"
        case .accounts:
            "creditcard"
        case .search:
            "magnifyingglass"
        }
    }

    /// 当前语言环境下的 Tab 标题。
    func title(locale: Locale = .current) -> String {
        AccountLocalization.string(titleLocalizationKey, locale: locale)
    }
}

/// 首页导航栈支持的二级页面。
enum HomeRoute: Hashable {
    /// 新增支出页面。
    case expenseEntry
}

/// 账户导航栈支持的二级页面。
enum AccountsRoute: Hashable {
    /// 指定账户的详情页面。
    case detail(UUID)
}

/// 搜索导航栈支持的二级页面。
enum SearchRoute: Hashable {
    /// 指定流水的详情页面。
    case transactionDetail(UUID)
}

/// 应用根级导航；iOS 26 将搜索分割展示，iOS 18 保持普通系统 Tab 样式。
struct AppTabView: View {
    @Environment(\.locale) private var locale
    @Environment(\.modelContext) private var modelContext
    @State private var selectedTab: AppTab = .initial
    @State private var homePath: [HomeRoute] = []
    @State private var accountsPath: [AccountsRoute] = []
    @State private var searchPath: [SearchRoute] = []

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab(value: AppTab.home) {
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
                            }
                        }
                }
            } label: {
                Label(AppTab.home.title(locale: locale), systemImage: AppTab.home.symbolName)
            }

            Tab(value: AppTab.charts) {
                NavigationStack {
                    ChartView()
                }
            } label: {
                Label(AppTab.charts.title(locale: locale), systemImage: AppTab.charts.symbolName)
            }

            Tab(value: AppTab.accounts) {
                NavigationStack(path: $accountsPath) {
                    AccountListView()
                        .navigationDestination(for: AccountsRoute.self) { route in
                            switch route {
                            case let .detail(accountID):
                                AccountDetailView(accountID: accountID)
                                    .secondaryPage()
                            }
                        }
                }
            } label: {
                Label(AppTab.accounts.title(locale: locale), systemImage: AppTab.accounts.symbolName)
            }

            Tab(value: AppTab.search, role: .search) {
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
            } label: {
                Label(AppTab.search.title(locale: locale), systemImage: AppTab.search.symbolName)
            }
        }
        .tabBarMinimizeOnScrollDownIfAvailable()
    }
}

#Preview {
    AppTabView()
        .modelContainer(
            for: [Account.self, AccountTransaction.self, BookkeepingPreference.self],
            inMemory: true
        )
}
