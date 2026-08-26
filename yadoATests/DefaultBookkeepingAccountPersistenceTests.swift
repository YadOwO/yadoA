import Foundation
import SwiftData
import Testing
@testable import yadoA

@Suite("默认记账账户持久化", .serialized)
@MainActor
struct DefaultBookkeepingAccountPersistenceTests {
    @Test("首个合格账户自动成为默认，非合格账户不会抢占默认")
    func firstEligibleAccountBecomesDefault() throws {
        let container = try AccountDataContainer.inMemory()
        let repository = LocalAccountRepository(container: container.modelContainer)

        try repository.save(
            AccountDraft(accountType: .investment, name: "证券", amountText: "10"),
            locale: Locale(identifier: "en_US")
        )
        #expect(try repository.defaultResolution() == .none)

        let cashID = UUID()
        try repository.save(
            AccountDraft(id: cashID, accountType: .cash, name: "现金", amountText: "20"),
            locale: Locale(identifier: "en_US")
        )
        #expect(try repository.defaultResolution() == .valid(cashID))

        let creditID = UUID()
        try repository.save(
            AccountDraft(
                id: creditID,
                accountType: .creditCard,
                template: AccountTemplate.creditInstitutions[0],
                name: "信用卡",
                amountText: "0"
            ),
            locale: Locale(identifier: "en_US")
        )
        #expect(try repository.defaultResolution() == .valid(cashID))
    }

    @Test("手动切换只接受启用合格账户，失败不改变旧默认")
    func switchingDefaultValidatesCandidate() throws {
        let container = try AccountDataContainer.inMemory()
        let repository = LocalAccountRepository(container: container.modelContainer)
        let cashID = UUID()
        let investmentID = UUID()

        try repository.save(
            AccountDraft(id: cashID, accountType: .cash, name: "现金", amountText: "10"),
            locale: Locale(identifier: "en_US")
        )
        try repository.save(
            AccountDraft(id: investmentID, accountType: .investment, name: "投资", amountText: "10"),
            locale: Locale(identifier: "en_US")
        )

        #expect(throws: AccountRepositoryError.invalidDefaultCandidate(investmentID)) {
            try repository.setDefaultAccount(id: investmentID)
        }
        #expect(try repository.defaultResolution() == .valid(cashID))
    }

    @Test("默认账户接替与停用在同一次保存中完成")
    func deactivationReplacesDefaultAtomically() throws {
        let container = try AccountDataContainer.inMemory()
        let repository = LocalAccountRepository(container: container.modelContainer)
        let accountID = UUID()
        let replacementID = UUID()

        try repository.save(
            AccountDraft(id: accountID, accountType: .cash, name: "现金", amountText: "1"),
            locale: Locale(identifier: "en_US")
        )
        try repository.save(
            AccountDraft(id: replacementID, accountType: .debitCard, template: AccountTemplate.banks(for: .debitCard)[0], name: "银行卡", amountText: "0"),
            locale: Locale(identifier: "en_US")
        )
        try LocalExpenseRepository(container: container.modelContainer).save(
            DiningExpenseDraft(accountID: accountID, amountText: "1", transactionDay: 20260821)
        )

        let expectation = AccountDisposalExpectation(
            accountID: accountID,
            action: .deactivate,
            expectedDefaultAccountID: accountID,
            replacementAccountID: replacementID,
            allowsNoDefault: false
        )
        try repository.dispose(expectation, now: Date(timeIntervalSince1970: 100))

        let account = try #require(try repository.account(id: accountID))
        #expect(account.isActive == false)
        #expect(account.deactivatedAt == Date(timeIntervalSince1970: 100))
        #expect(try repository.defaultResolution() == .valid(replacementID))
        #expect(try transactionCount(in: container.modelContainer) == 1)
    }

    @Test("处置确认期间出现新候选时要求刷新确认")
    func disposalRejectsStaleNoDefaultConfirmation() throws {
        let container = try AccountDataContainer.inMemory()
        let repository = LocalAccountRepository(container: container.modelContainer)
        let accountID = UUID()

        try repository.save(
            AccountDraft(id: accountID, accountType: .cash, name: "现金", amountText: "0"),
            locale: Locale(identifier: "en_US")
        )
        let plan = try repository.disposalPlan(for: accountID)
        #expect(plan.replacementCandidates.isEmpty)

        try repository.save(
            AccountDraft(
                accountType: .debitCard,
                template: AccountTemplate.banks(for: .debitCard)[0],
                name: "银行卡",
                amountText: "0"
            ),
            locale: Locale(identifier: "en_US")
        )

        #expect(throws: AccountRepositoryError.expectedStateChanged) {
            try repository.dispose(
                AccountDisposalExpectation(
                    accountID: plan.accountID,
                    action: .delete,
                    expectedDefaultAccountID: plan.defaultAccountID,
                    replacementAccountID: nil,
                    allowsNoDefault: true
                )
            )
        }
        #expect(try repository.account(id: accountID)?.isActive == true)
        #expect(try repository.defaultResolution() == .valid(accountID))
    }

    @Test("有流水账户不能永久删除，非零余额不能停用")
    func lifecycleGuardsHistoryAndBalance() throws {
        let container = try AccountDataContainer.inMemory()
        let repository = LocalAccountRepository(container: container.modelContainer)
        let accountID = UUID()

        try repository.save(
            AccountDraft(id: accountID, accountType: .cash, name: "现金", amountText: "10"),
            locale: Locale(identifier: "en_US")
        )
        let deleteExpectation = AccountDisposalExpectation(
            accountID: accountID,
            action: .delete,
            expectedDefaultAccountID: accountID,
            replacementAccountID: nil,
            allowsNoDefault: true
        )
        #expect(throws: AccountRepositoryError.nonZeroBalance(accountID)) {
            try repository.dispose(
                AccountDisposalExpectation(
                    accountID: accountID,
                    action: .deactivate,
                    expectedDefaultAccountID: accountID,
                    replacementAccountID: nil,
                    allowsNoDefault: true
                )
            )
        }

        try LocalExpenseRepository(container: container.modelContainer).save(
            DiningExpenseDraft(accountID: accountID, amountText: "1", transactionDay: 20260821)
        )
        #expect(throws: AccountRepositoryError.accountHasTransactions(accountID)) {
            try repository.dispose(deleteExpectation)
        }
    }

    @Test("停用账户恢复时，在没有有效默认的情况下自动成为默认")
    func restoreRepairsMissingDefault() throws {
        let container = try AccountDataContainer.inMemory()
        let accountID = UUID()
        let context = ModelContext(container.modelContainer)
        let account = Account(
            id: accountID,
            typeRawValue: AccountType.creditCard.rawValue,
            templateID: AccountTemplate.creditInstitutions[0].id,
            name: "信用卡",
            note: nil,
            lastFourDigits: nil,
            balance: 0,
            currencyCode: "CNY",
            createdAt: .now,
            updatedAt: .now,
            deactivatedAt: Date(timeIntervalSince1970: 10)
        )
        context.insert(account)
        context.insert(BookkeepingPreference(defaultAccountID: nil))
        try context.save()

        try LocalAccountRepository(container: container.modelContainer).restore(id: accountID)

        #expect(try accountByID(accountID, in: container.modelContainer)?.isActive == true)
        #expect(try LocalAccountRepository(container: container.modelContainer).defaultResolution() == .valid(accountID))
    }

    @Test("保存失败会回滚账户状态与默认接替")
    func failedLifecycleSaveRollsBackEverything() throws {
        let container = try AccountDataContainer.inMemory()
        let seed = LocalAccountRepository(container: container.modelContainer)
        let accountID = UUID()
        let replacementID = UUID()
        try seed.save(AccountDraft(id: accountID, accountType: .cash, name: "现金", amountText: "0"))
        try seed.save(AccountDraft(id: replacementID, accountType: .cash, name: "备用", amountText: "0"))

        let repository = LocalAccountRepository(
            container: container.modelContainer,
            beforeSave: { throw InjectedLifecycleSaveFailure() }
        )
        let expectation = AccountDisposalExpectation(
            accountID: accountID,
            action: .deactivate,
            expectedDefaultAccountID: accountID,
            replacementAccountID: replacementID,
            allowsNoDefault: false
        )

        #expect(throws: InjectedLifecycleSaveFailure.self) {
            try repository.dispose(expectation)
        }
        #expect(try accountByID(accountID, in: container.modelContainer)?.isActive == true)
        #expect(try repository.defaultResolution() == .valid(accountID))
    }

    private func accountByID(_ id: UUID, in container: ModelContainer) throws -> Account? {
        let targetID = id
        var descriptor = FetchDescriptor<Account>(
            predicate: #Predicate<Account> { account in
                account.id == targetID
            }
        )
        descriptor.fetchLimit = 1
        return try ModelContext(container).fetch(descriptor).first
    }

    private func transactionCount(in container: ModelContainer) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<AccountTransaction>())
    }
}

private struct InjectedLifecycleSaveFailure: Error {}
