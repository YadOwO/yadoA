import Foundation
import Testing
@testable import yadoA

/// 设置页的语言选项，以及按简繁体区分的语言判断与语音识别语言换算。
@Suite("界面语言")
@MainActor
struct AppLanguageTests {
    /// 三种界面语言；新增面向用户的文案都要在这三种语言下有值。
    private let interfaceLocales = ["en", "zh-Hans", "zh-Hant"].map { Locale(identifier: $0) }

    @Test("语言选项依次是跟随系统、简体中文、繁体中文、英文，保存的值不变")
    func languageOptions() {
        #expect(AppLanguage.allCases == [.system, .simplifiedChinese, .traditionalChinese, .english])
        #expect(AppLanguage(rawValue: "zh-Hant") == .traditionalChinese)
        #expect(AppLanguage(rawValue: "zh-Hans") == .simplifiedChinese)
        #expect(AppLanguage(rawValue: "en") == .english)
    }

    @Test("选繁体中文时界面用 zh-Hant，并真的取到繁体文案")
    func traditionalChineseResolvesToHant() {
        let locale = AppLanguage.traditionalChinese.resolvedLocale(systemLocale: Locale(identifier: "en_US"))
        #expect(locale.identifier(.bcp47) == "zh-Hant")
        #expect(locale.isTraditionalChinese)
        #expect(AccountLocalization.string("app.tab.home", locale: locale) == "記帳")
        #expect(AccountLocalization.string("account.list.title", locale: locale) == "帳戶")
    }

    @Test("每个语言选项在三种界面语言下都有标题；语言名用各自的写法")
    func everyOptionHasTitle() {
        for language in AppLanguage.allCases {
            let key = language.titleLocalizationKey
            for locale in interfaceLocales {
                #expect(AccountLocalization.string(key, locale: locale) != key)
            }
        }
        for locale in interfaceLocales {
            #expect(AccountLocalization.string(AppLanguage.traditionalChinese.titleLocalizationKey, locale: locale) == "繁體中文")
            #expect(AccountLocalization.string(AppLanguage.simplifiedChinese.titleLocalizationKey, locale: locale) == "简体中文")
        }
    }

    @Test("写明繁体，或没写文字但地区默认繁体时，认作繁体中文")
    func detectsTraditionalChinese() {
        for identifier in ["zh-Hant", "zh-Hant-TW", "zh-Hant-HK", "zh_TW", "zh-HK", "zh-MO"] {
            #expect(Locale(identifier: identifier).isTraditionalChinese, "\(identifier)")
        }
        for identifier in ["zh-Hans", "zh-Hans-CN", "zh", "zh_CN", "zh-Hans-HK", "en", "en_TW", "ja"] {
            #expect(!Locale(identifier: identifier).isTraditionalChinese, "\(identifier)")
        }
    }

    @Test("繁体中文的语音识别按设备地区选：港澳先试粤语，其他地区用台湾国语；其他语言不换算")
    func speechRecognitionCandidates() {
        /// 候选识别语言的 BCP 47 写法，便于比较。
        func candidates(_ identifier: String, region: String?) -> [String] {
            VoiceSpeechLocale.preferredLocales(
                for: Locale(identifier: identifier),
                deviceRegion: region.map { Locale.Region($0) }
            ).map { $0.identifier(.bcp47) }
        }

        #expect(candidates("zh-Hant", region: "TW") == ["zh-TW"])
        #expect(candidates("zh-Hant", region: "HK") == ["zh-HK", "zh-TW"])
        #expect(candidates("zh-Hant", region: "MO") == ["zh-HK", "zh-TW"])
        #expect(candidates("zh-Hant", region: "US") == ["zh-TW"])
        #expect(candidates("zh-Hant", region: nil) == ["zh-TW"])
        // 设备地区优先于界面语言自带的地区；取不到设备地区时才看界面语言
        #expect(candidates("zh-Hant-HK", region: "TW") == ["zh-TW"])
        #expect(candidates("zh-Hant-HK", region: nil) == ["zh-HK", "zh-TW"])
        // 简体中文、英文照旧直接用界面语言
        #expect(candidates("zh-Hans", region: "TW").isEmpty)
        #expect(candidates("zh-Hans", region: "HK").isEmpty)
        #expect(candidates("en", region: "HK").isEmpty)
    }
}
