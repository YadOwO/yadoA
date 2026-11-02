import Foundation
import Testing
@testable import yadoA

@Suite("应用一级导航")
struct AppTabViewTests {
    @Test("当前提供记账、图表、账户和我的四个入口且默认进入记账页")
    func exposesFourTabsAndStartsOnHome() {
        #expect(AppTab.allCases == [.home, .charts, .accounts, .profile])
        #expect(AppTab.initial == .home)
        #expect(AppTab.home.symbolName == "book")
        #expect(AppTab.charts.symbolName == "chart.bar.xaxis")
        #expect(AppTab.accounts.symbolName == "creditcard")
        #expect(AppTab.profile.symbolName == "person.crop.circle")
    }

    @Test("Tab 与记账页占位文案支持中英文")
    func navigationLocalizationHonorsExplicitLocale() {
        let english = Locale(identifier: "en")
        let simplifiedChinese = Locale(identifier: "zh-Hans")

        #expect(AppTab.home.title(locale: english) == "Ledger")
        #expect(AppTab.home.title(locale: simplifiedChinese) == "记账")
        #expect(AppTab.charts.title(locale: english) == "Charts")
        #expect(AppTab.charts.title(locale: simplifiedChinese) == "图表")
        #expect(AppTab.accounts.title(locale: english) == "Accounts")
        #expect(AppTab.accounts.title(locale: simplifiedChinese) == "账户")
        #expect(AppTab.profile.title(locale: english) == "Profile")
        #expect(AppTab.profile.title(locale: simplifiedChinese) == "我的")
        #expect(AccountLocalization.string("bookkeeping.search.title", locale: english) == "Search")
        #expect(
            AccountLocalization.string("bookkeeping.search.title", locale: simplifiedChinese) == "搜索记账"
        )
        #expect(
            AccountLocalization.string("home.overview.title", locale: english)
                == "Financial Overview"
        )
        #expect(
            AccountLocalization.string("home.overview.title", locale: simplifiedChinese)
                == "财务总览"
        )
    }

    @Test("启动页面可选记账或账户，未设置或值无效时回退记账页")
    func startPageResolvesStoredPreference() throws {
        let suiteName = "AppTabViewTests.startPage"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(AppStartPage.allCases == [.home, .accounts])
        #expect(AppStartPage.stored(in: defaults) == .home)

        defaults.set(AppStartPage.accounts.rawValue, forKey: AppStartPage.storageKey)
        #expect(AppStartPage.stored(in: defaults) == .accounts)
        #expect(AppStartPage.stored(in: defaults).tab == .accounts)

        defaults.set("charts", forKey: AppStartPage.storageKey)
        #expect(AppStartPage.stored(in: defaults) == .home)
    }

    @Test("启动页面对应的 Tab 排在第一位，其余顺序不变且我的在最右")
    func tabOrderPutsStartPageFirst() {
        #expect(AppTab.ordered(startingWith: .home) == [.home, .charts, .accounts, .profile])
        #expect(AppTab.ordered(startingWith: .accounts) == [.accounts, .home, .charts, .profile])
        #expect(AppTab.ordered(startingWith: .profile) == AppTab.allCases)
    }

    @Test("启动页面设置文案支持中英文")
    func startPageLocalizationHonorsExplicitLocale() {
        let english = Locale(identifier: "en")
        let simplifiedChinese = Locale(identifier: "zh-Hans")

        #expect(AccountLocalization.string("profile.start_page.title", locale: english) == "Open on Launch")
        #expect(AccountLocalization.string("profile.start_page.title", locale: simplifiedChinese) == "启动页面")
        #expect(
            AccountLocalization.string(AppStartPage.accounts.titleLocalizationKey, locale: simplifiedChinese)
                == "账户"
        )
    }
}
