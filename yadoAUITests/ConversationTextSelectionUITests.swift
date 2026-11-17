import XCTest

/// 验证对话正文可以长按拷贝；用 AI 对话夹具写入的本机记录，不发请求。
///
/// 意见反馈和语音卡片的内容来自服务端和模型，自动化里造不出来，需要真机验收；三处用的是同一个 `conversationTextSelection()`。
/// 气泡底色和选中颜色无法用无障碍树断言，同样需要真机在浅色、深色外观下各看一遍。
final class ConversationTextSelectionUITests: XCTestCase {
    /// 夹具里用户说的话，与 `AIChatUITestFixture` 一致。
    private let userText = "Lunch with friends 30"

    /// 夹具里的回复，与 `AIChatUITestFixture` 一致。
    private let replyText = "Noted. Anything else to log?"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLongPressUserMessageOffersCopy() {
        let app = launchAIChatFixtureInEnglish()
        longPressAndAssertCopyOffered(on: app.staticTexts[userText], in: app)
    }

    @MainActor
    func testLongPressReplyOffersCopy() {
        let app = launchAIChatFixtureInEnglish()
        longPressAndAssertCopyOffered(on: app.staticTexts[replyText], in: app)
    }

    /// 拷贝后粘贴到输入框，确认文字真的进了剪贴板。
    ///
    /// iOS 27 起长按可能只选中其中一段，因此只要求粘贴出来的是原文的一部分。
    @MainActor
    func testCopiedMessageCanBePastedIntoComposer() {
        let app = launchAIChatFixtureInEnglish()
        longPressAndAssertCopyOffered(on: app.staticTexts[userText], in: app)
        app.menuItems["Copy"].tap()

        let field = app.descendants(matching: .any)["voice-chat-field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        // 输入框聚焦后再点一下才弹出粘贴
        field.tap()
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 3))
        paste.tap()

        // 没粘上时读到的是占位文字，同样会让下面的断言失败
        let pasted = field.value as? String ?? ""
        XCTAssertFalse(pasted.isEmpty)
        XCTAssertTrue(userText.contains(pasted), "Pasted text should come from the message, got: \(pasted)")
    }

    /// 长按一段文字，等系统菜单里出现“拷贝”。
    ///
    /// - Parameters:
    ///   - text: 要长按的文字。
    ///   - app: 被测应用。
    @MainActor
    private func longPressAndAssertCopyOffered(on text: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.press(forDuration: 1.2)
        XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 3))
    }
}
