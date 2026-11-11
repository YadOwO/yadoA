import Foundation
import Testing
@testable import yadoA

@Suite("登录入口")
struct AuthLocalizationTests {
    @Test("回调地址 scheme 全小写，与两套 Logto 的应用配置一致")
    func redirectUriSchemeIsLowercased() {
        let prodScheme = URL(string: AuthConfig.prod.redirectUri)?.scheme
        #expect(prodScheme == "com.yado.yadoa")
        let devScheme = URL(string: AuthConfig.dev.redirectUri)?.scheme
        #expect(devScheme == "com.yado.yadoa.dev")
        let currentScheme = URL(string: AuthConfig.redirectUri)?.scheme
        #expect(currentScheme == currentScheme?.lowercased())
    }

    @Test("dev 与线上是两套互不相干的登录和后端地址")
    func environmentsDoNotShareEndpoints() {
        let dev = AuthConfig.dev
        let prod = AuthConfig.prod
        #expect(dev.endpoint != prod.endpoint)
        #expect(dev.appId != prod.appId)
        #expect(dev.redirectUri != prod.redirectUri)
        #expect(dev.aiServiceEndpoint != prod.aiServiceEndpoint)
        #expect(dev.syncServiceEndpoint != prod.syncServiceEndpoint)
        #expect(dev.hubServiceEndpoint != prod.hubServiceEndpoint)
        // 所有地址都必须是合法的 https 地址，写错会在启动时触发 preconditionFailure
        for values in [dev, prod] {
            for text in [values.endpoint, values.aiServiceEndpoint, values.syncServiceEndpoint, values.hubServiceEndpoint] {
                #expect(URL(string: text)?.scheme == "https")
                #expect(URL(string: text)?.host() != nil)
            }
        }
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
            "auth.sign_in.headline",
            "auth.sign_in.password",
            "auth.sign_in.coming_soon",
            "auth.sign_in.local_note",
            "auth.sign_in.success",
        ]
        for key in keys {
            #expect(AccountLocalization.string(key, locale: english) != key)
            #expect(AccountLocalization.string(key, locale: simplifiedChinese) != key)
        }
    }

    @Test("登录权益都有中英文文案，语音记账原因只突出语音那一行")
    func signInBenefitsAreLocalized() {
        let english = Locale(identifier: "en")
        let simplifiedChinese = Locale(identifier: "zh-Hans")

        for benefit in SignInBenefit.allCases {
            #expect(AccountLocalization.string(benefit.titleLocalizationKey, locale: english) != benefit.titleLocalizationKey)
            #expect(AccountLocalization.string(benefit.titleLocalizationKey, locale: simplifiedChinese) != benefit.titleLocalizationKey)
        }
        #expect(SignInBenefit.allCases.filter { $0.highlightedReason == .voiceBookkeeping } == [.voice])
    }

    @Test("第三方登录方式都有中英文文案，连接器 target 不为空")
    func socialProvidersAreLocalized() {
        let english = Locale(identifier: "en")
        let simplifiedChinese = Locale(identifier: "zh-Hans")

        for provider in AuthSocialProvider.allCases {
            #expect(!provider.connectorTarget.isEmpty)
            #expect(AccountLocalization.string(provider.titleLocalizationKey, locale: english) != provider.titleLocalizationKey)
            #expect(AccountLocalization.string(provider.titleLocalizationKey, locale: simplifiedChinese) != provider.titleLocalizationKey)
        }
    }
}
