import Foundation
import SwiftData
import Testing
@testable import yadoA

/// 记账提速：预选最近分类、“再记一笔”和首页流水可否删除。
@Suite("记账快捷操作")
@MainActor
struct BookkeepingQuickEntryTests {
    // MARK: - 打字入口

    @Test("未登录点打字入口询问是否去登录，不打开输入框")
    func textInputRequiresSignIn() {
        let voice = VoiceBookkeepingState()

        voice.beginTextInput(isSignedIn: false)

        #expect(voice.input.alert == .signInRequired)
        #expect(!voice.isTextInputPresented)
    }

    @Test("已登录点打字入口打开输入框")
    func textInputOpensWhenSignedIn() {
        let voice = VoiceBookkeepingState()

        voice.beginTextInput(isSignedIn: true)

        #expect(voice.input.alert == nil)
        #expect(voice.isTextInputPresented)
    }
}
