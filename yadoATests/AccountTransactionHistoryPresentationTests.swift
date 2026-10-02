import Foundation
import SwiftData
import Testing
@testable import yadoA

@Suite("账户流水查询与展示", .serialized)
@MainActor
struct AccountTransactionHistoryPresentationTests {
    @Test("共享查询只返回当前账户并混排两种流水")
    func descriptorFiltersAccountAndAppliesStableOrdering() throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let firstAccountID = UUID()
        let secondAccountID = UUID()
        try saveAccount(id: firstAccountID, name: "账户 A", in: dataContainer.modelContainer)
        try saveAccount(id: secondAccountID, name: "账户 B", in: dataContainer.modelContainer)
        let repository = LocalExpenseRepository(container: dataContainer.modelContainer)
        let baseSavedAt = Date(timeIntervalSince1970: 1_786_608_000)
        let futureID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
        let adjustmentID = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
        let newestSameDayID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let equalTimeFirstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let equalTimeSecondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let pastID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

        try saveExpense(
            id: pastID,
            accountID: firstAccountID,
            transactionDay: 20260806,
            savedAt: baseSavedAt.addingTimeInterval(300),
            repository: repository
        )
        try saveExpense(
            id: equalTimeSecondID,
            accountID: firstAccountID,
            transactionDay: 20260813,
            savedAt: baseSavedAt,
            repository: repository
        )
        try saveExpense(
            id: futureID,
            accountID: firstAccountID,
            transactionDay: 20260814,
            savedAt: baseSavedAt,
            repository: repository
        )
        try saveExpense(
            id: equalTimeFirstID,
            accountID: firstAccountID,
            transactionDay: 20260813,
            savedAt: baseSavedAt,
            repository: repository
        )
        try saveExpense(
            id: newestSameDayID,
            accountID: firstAccountID,
            transactionDay: 20260813,
            savedAt: baseSavedAt.addingTimeInterval(60),
            repository: repository
        )
        try saveExpense(
            id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
            accountID: secondAccountID,
            transactionDay: 20991231,
            savedAt: baseSavedAt.addingTimeInterval(600),
            repository: repository
        )
        let context = ModelContext(dataContainer.modelContainer)
        context.autosaveEnabled = false
        context.insert(
            try AccountTransaction.validatingBalanceAdjustment(
                id: adjustmentID,
                accountID: firstAccountID,
                balanceBefore: 950,
                balanceAfter: 1_000,
                transactionDay: 20260813,
                savedAt: baseSavedAt.addingTimeInterval(120)
            )
        )
        try context.save()

        let queryContext = ModelContext(dataContainer.modelContainer)
        let transactions = try queryContext.fetch(
            AccountTransactionHistoryPresentation.descriptor(accountID: firstAccountID)
        )

        #expect(transactions.allSatisfy { $0.accountID == firstAccountID })
        #expect(
            transactions.map(\.id) == [
                futureID,
                adjustmentID,
                newestSameDayID,
                equalTimeFirstID,
                equalTimeSecondID,
                pastID
            ]
        )
    }

    @Test("中英文展示餐饮负向金额日期且空备注保持缺省")
    func rowLocalizesDiningAndPreservesOptionalNote() throws {
        let amount = try #require(Decimal(string: "12.34"))
        let withNote = try AccountTransaction.validatingDiningExpense(
            id: UUID(),
            accountID: UUID(),
            amount: amount,
            transactionDay: 20260813,
            note: "  午餐  "
        )
        let withoutNote = try AccountTransaction.validatingDiningExpense(
            id: UUID(),
            accountID: UUID(),
            amount: 8,
            transactionDay: 20260813,
            note: " \n "
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let englishLocale = Locale(identifier: "en_US")
        let chineseLocale = Locale(identifier: "zh-Hans")

        let english = try #require(
            AccountTransactionHistoryPresentation.row(
                for: withNote,
                locale: englishLocale,
                calendar: calendar
            )
        )
        let chinese = try #require(
            AccountTransactionHistoryPresentation.row(
                for: withNote,
                locale: chineseLocale,
                calendar: calendar
            )
        )
        let blankNote = try #require(
            AccountTransactionHistoryPresentation.row(
                for: withoutNote,
                locale: chineseLocale,
                calendar: calendar
            )
        )

        #expect(english.title == "Dining")
        #expect(chinese.title == "餐饮")
        #expect(
            english.formattedAmount == (-amount).formatted(
                .currency(code: "CNY").locale(englishLocale)
            )
        )
        #expect(english.balanceTransition == nil)
        #expect(english.formattedDate.contains("2026"))
        #expect(chinese.formattedDate.contains("8"))
        #expect(english.note == "午餐")
        #expect(blankNote.note == nil)
    }

    @Test("余额调整展示显式差额与前后余额")
    func balanceAdjustmentShowsSignedDeltaAndTransition() throws {
        let positive = try AccountTransaction.validatingBalanceAdjustment(
            id: UUID(),
            accountID: UUID(),
            balanceBefore: 100,
            balanceAfter: 120,
            transactionDay: 20260813,
            note: "校准"
        )
        let negative = try AccountTransaction.validatingBalanceAdjustment(
            id: UUID(),
            accountID: UUID(),
            balanceBefore: 40,
            balanceAfter: -10,
            transactionDay: 20260813
        )
        let englishLocale = Locale(identifier: "en_US")
        let chineseLocale = Locale(identifier: "zh-Hans")

        let positiveRow = try #require(
            AccountTransactionHistoryPresentation.row(for: positive, locale: englishLocale)
        )
        let negativeRow = try #require(
            AccountTransactionHistoryPresentation.row(for: negative, locale: chineseLocale)
        )

        #expect(positiveRow.title == "Balance Adjustment")
        #expect(positiveRow.formattedAmount.hasPrefix("+"))
        #expect(positiveRow.formattedAmount.contains("20"))
        #expect(positiveRow.balanceTransition?.contains("100") == true)
        #expect(positiveRow.balanceTransition?.contains("120") == true)
        #expect(positiveRow.balanceTransition?.contains("→") == true)
        #expect(positiveRow.accessibilityLabel.contains("Balance Adjustment"))
        #expect(positiveRow.accessibilityLabel.contains("Balance changed from"))
        #expect(negativeRow.title == "余额调整")
        #expect(
            negativeRow.formattedAmount == Decimal(-50).formatted(
                .currency(code: "CNY").locale(chineseLocale)
            )
        )
        #expect(negativeRow.balanceTransition?.contains("-10") == true)
        #expect(negativeRow.accessibilityLabel.contains("余额从"))
        #expect(negativeRow.note == nil)
    }

    /// 保存一个真实账户，供跨账户查询集成测试使用。
    private func saveAccount(
        id: UUID,
        name: String,
        in container: ModelContainer
    ) throws {
        let repository = LocalAccountRepository(container: container)
        try repository.save(
            AccountDraft(
                id: id,
                accountType: .cash,
                name: name,
                amountText: "1000"
            ),
            locale: Locale(identifier: "en_US")
        )
    }

    /// 通过真实仓库保存一笔可指定日期与并列键的餐饮支出。
    private func saveExpense(
        id: UUID,
        accountID: UUID,
        transactionDay: Int,
        savedAt: Date,
        repository: LocalExpenseRepository
    ) throws {
        try repository.save(
            DiningExpenseDraft(
                id: id,
                accountID: accountID,
                amountText: "10",
                transactionDay: transactionDay
            ),
            savedAt: savedAt
        )
    }
}
