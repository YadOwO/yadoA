import Foundation
import Testing
@testable import yadoA

@Suite("应用一级导航")
struct AppTabViewTests {
    @Test("当前提供首页、图表和账户三个入口且默认进入首页")
    func exposesThreeTabsAndStartsOnHome() {
        #expect(AppTab.allCases == [.home, .charts, .accounts])
        #expect(AppTab.initial == .home)
        #expect(AppTab.home.symbolName == "house")
        #expect(AppTab.charts.symbolName == "chart.bar.xaxis")
        #expect(AppTab.accounts.symbolName == "creditcard")
    }

    @Test("Tab 与首页占位文案支持中英文")
    func navigationLocalizationHonorsExplicitLocale() {
        let english = Locale(identifier: "en")
        let simplifiedChinese = Locale(identifier: "zh-Hans")

        #expect(AppTab.home.title(locale: english) == "Home")
        #expect(AppTab.home.title(locale: simplifiedChinese) == "首页")
        #expect(AppTab.charts.title(locale: english) == "Charts")
        #expect(AppTab.charts.title(locale: simplifiedChinese) == "图表")
        #expect(AppTab.accounts.title(locale: english) == "Accounts")
        #expect(AppTab.accounts.title(locale: simplifiedChinese) == "账户")
        #expect(
            AccountLocalization.string("home.overview.title", locale: english)
                == "Financial Overview"
        )
        #expect(
            AccountLocalization.string("home.overview.title", locale: simplifiedChinese)
                == "财务总览"
        )
    }
}
