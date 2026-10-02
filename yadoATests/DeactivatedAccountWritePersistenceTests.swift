import Foundation
import SwiftData
import Testing
@testable import yadoA

@Suite("停用账户写入边界", .serialized)
@MainActor
struct DeactivatedAccountWritePersistenceTests {
    @Test("支出和余额调整都在最终保存边界拒绝停用账户")
    func financialWritesRejectDeactivatedAccount() throws {
        let container = try AccountDataContainer.inMemory()
        let repository = LocalAccountRepository(container: container.modelContainer)
        let accountID = UUID()
        try repository.save(
            AccountDraft(id: accountID, accountType: .cash, name: "现金", amountText: "0"),
            locale: Locale(identifier: "en_US")
        )

        let context = ModelContext(container.modelContainer)
        let targetID = accountID
        let account = try #require(
            context.fetch(
                FetchDescriptor<Account>(
                    predicate: #Predicate<Account> { account in
                        account.id == targetID
                    }
                )
            ).first
        )
        account.deactivatedAt = Date(timeIntervalSince1970: 30)
        try context.save()

        #expect(throws: ExpenseRepositoryError.accountDeactivated(accountID)) {
            try LocalExpenseRepository(container: container.modelContainer).save(
                DiningExpenseDraft(accountID: accountID, amountText: "1", transactionDay: 20260821)
            )
        }
        #expect(throws: BalanceAdjustmentRepositoryError.accountDeactivated(accountID)) {
            try LocalBalanceAdjustmentRepository(container: container.modelContainer).save(
                BalanceAdjustmentDraft(accountID: accountID, amountText: "1")
            )
        }
        #expect(try ModelContext(container.modelContainer).fetchCount(FetchDescriptor<AccountTransaction>()) == 0)
    }

    @Test("未知账户类型不能绕过财务写入边界")
    func financialWritesRejectUnknownAccountType() throws {
        let container = try AccountDataContainer.inMemory()
        let context = ModelContext(container.modelContainer)
        let accountID = UUID()
        context.insert(
            Account(
                id: accountID,
                typeRawValue: "futureAccountType",
                templateID: nil,
                name: "未知账户",
                note: nil,
                lastFourDigits: nil,
                balance: .zero,
                currencyCode: "CNY",
                createdAt: .now,
                updatedAt: .now
            )
        )
        try context.save()

        #expect(throws: ExpenseRepositoryError.unsupportedAccountType("futureAccountType")) {
            try LocalExpenseRepository(container: container.modelContainer).save(
                DiningExpenseDraft(accountID: accountID, amountText: "1", transactionDay: 20260821)
            )
        }
        #expect(throws: BalanceAdjustmentRepositoryError.unsupportedAccountType("futureAccountType")) {
            try LocalBalanceAdjustmentRepository(container: container.modelContainer).save(
                BalanceAdjustmentDraft(accountID: accountID, amountText: "1")
            )
        }
        #expect(try ModelContext(container.modelContainer).fetchCount(FetchDescriptor<AccountTransaction>()) == 0)
    }
}
