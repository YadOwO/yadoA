import XCTest

/// 账户页顶部备份提醒卡片的 UI 流程。
///
/// 假设模拟器上这个 dev 包没有开启云同步；不尝试操作系统分享面板。
final class BackupReminderFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaterButtonHidesReminderCard() throws {
        let app = launchBackupReminderFixtureInEnglish()
        openAccountsTab(in: app)

        let card = app.descendants(matching: .any)["account-list-backup-reminder"]
        XCTAssertTrue(card.waitForExistence(timeout: 3))

        let later = app.buttons["account-list-backup-reminder-later"]
        XCTAssertTrue(later.exists)
        later.tap()

        // 点「以后再说」后暂缓 30 天，卡片马上消失，另一个按钮也不会被误触发
        let disappeared = NSPredicate(format: "exists == false")
        expectation(for: disappeared, evaluatedWith: card)
        waitForExpectations(timeout: 3)
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    @MainActor
    func testBackupNowShowsConfirmationAndCancelKeepsReminderCard() throws {
        let app = launchBackupReminderFixtureInEnglish()
        openAccountsTab(in: app)

        let card = app.descendants(matching: .any)["account-list-backup-reminder"]
        XCTAssertTrue(card.waitForExistence(timeout: 3))

        let backup = app.buttons["account-list-backup-reminder-backup"]
        XCTAssertTrue(backup.exists)
        backup.tap()

        // 和导出入口共用同一个确认弹窗。
        // iOS 26/27 的系统弹窗会把同一个标识同时挂在外层和里面的按钮上，直接查询会命中两个元素，tap() 抛 Multiple matching elements，所以用 firstMatch
        let confirm = app.alerts.buttons["account-management-export-confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        let cancel = app.alerts.buttons["account-management-export-cancel"].firstMatch
        XCTAssertTrue(cancel.exists)
        cancel.tap()

        // 取消不算备份，卡片仍在
        XCTAssertFalse(confirm.waitForExistence(timeout: 1))
        XCTAssertTrue(card.exists)
    }
}
