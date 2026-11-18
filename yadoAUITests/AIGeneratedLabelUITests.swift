import XCTest

/// 验证 AI 回复下面有「内容由 AI 生成，请核对」标注；用 AI 对话夹具写入的本机历史记录，不发请求。
///
/// 夹具里只有一轮已完成的历史回复，所以这里只覆盖聊天页的历史回复。
/// 语音卡片、查账卡片、用模型原话做标题的纸条、失败轮次（不该出现标注）、新一轮回复淡入之后才出现，
/// 以及深色外观下的显示，自动化里造不出来，需要真机验收。
final class AIGeneratedLabelUITests: XCTestCase {
    /// 夹具里的回复，与 `AIChatUITestFixture` 一致。
    private let replyText = "Noted. Anything else to log?"

    /// 英文环境下标注的完整文案。
    private let labelText = "AI-generated. Please double-check."

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testHistoryReplyShowsAIGeneratedLabel() {
        let app = launchAIChatFixtureInEnglish()
        XCTAssertTrue(app.staticTexts[replyText].waitForExistence(timeout: 5))

        let label = app.descendants(matching: .any)["ai-generated-label"].firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 3))
        XCTAssertEqual(label.label, labelText)
    }

    /// 夹具里只有一条 AI 回复；用户的话下面不该有标注，整页只应出现一处。
    @MainActor
    func testOnlyAIReplyHasAIGeneratedLabel() {
        let app = launchAIChatFixtureInEnglish()
        XCTAssertTrue(app.staticTexts[replyText].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["ai-generated-label"].firstMatch.waitForExistence(timeout: 3))

        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "ai-generated-label").count, 1)
    }
}
