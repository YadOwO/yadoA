import XCTest

final class AccountListFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEmptyStateCreatesFirstAccountAndMovesAddActionToToolbar() throws {
        let app = launchIsolatedAppInEnglish()
        openAccountsTab(in: app)

        let emptyAdd = app.buttons["account-list-empty-add"]
        XCTAssertTrue(emptyAdd.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["account-list-toolbar-add"].exists)
        emptyAdd.tap()

        let cashType = app.descendants(matching: .any)["account-creation-type-cash"]
        XCTAssertTrue(cashType.waitForExistence(timeout: 3))
        cashType.tap()

        let amount = app.textFields["account-creation-amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 2))
        amount.tap()
        amount.typeText("40")

        let save = app.buttons["account-creation-save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()

        let accountRow = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "account-list-row-")
        ).firstMatch
        XCTAssertTrue(accountRow.waitForExistence(timeout: 3))
        XCTAssertFalse(emptyAdd.exists)
        // 账户按分类分组，现金账户在「现金」分组下。
        XCTAssertTrue(app.descendants(matching: .any)["account-list-section-cash"].exists)

        let summaryCard = app.descendants(matching: .any)["account-list-summary-card"]
        XCTAssertTrue(summaryCard.waitForExistence(timeout: 2))
        XCTAssertFalse(summaryCard.label.isEmpty)
        XCTAssertTrue(summaryCard.label.contains("40"))

        // 汇总卡片点进资产分析页：默认看净资产；切到资产后按账户排行，只有这一个现金账户。
        summaryCard.tap()
        let analysisBar = app.navigationBars["Net Worth Analysis"]
        XCTAssertTrue(analysisBar.waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["asset-analysis-debt-ratio-card"].exists)
        app.buttons["asset-analysis-tab-assets"].tap()
        let rankingRow = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "asset-analysis-ranking-")
        ).firstMatch
        XCTAssertTrue(rankingRow.waitForExistence(timeout: 2))
        analysisBar.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(summaryCard.waitForExistence(timeout: 3))

        // 有账户后，添加账户直接放在右上角；账户管理收在旁边的「更多」菜单里。
        XCTAssertTrue(app.buttons["account-list-toolbar-add"].waitForExistence(timeout: 2))
        var more = app.buttons["account-list-more"]
        if !more.exists {
            more = app.navigationBars["Accounts"].buttons["More"]
        }
        XCTAssertTrue(more.waitForExistence(timeout: 2))
        more.tap()
        // 系统菜单保留操作标题，但不会保留 SwiftUI 按钮的 identifier。只有一个账户时还不能转账。
        let management = app.buttons["Account Management"]
        XCTAssertTrue(management.waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["Transfer"].exists)
        XCTAssertTrue(management.exists)
        management.tap()
        XCTAssertTrue(app.buttons["account-management-choose-default"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["account-management-type-order"].exists)
        // 没有已停用账户时不显示入口。
        XCTAssertFalse(app.buttons["account-management-deactivated"].exists)
        app.buttons["account-management-close"].tap()

        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.tabBars.firstMatch.isHittable)
        // 分组标题也叫「Cash」，按行标识点进详情。
        accountRow.tap()

        XCTAssertTrue(app.navigationBars["Account Details"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.tabBars.firstMatch.exists, "账户详情保留 Tab Bar")
        XCTAssertEqual(app.staticTexts["account-detail-name"].label, "Cash")
        // 账户资料直接展示在余额下方，无需展开。
        XCTAssertEqual(
            app.descendants(matching: .any)["account-detail-type"].label,
            "Type, Cash"
        )

        let detailAmount = app.staticTexts["account-detail-amount"]
        XCTAssertTrue(detailAmount.waitForExistence(timeout: 2))
        XCTAssertTrue(detailAmount.label.contains("40"))
        XCTAssertTrue(detailAmount.label.contains("¥"))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Account balance overview"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.buttons["account-detail-adjust-balance"].tap()
        XCTAssertTrue(app.textFields["balance-adjustment-target"].waitForExistence(timeout: 2))
        app.buttons["balance-adjustment-cancel"].tap()
        XCTAssertTrue(detailAmount.waitForExistence(timeout: 2))

        app.navigationBars["Account Details"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(app.tabBars.buttons.count, 4)
    }
}
