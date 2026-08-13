import Foundation
import Testing
@testable import yadoA

@Suite("Account 模型转换")
struct AccountModelTests {
    @Test("账户类型明确区分资产扣减与债务增加")
    func accountTypesDefineExpenseBalanceEffect() {
        let valueTypes: [AccountType] = [
            .cash,
            .debitCard,
            .virtualAccount,
            .investment,
            .receivable,
            .customAsset
        ]

        for accountType in valueTypes {
            #expect(accountType.expenseBalanceEffect == .decreaseValue)
        }
        #expect(AccountType.creditCard.expenseBalanceEffect == .increaseDebt)
        #expect(AccountType.liability.expenseBalanceEffect == .increaseDebt)
    }

    @Test("信用卡金额保持正数与精确值")
    func creditCardKeepsPositiveExactBalance() throws {
        let id = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_786_435_200)
        let draft = AccountDraft(
            id: id,
            accountType: .creditCard,
            template: AccountTemplate.creditInstitutions[0],
            name: "  花呗日常  ",
            amountText: "2800"
        )

        let account = try Account.validating(
            draft: draft,
            locale: Locale(identifier: "en_US"),
            now: timestamp
        )

        #expect(account.id == id)
        #expect(account.typeRawValue == AccountType.creditCard.rawValue)
        #expect(account.accountType == .creditCard)
        #expect(account.balance == Decimal(2800))
        #expect(account.currencyCode == "CNY")
        #expect(account.createdAt == timestamp)
        #expect(account.updatedAt == timestamp)
    }

    @Test("展示字段会在持久化前清理")
    func displayFieldsAreSanitized() throws {
        let id = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_786_435_300)
        let template = AccountTemplate.banks(for: .debitCard)[0]
        let draft = AccountDraft(
            id: id,
            accountType: .debitCard,
            template: template,
            name: "  工资卡\n",
            note: "  仅用于工资  ",
            lastFourDigits: " 12a345 ",
            amountText: "0"
        )

        let account = try Account.validating(
            draft: draft,
            locale: Locale(identifier: "en_US"),
            now: timestamp
        )

        #expect(account.id == id)
        #expect(account.templateID == template.id)
        #expect(account.name == "工资卡")
        #expect(account.note == "仅用于工资")
        #expect(account.lastFourDigits == "1234")
        #expect(account.balance == 0)
    }

    @Test(
        "空白可选字段保存为 nil",
        arguments: ["", " ", "\n\t"]
    )
    func blankOptionalFieldsBecomeNil(blank: String) throws {
        let draft = AccountDraft(
            accountType: .cash,
            name: "现金",
            note: blank,
            lastFourDigits: blank,
            amountText: "1"
        )

        let account = try Account.validating(draft: draft)

        #expect(account.note == nil)
        #expect(account.lastFourDigits == nil)
    }

    @Test(
        "无效名称或金额不会生成账户",
        arguments: [
            ("   ", "1"),
            ("账户", ""),
            ("账户", "-1"),
            ("账户", "invalid")
        ]
    )
    func invalidDraftIsRejected(name: String, amountText: String) {
        let draft = AccountDraft(
            accountType: .customAsset,
            name: name,
            amountText: amountText
        )

        #expect(throws: AccountValidationError.self) {
            try Account.validating(
                draft: draft,
                locale: Locale(identifier: "en_US")
            )
        }
    }

    @Test("账户类型与模板必须匹配且必选类型不能缺少模板")
    func accountTypeAndTemplateMustMatch() {
        let missingTemplate = AccountDraft(
            accountType: .debitCard,
            name: "储蓄卡",
            amountText: "1"
        )
        let mismatchedTemplate = AccountDraft(
            accountType: .cash,
            template: AccountTemplate.virtualAccounts[0],
            name: "现金",
            amountText: "1"
        )

        #expect(throws: AccountValidationError.invalidTemplate) {
            try Account.validating(draft: missingTemplate)
        }
        #expect(throws: AccountValidationError.invalidTemplate) {
            try Account.validating(draft: mismatchedTemplate)
        }
    }

    @Test("未知持久化类型不会被误解为其他账户类型")
    func unknownPersistedTypeIsSafe() {
        let account = Account(
            id: UUID(),
            typeRawValue: "futureAccountType",
            templateID: nil,
            name: "未来账户",
            note: nil,
            lastFourDigits: nil,
            balance: 1,
            currencyCode: "CNY",
            createdAt: .now,
            updatedAt: .now
        )

        #expect(account.accountType == nil)
    }
}
