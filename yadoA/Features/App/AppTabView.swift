import SwiftData
import SwiftUI

/// 应用当前提供的一级导航入口。
enum AppTab: String, CaseIterable, Hashable {
    /// 首页财务总览入口。
    case home

    /// 本地账户管理入口。
    case accounts

    /// 应用启动时默认展示首页。
    static let initial: AppTab = .home

    /// Tab 标题对应的稳定本地化键。
    var titleLocalizationKey: String {
        switch self {
        case .home:
            "app.tab.home"
        case .accounts:
            "account.list.title"
        }
    }

    /// Tab 使用的系统语义图标。
    var symbolName: String {
        switch self {
        case .home:
            "house"
        case .accounts:
            "creditcard"
        }
    }

    /// 当前语言环境下的 Tab 标题。
    func title(locale: Locale = .current) -> String {
        AccountLocalization.string(titleLocalizationKey, locale: locale)
    }
}

/// 应用根级双 Tab 导航；iOS 26 使用原生液态玻璃 Tab Bar，iOS 18 保持普通系统样式。
struct AppTabView: View {
    @Environment(\.locale) private var locale
    @State private var selectedTab: AppTab = .initial

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab(value: AppTab.home) {
                HomeView()
            } label: {
                Label(AppTab.home.title(locale: locale), systemImage: AppTab.home.symbolName)
            }

            Tab(value: AppTab.accounts) {
                AccountListView()
            } label: {
                Label(AppTab.accounts.title(locale: locale), systemImage: AppTab.accounts.symbolName)
            }
        }
        .tabBarMinimizeOnScrollDownIfAvailable()
    }
}

#Preview {
    AppTabView()
        .modelContainer(
            for: [Account.self, ExpenseTransaction.self],
            inMemory: true
        )
}
