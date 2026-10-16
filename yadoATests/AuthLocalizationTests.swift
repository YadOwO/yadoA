import Foundation
import Testing
@testable import yadoA

@Suite("登录入口")
struct AuthLocalizationTests {
    @Test("回调地址 scheme 全小写，与 Logto 应用配置一致")
    func redirectUriSchemeIsLowercased() {
        let scheme = URL(string: AuthConfig.redirectUri)?.scheme
        #expect(scheme == "com.yado.yadoa")
        #expect(scheme == scheme?.lowercased())
    }

    @Test("登录与退出文案支持中英文")
    func authLocalizationHonorsExplicitLocale() {
        let english = Locale(identifier: "en")
        let simplifiedChinese = Locale(identifier: "zh-Hans")

        #expect(AccountLocalization.string("auth.sign_in.action", locale: english) == "Sign In / Sign Up")
        #expect(AccountLocalization.string("auth.sign_in.action", locale: simplifiedChinese) == "登录 / 注册")
        #expect(AccountLocalization.string("auth.sign_out.action", locale: english) == "Sign Out")
        #expect(AccountLocalization.string("auth.sign_out.action", locale: simplifiedChinese) == "退出登录")

        let keys = [
            "auth.section.title",
            "auth.sign_in.failed",
            "auth.user.signed_in",
            "auth.sign_out.confirm.title",
            "auth.sign_out.confirm.message",
        ]
        for key in keys {
            #expect(AccountLocalization.string(key, locale: english) != key)
            #expect(AccountLocalization.string(key, locale: simplifiedChinese) != key)
        }
    }
}
