import Foundation
import Testing
@testable import yadoA

@Suite("协议入口")
struct LegalDocumentTests {
    /// 英文环境。
    private let english = Locale(identifier: "en")
    /// 简体中文环境。
    private let simplifiedChinese = Locale(identifier: "zh-Hans")

    @Test("中文界面打开中文版，其他语言打开英文版；路径与网站、App Store Connect 填写的一致")
    func urlFollowsAppLanguage() {
        #expect(LegalDocument.privacy.url(locale: simplifiedChinese).absoluteString
            == "https://my.yado1225.top/zh/legal/yadoa/privacy/")
        #expect(LegalDocument.terms.url(locale: english).absoluteString
            == "https://my.yado1225.top/legal/yadoa/terms/")
        #expect(LegalDocument.sharing.url(locale: Locale(identifier: "zh-Hans-CN")).absoluteString
            == "https://my.yado1225.top/zh/legal/yadoa/sharing/")
        #expect(LegalDocument.sharing.url(locale: Locale(identifier: "ja")).absoluteString
            == "https://my.yado1225.top/legal/yadoa/sharing/")
    }

    @Test("同意文案的链接地址能认回对应文档，其他地址不认")
    func linkURLRoundTrips() {
        for document in LegalDocument.allCases {
            #expect(LegalDocument(linkURL: document.linkURL) == document)
        }
        #expect(LegalDocument(linkURL: URL(string: "https://my.yado1225.top/legal/yadoa/privacy/")!) == nil)
        #expect(LegalDocument(linkURL: URL(string: "yadoa-legal://unknown")!) == nil)
    }

    @Test("设置页的协议标题都有中英文文案")
    func titlesAreLocalized() {
        for document in LegalDocument.allCases {
            let key = document.titleLocalizationKey
            #expect(AccountLocalization.string(key, locale: english) != key)
            #expect(AccountLocalization.string(key, locale: simplifiedChinese) != key)
        }
    }

    @Test("登录页同意文案在中英文下都链到用户协议和隐私政策")
    func signInAgreementLinksBothDocuments() {
        for locale in [english, simplifiedChinese] {
            #expect(SignInAgreement.linkedDocuments(locale: locale) == [.terms, .privacy])
            // 解析后不应残留 Markdown 语法
            let plain = String(SignInAgreement.attributedText(locale: locale).characters)
            #expect(!plain.contains("]("))
            #expect(!plain.contains(LegalDocument.linkScheme))
        }
    }
}
