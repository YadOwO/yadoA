import Foundation
import Testing
@testable import yadoA

@Suite("应用一级导航")
struct AppTabViewTests {
    @Test("当前只提供首页和账户两个入口且默认进入首页")
    func exposesTwoTabsAndStartsOnHome() {
        #expect(AppTab.allCases == [.home, .accounts])
        #expect(AppTab.initial == .home)
        #expect(AppTab.home.symbolName == "house")
        #expect(AppTab.accounts.symbolName == "creditcard")
    }

    @Test("Tab 与首页占位文案支持中英文")
    func navigationLocalizationHonorsExplicitLocale() {
        let english = Locale(identifier: "en")
        let simplifiedChinese = Locale(identifier: "zh-Hans")

        #expect(AppTab.home.title(locale: english) == "Home")
        #expect(AppTab.home.title(locale: simplifiedChinese) == "首页")
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
