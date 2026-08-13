import Foundation
import SwiftData
import Testing
@testable import yadoA

@Suite("ExpenseTransaction 模型转换")
struct ExpenseTransactionModelTests {
    @Test("有效餐饮流水精确保留字段并清理备注")
    func validDiningExpenseKeepsExactFields() throws {
        let id = UUID()
        let accountID = UUID()
        let savedAt = Date(timeIntervalSince1970: 1_786_608_000)
        let amount = try #require(Decimal(string: "23.40"))

        let transaction = try ExpenseTransaction.validating(
            id: id,
            accountID: accountID,
            amount: amount,
            transactionDay: 20260813,
            note: "  午餐\n",
            savedAt: savedAt
        )

        #expect(transaction.id == id)
        #expect(transaction.accountID == accountID)
        #expect(transaction.categoryRawValue == ExpenseCategory.dining.rawValue)
        #expect(transaction.category == .dining)
        #expect(transaction.amount == amount)
        #expect(transaction.currencyCode == "CNY")
        #expect(transaction.transactionDay == 20260813)
        #expect(transaction.note == "午餐")
        #expect(transaction.savedAt == savedAt)
    }

    @Test(
        "空白备注保存为 nil",
        arguments: ["", " ", "\n\t"]
    )
    func blankNoteBecomesNil(blank: String) throws {
        let transaction = try ExpenseTransaction.validating(
            id: UUID(),
            accountID: UUID(),
            amount: 1,
            transactionDay: 20260813,
            note: blank
        )

        #expect(transaction.note == nil)
    }

    @Test(
        "无效支出金额不会生成流水",
        arguments: ["0", "-1", "1.001"]
    )
    func invalidAmountIsRejected(rawAmount: String) throws {
        let amount = try #require(Decimal(string: rawAmount))

        #expect(throws: ExpenseTransactionValidationError.invalidAmount) {
            try ExpenseTransaction.validating(
                id: UUID(),
                accountID: UUID(),
                amount: amount,
                transactionDay: 20260813
            )
        }
    }

    @Test("等值的两位小数金额可以生成流水")
    func equivalentTwoFractionDigitAmountIsAccepted() throws {
        let amount = try #require(Decimal(string: "1.230"))

        let transaction = try ExpenseTransaction.validating(
            id: UUID(),
            accountID: UUID(),
            amount: amount,
            transactionDay: 20260813
        )

        #expect(transaction.amount == Decimal(string: "1.23"))
    }

    @Test(
        "无效公历记账日不会生成流水",
        arguments: [20260229, 20261301, 20260800, 2026081]
    )
    func invalidTransactionDayIsRejected(transactionDay: Int) {
        #expect(throws: ExpenseTransactionValidationError.invalidTransactionDay) {
            try ExpenseTransaction.validating(
                id: UUID(),
                accountID: UUID(),
                amount: 1,
                transactionDay: transactionDay
            )
        }
    }

    @Test("记账日整数与保存时间支持独立排序")
    func transactionDayAndSavedAtRemainIndependent() throws {
        let earlierSave = Date(timeIntervalSince1970: 1_786_608_000)
        let laterSave = earlierSave.addingTimeInterval(60)
        let earlierDay = try ExpenseTransaction.validating(
            id: UUID(),
            accountID: UUID(),
            amount: 1,
            transactionDay: 20260812,
            savedAt: laterSave
        )
        let laterDay = try ExpenseTransaction.validating(
            id: UUID(),
            accountID: UUID(),
            amount: 1,
            transactionDay: 20260813,
            savedAt: earlierSave
        )

        #expect(laterDay.transactionDay > earlierDay.transactionDay)
        #expect(laterDay.savedAt < earlierDay.savedAt)
    }

    @Test("完整内存容器能够持久化餐饮流水")
    @MainActor
    func inMemoryContainerPersistsExpenseTransaction() throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let context = ModelContext(dataContainer.modelContainer)
        context.autosaveEnabled = false
        let transaction = try ExpenseTransaction.validating(
            id: UUID(),
            accountID: UUID(),
            amount: 12.34,
            transactionDay: 20260813
        )

        context.insert(transaction)
        try context.save()

        let savedTransactions = try context.fetch(FetchDescriptor<ExpenseTransaction>())
        #expect(savedTransactions.map(\.id) == [transaction.id])
        #expect(dataContainer.modelContainer.schema.version == .init(2, 0, 0))
    }
}
