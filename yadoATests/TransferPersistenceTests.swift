import Foundation
import SwiftData
import Testing
@testable import yadoA

@Suite("转账持久化边界", .serialized)
@MainActor
struct TransferPersistenceTests {
    @Test("借记卡还信用卡：转出余额减少，信用卡欠款减少")
    func transferUpdatesBothBalancesByAccountSemantics() throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let debitID = UUID()
        let creditID = UUID()
        try saveAccount(id: debitID, accountType: .debitCard, amountText: "1000", in: dataContainer.modelContainer)
        try saveAccount(id: creditID, accountType: .creditCard, amountText: "300", in: dataContainer.modelContainer)
        let draft = TransferDraft(
            fromAccountID: debitID,
            toAccountID: creditID,
            amountText: "200",
            transactionDay: 20261022,
            note: "还款"
        )

        try LocalTransferRepository(container: dataContainer.modelContainer).save(draft)

        let context = dataContainer.modelContainer.makeManualSaveContext()
        #expect(try context.account(id: debitID)?.balance == 800)
        #expect(try context.account(id: creditID)?.balance == 100)
        let transaction = try #require(try context.transaction(id: draft.id))
        #expect(transaction.accountID == debitID)
        #expect(transaction.counterpartAccountID == creditID)
        #expect(transaction.transactionDay == 20261022)
        #expect(transaction.note == "还款")
    }

    @Test("删除转账把两边余额都恢复原样")
    func deletingTransferRestoresBalances() throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let cashID = UUID()
        let walletID = UUID()
        try saveAccount(id: cashID, accountType: .cash, amountText: "50", in: dataContainer.modelContainer)
        try saveAccount(id: walletID, accountType: .virtualAccount, amountText: "10", in: dataContainer.modelContainer)
        let repository = LocalTransferRepository(container: dataContainer.modelContainer)
        let draft = TransferDraft(
            fromAccountID: cashID,
            toAccountID: walletID,
            amountText: "20.5",
            transactionDay: 20261022
        )
        try repository.save(draft)

        try repository.delete(id: draft.id)

        let context = dataContainer.modelContainer.makeManualSaveContext()
        #expect(try context.account(id: cashID)?.balance == 50)
        #expect(try context.account(id: walletID)?.balance == 10)
        #expect(try context.transaction(id: draft.id) == nil)
        #expect(throws: TransferRepositoryError.transactionNotFound(draft.id)) {
            try repository.delete(id: draft.id)
        }
    }

    @Test("同一账户、缺少金额或停用账户不能转账，且不产生写入")
    func invalidTransfersAreRejectedWithoutSideEffects() throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let cashID = UUID()
        let bankID = UUID()
        try saveAccount(id: cashID, accountType: .cash, amountText: "0", in: dataContainer.modelContainer)
        try saveAccount(id: bankID, accountType: .debitCard, amountText: "100", in: dataContainer.modelContainer)
        let repository = LocalTransferRepository(container: dataContainer.modelContainer)

        #expect(throws: TransferRepositoryError.invalidDraft) {
            try repository.save(
                TransferDraft(fromAccountID: bankID, toAccountID: bankID, amountText: "10", transactionDay: 20261022)
            )
        }
        #expect(throws: TransferRepositoryError.invalidDraft) {
            try repository.save(
                TransferDraft(fromAccountID: bankID, toAccountID: cashID, amountText: "", transactionDay: 20261022)
            )
        }

        // 余额为零的现金账户可以停用，停用后不能再转入。
        let accountRepository = LocalAccountRepository(container: dataContainer.modelContainer)
        let plan = try accountRepository.disposalPlan(for: cashID)
        try accountRepository.dispose(
            AccountDisposalExpectation(
                accountID: cashID,
                action: .deactivate,
                expectedDefaultAccountID: plan.defaultAccountID,
                replacementAccountID: plan.isCurrentDefault ? bankID : nil,
                allowsNoDefault: false
            )
        )
        #expect(throws: TransferRepositoryError.accountDeactivated(cashID)) {
            try repository.save(
                TransferDraft(fromAccountID: bankID, toAccountID: cashID, amountText: "10", transactionDay: 20261022)
            )
        }

        let context = dataContainer.modelContainer.makeManualSaveContext()
        #expect(try context.account(id: bankID)?.balance == 100)
        #expect(try context.fetchCount(FetchDescriptor<AccountTransaction>()) == 0)
    }

    @Test("转入的账户也算有流水，不能被永久删除")
    func incomingTransferBlocksPermanentDeletion() throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let sourceID = UUID()
        let targetID = UUID()
        try saveAccount(id: sourceID, accountType: .cash, amountText: "100", in: dataContainer.modelContainer)
        try saveAccount(id: targetID, accountType: .cash, amountText: "0", in: dataContainer.modelContainer)
        try LocalTransferRepository(container: dataContainer.modelContainer).save(
            TransferDraft(fromAccountID: sourceID, toAccountID: targetID, amountText: "30", transactionDay: 20261022)
        )

        let plan = try LocalAccountRepository(container: dataContainer.modelContainer).disposalPlan(for: targetID)

        #expect(plan.transactionCount == 1)
        #expect(!plan.canPermanentlyDelete)
    }

    @Test("保存失败时两边余额和流水一起回滚")
    func failedSaveRollsBackEverything() throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let sourceID = UUID()
        let targetID = UUID()
        try saveAccount(id: sourceID, accountType: .cash, amountText: "100", in: dataContainer.modelContainer)
        try saveAccount(id: targetID, accountType: .cash, amountText: "0", in: dataContainer.modelContainer)
        struct InjectedFailure: Error {}
        let repository = LocalTransferRepository(container: dataContainer.modelContainer) {
            throw InjectedFailure()
        }

        #expect(throws: InjectedFailure.self) {
            try repository.save(
                TransferDraft(fromAccountID: sourceID, toAccountID: targetID, amountText: "30", transactionDay: 20261022)
            )
        }

        let context = dataContainer.modelContainer.makeManualSaveContext()
        #expect(try context.account(id: sourceID)?.balance == 100)
        #expect(try context.account(id: targetID)?.balance == 0)
        #expect(try context.fetchCount(FetchDescriptor<AccountTransaction>()) == 0)
    }

    /// 通过既有账户仓库保存符合当前类型约束的账户。
    private func saveAccount(
        id: UUID,
        accountType: AccountType,
        amountText: String,
        in container: ModelContainer
    ) throws {
        try LocalAccountRepository(container: container).save(
            AccountDraft(
                id: id,
                accountType: accountType,
                template: accountType.requiresTemplateSelection ? accountType.templates.first : nil,
                name: accountType.rawValue,
                amountText: amountText
            ),
            locale: Locale(identifier: "en_US")
        )
    }
}
