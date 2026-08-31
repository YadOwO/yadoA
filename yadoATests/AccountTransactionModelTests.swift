import Foundation
import SwiftData
import Testing
@testable import yadoA

@Suite("AccountTransaction 模型转换")
struct AccountTransactionModelTests {
    @Test("全部支出分类都能通过统一载荷往返", arguments: ExpenseCategory.allCases)
    func everyExpenseCategoryRoundTrips(category: ExpenseCategory) throws {
        let amount = try #require(Decimal(string: "12.34"))
        let transaction = try AccountTransaction.validatingExpense(
            id: UUID(),
            accountID: UUID(),
            category: category,
            amount: amount,
            transactionDay: 20260831
        )

        #expect(ExpenseCategory.allCases.count == 16)
        #expect(transaction.typeRawValue == "diningExpense")
        #expect(transaction.transactionType == .expense)
        #expect(transaction.category == category)
        #expect(
            try transaction.validatedPayload()
                == .expense(category: category, amount: amount)
        )
    }

    @Test("有效餐饮流水精确保留字段并清理备注")
    func validDiningExpenseKeepsExactFields() throws {
        let id = UUID()
        let accountID = UUID()
        let savedAt = Date(timeIntervalSince1970: 1_786_608_000)
        let amount = try #require(Decimal(string: "23.40"))

        let transaction = try AccountTransaction.validatingDiningExpense(
            id: id,
            accountID: accountID,
            amount: amount,
            transactionDay: 20260813,
            title: "  午餐  ",
            note: "  午餐\n",
            savedAt: savedAt
        )

        #expect(transaction.id == id)
        #expect(transaction.accountID == accountID)
        #expect(transaction.typeRawValue == AccountTransactionType.expense.rawValue)
        #expect(transaction.transactionType == .expense)
        #expect(transaction.categoryRawValue == ExpenseCategory.dining.rawValue)
        #expect(transaction.category == .dining)
        #expect(transaction.amount == amount)
        #expect(transaction.title == "午餐")
        #expect(transaction.balanceBefore == nil)
        #expect(transaction.balanceAfter == nil)
        #expect(transaction.balanceDelta == nil)
        #expect(transaction.currencyCode == "CNY")
        #expect(transaction.transactionDay == 20260813)
        #expect(transaction.note == "午餐")
        #expect(transaction.savedAt == savedAt)
    }

    @Test("空白标题保存为 nil")
    func blankTitleBecomesNil() throws {
        let transaction = try AccountTransaction.validatingDiningExpense(
            id: UUID(),
            accountID: UUID(),
            amount: 1,
            transactionDay: 20260813,
            title: " \n\t"
        )

        #expect(transaction.title == nil)
    }

    @Test(
        "空白备注保存为 nil",
        arguments: ["", " ", "\n\t"]
    )
    func blankNoteBecomesNil(blank: String) throws {
        let transaction = try AccountTransaction.validatingDiningExpense(
            id: UUID(),
            accountID: UUID(),
            amount: 1,
            transactionDay: 20260813,
            note: blank
        )

        #expect(transaction.note == nil)
    }

    @Test(
        "无效餐饮金额不会生成流水",
        arguments: ["0", "-1", "1.001"]
    )
    func invalidDiningAmountIsRejected(rawAmount: String) throws {
        let amount = try #require(Decimal(string: rawAmount))

        #expect(throws: AccountTransactionValidationError.invalidAmount) {
            try AccountTransaction.validatingDiningExpense(
                id: UUID(),
                accountID: UUID(),
                amount: amount,
                transactionDay: 20260813
            )
        }
    }

    @Test("等值的两位小数金额可以生成餐饮流水")
    func equivalentTwoFractionDigitAmountIsAccepted() throws {
        let amount = try #require(Decimal(string: "1.230"))

        let transaction = try AccountTransaction.validatingDiningExpense(
            id: UUID(),
            accountID: UUID(),
            amount: amount,
            transactionDay: 20260813
        )

        #expect(transaction.amount == Decimal(string: "1.23"))
    }

    @Test("余额调整精确保存调整前后值与正差额")
    func balanceAdjustmentKeepsPositiveDeltaSnapshot() throws {
        let transaction = try AccountTransaction.validatingBalanceAdjustment(
            id: UUID(),
            accountID: UUID(),
            balanceBefore: 100,
            balanceAfter: 120,
            transactionDay: 20260813,
            note: "  补齐利息  "
        )

        #expect(transaction.transactionType == .balanceAdjustment)
        #expect(transaction.categoryRawValue == nil)
        #expect(transaction.category == nil)
        #expect(transaction.amount == nil)
        #expect(transaction.balanceBefore == Decimal(100))
        #expect(transaction.balanceAfter == Decimal(120))
        #expect(transaction.balanceDelta == Decimal(20))
        #expect(transaction.note == "补齐利息")
    }

    @Test("余额调整支持负数目标与负差额")
    func balanceAdjustmentKeepsNegativeTargetAndDelta() throws {
        let transaction = try AccountTransaction.validatingBalanceAdjustment(
            id: UUID(),
            accountID: UUID(),
            balanceBefore: 40,
            balanceAfter: -10,
            transactionDay: 20260813
        )

        #expect(transaction.balanceBefore == Decimal(40))
        #expect(transaction.balanceAfter == Decimal(-10))
        #expect(transaction.balanceDelta == Decimal(-50))
    }

    @Test("相同前后余额和超出 CNY 精度的快照会被拒绝")
    func invalidBalanceAdjustmentSnapshotIsRejected() {
        #expect(throws: AccountTransactionValidationError.self) {
            try AccountTransaction.validatingBalanceAdjustment(
                id: UUID(),
                accountID: UUID(),
                balanceBefore: 100,
                balanceAfter: 100,
                transactionDay: 20260813
            )
        }
        #expect(throws: AccountTransactionValidationError.self) {
            try AccountTransaction.validatingBalanceAdjustment(
                id: UUID(),
                accountID: UUID(),
                balanceBefore: Decimal(string: "100.001")!,
                balanceAfter: 120,
                transactionDay: 20260813
            )
        }
    }

    @Test("差额与前后余额不自洽时不会生成流水")
    func inconsistentBalanceDeltaIsRejected() {
        #expect(throws: AccountTransactionValidationError.invalidBalanceAdjustment) {
            try AccountTransaction.validatingPersistedFields(
                id: UUID(),
                accountID: UUID(),
                typeRawValue: AccountTransactionType.balanceAdjustment.rawValue,
                categoryRawValue: nil,
                amount: nil,
                balanceBefore: 100,
                balanceAfter: 120,
                balanceDelta: 99,
                transactionDay: 20260813
            )
        }
    }

    @Test("未知类型和两类流水字段混用时会被拒绝")
    func unknownTypeAndMixedPayloadAreRejected() {
        #expect(throws: AccountTransactionValidationError.unknownType("futureType")) {
            try AccountTransaction.validatingPersistedFields(
                id: UUID(),
                accountID: UUID(),
                typeRawValue: "futureType",
                categoryRawValue: ExpenseCategory.dining.rawValue,
                amount: 10,
                balanceBefore: nil,
                balanceAfter: nil,
                balanceDelta: nil,
                transactionDay: 20260813
            )
        }
        #expect(throws: AccountTransactionValidationError.invalidPayload) {
            try AccountTransaction.validatingPersistedFields(
                id: UUID(),
                accountID: UUID(),
                typeRawValue: AccountTransactionType.expense.rawValue,
                categoryRawValue: ExpenseCategory.dining.rawValue,
                amount: 10,
                balanceBefore: 100,
                balanceAfter: 110,
                balanceDelta: 10,
                transactionDay: 20260813
            )
        }
        #expect(throws: AccountTransactionValidationError.invalidPayload) {
            try AccountTransaction.validatingPersistedFields(
                id: UUID(),
                accountID: UUID(),
                typeRawValue: AccountTransactionType.balanceAdjustment.rawValue,
                categoryRawValue: ExpenseCategory.dining.rawValue,
                amount: 10,
                balanceBefore: 100,
                balanceAfter: 110,
                balanceDelta: 10,
                transactionDay: 20260813
            )
        }
    }

    @Test(
        "无效公历记账日不会生成流水",
        arguments: [20260229, 20261301, 20260800, 2026081]
    )
    func invalidTransactionDayIsRejected(transactionDay: Int) {
        #expect(throws: AccountTransactionValidationError.invalidTransactionDay) {
            try AccountTransaction.validatingDiningExpense(
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
        let earlierDay = try AccountTransaction.validatingDiningExpense(
            id: UUID(),
            accountID: UUID(),
            amount: 1,
            transactionDay: 20260812,
            savedAt: laterSave
        )
        let laterDay = try AccountTransaction.validatingDiningExpense(
            id: UUID(),
            accountID: UUID(),
            amount: 1,
            transactionDay: 20260813,
            savedAt: earlierSave
        )

        #expect(laterDay.transactionDay > earlierDay.transactionDay)
        #expect(laterDay.savedAt < earlierDay.savedAt)
    }

    @Test("完整内存容器能同时持久化两类账户流水")
    @MainActor
    func inMemoryContainerPersistsBothTransactionTypes() throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let context = ModelContext(dataContainer.modelContainer)
        context.autosaveEnabled = false
        let dining = try AccountTransaction.validatingDiningExpense(
            id: UUID(),
            accountID: UUID(),
            amount: 12.34,
            transactionDay: 20260813
        )
        let adjustment = try AccountTransaction.validatingBalanceAdjustment(
            id: UUID(),
            accountID: UUID(),
            balanceBefore: 100,
            balanceAfter: 120,
            transactionDay: 20260813
        )

        context.insert(dining)
        context.insert(adjustment)
        try context.save()

        let savedTransactions = try context.fetch(FetchDescriptor<AccountTransaction>())
        #expect(Set(savedTransactions.map(\.id)) == Set([dining.id, adjustment.id]))
        #expect(dataContainer.modelContainer.schema.version == .init(5, 0, 0))
    }
}
