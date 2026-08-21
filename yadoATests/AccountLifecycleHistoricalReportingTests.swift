import Foundation
import SwiftData
import Testing
@testable import yadoA

@Suite("账户生命周期历史回归", .serialized)
@MainActor
struct AccountLifecycleHistoricalReportingTests {
    @Test("停用零余额账户不会改变 Home、Charts 或详情历史")
    func deactivationPreservesHistoricalReporting() throws {
        let container = try AccountDataContainer.inMemory()
        let accountID = UUID()
        let repository = LocalAccountRepository(container: container.modelContainer)
        try repository.save(
            AccountDraft(id: accountID, accountType: .cash, name: "历史现金", amountText: "30"),
            locale: Locale(identifier: "en_US")
        )
        try LocalExpenseRepository(container: container.modelContainer).save(
            DiningExpenseDraft(
                accountID: accountID,
                amountText: "10",
                transactionDay: 20260821
            )
        )
        _ = try LocalBalanceAdjustmentRepository(container: container.modelContainer).save(
            BalanceAdjustmentDraft(
                accountID: accountID,
                amountText: "0",
                note: "归零后停用"
            ),
            now: date(year: 2026, month: 8, day: 21),
            calendar: utcCalendar
        )

        let beforeTransactions = try transactions(in: container.modelContainer)
        let beforeHome = HomeOverviewPresentation(
            transactions: beforeTransactions,
            now: date(year: 2026, month: 8, day: 21),
            calendar: utcCalendar,
            locale: Locale(identifier: "en_US")
        )
        let month = try #require(HomeMonth(year: 2026, month: 8))
        let beforeMonth = beforeHome.presentation(for: month)
        let beforeChart = ChartOverviewPresentation(
            period: .month,
            anchorDate: date(year: 2026, month: 8, day: 21),
            transactions: beforeTransactions,
            calendar: utcCalendar,
            locale: Locale(identifier: "en_US")
        )

        try repository.dispose(
            AccountDisposalExpectation(
                accountID: accountID,
                action: .deactivate,
                expectedDefaultAccountID: accountID,
                replacementAccountID: nil,
                allowsNoDefault: true
            )
        )

        let afterTransactions = try transactions(in: container.modelContainer)
        let afterHome = HomeOverviewPresentation(
            transactions: afterTransactions,
            now: date(year: 2026, month: 8, day: 21),
            calendar: utcCalendar,
            locale: Locale(identifier: "en_US")
        )
        let afterMonth = afterHome.presentation(for: month)
        let afterChart = ChartOverviewPresentation(
            period: .month,
            anchorDate: date(year: 2026, month: 8, day: 21),
            transactions: afterTransactions,
            calendar: utcCalendar,
            locale: Locale(identifier: "en_US")
        )

        #expect(afterTransactions.map(\.id) == beforeTransactions.map(\.id))
        #expect(afterMonth == beforeMonth)
        #expect(afterChart == beforeChart)
        let history = try ModelContext(container.modelContainer).fetch(
            AccountTransactionHistoryPresentation.descriptor(accountID: accountID)
        )
        #expect(history.map(\.id) == beforeTransactions.map(\.id))
        #expect(try AccountListPresentation.sorted(repository.accounts()).isEmpty)
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    private func date(year: Int, month: Int, day: Int) -> Date {
        utcCalendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func transactions(in container: ModelContainer) throws -> [AccountTransaction] {
        try ModelContext(container).fetch(HomeOverviewPresentation.descriptor())
    }
}
