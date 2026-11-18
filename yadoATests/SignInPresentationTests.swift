import Foundation
import Testing
@testable import yadoA

/// 未登录点需要登录的功能时，先询问再打开登录页的状态流转。
@Suite("登录询问弹窗")
@MainActor
struct SignInPresentationTests {
    @Test("requestSignIn 只记下待询问原因，不直接打开登录页")
    func requestOnlyPrompts() {
        let presentation = SignInPresentation()
        presentation.requestSignIn(reason: .checkIn)

        #expect(presentation.pendingPromptReason == .checkIn)
        #expect(!presentation.isPresented)
    }

    @Test("确认后打开登录页，带上原因并清掉询问")
    func confirmPresentsSignIn() {
        let presentation = SignInPresentation()
        presentation.requestSignIn(reason: .feedback)
        presentation.present(reason: .feedback)

        #expect(presentation.isPresented)
        #expect(presentation.reason == .feedback)
        #expect(presentation.pendingPromptReason == nil)
    }

    @Test("取消后不打开登录页")
    func cancelKeepsSignInClosed() {
        let presentation = SignInPresentation()
        presentation.requestSignIn(reason: .checkIn)
        presentation.cancelSignInPrompt()

        #expect(presentation.pendingPromptReason == nil)
        #expect(!presentation.isPresented)
    }

    @Test("每个原因的弹窗标题和说明都有中英文案", arguments: [SignInReason.voiceBookkeeping, .feedback, .checkIn])
    func promptCopyIsLocalized(reason: SignInReason) {
        for identifier in ["zh-Hans", "en"] {
            let locale = Locale(identifier: identifier)
            let title = AccountLocalization.string(reason.promptTitleLocalizationKey, locale: locale)
            let message = AccountLocalization.string(reason.messageLocalizationKey, locale: locale)
            #expect(title != reason.promptTitleLocalizationKey)
            #expect(message != reason.messageLocalizationKey)
        }
    }
}
