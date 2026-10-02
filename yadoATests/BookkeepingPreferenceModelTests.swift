import Foundation
import Testing
@testable import yadoA

@Suite("默认账户模型")
@MainActor
struct BookkeepingPreferenceModelTests {
    @Test("默认资格只覆盖四类支付账户")
    func defaultEligibilityIsExplicit() {
        let eligible: Set<AccountType> = [.cash, .debitCard, .creditCard, .virtualAccount]
        #expect(Set(AccountType.allCases.filter(\.isEligibleForDefault)) == eligible)
        #expect(AccountType.allCases.filter { !$0.isEligibleForDefault }.count == 4)
    }

    @Test("停用与恢复不改变资料更新时间")
    func activationStateUsesOptionalDate() throws {
        let updatedAt = Date(timeIntervalSince1970: 20)
        let account = try Account.validating(
            draft: AccountDraft(accountType: .cash, name: "现金", amountText: "0"),
            now: updatedAt
        )

        #expect(account.isActive)
        account.deactivatedAt = Date(timeIntervalSince1970: 30)
        #expect(account.isActive == false)
        #expect(account.updatedAt == updatedAt)
        account.deactivatedAt = nil
        #expect(account.isActive)
        #expect(account.updatedAt == updatedAt)
    }

    @Test("未知账户类型不具备默认和财务写入资格")
    func unknownAccountTypeIsNotBookkeepingCapable() {
        let account = Account(
            id: UUID(),
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

        #expect(account.isEligibleForDefault == false)
        #expect(account.supportsBookkeeping == false)
    }

    @Test("canonical singleton解析区分缺失、明确无默认和失效指针")
    func canonicalResolutionDistinguishesStates() throws {
        let account = try Account.validating(
            draft: AccountDraft(accountType: .cash, name: "现金", amountText: "0")
        )

        #expect(
            BookkeepingPreference.resolution(preference: nil, accounts: [account]) == .missing
        )
        #expect(
            BookkeepingPreference.resolution(
                preference: BookkeepingPreference(defaultAccountID: nil),
                accounts: [account]
            ) == .none
        )
        #expect(
            BookkeepingPreference.resolution(
                preference: BookkeepingPreference(defaultAccountID: UUID()),
                accounts: [account]
            ).isInvalid
        )
        #expect(
            BookkeepingPreference.resolution(
                preference: BookkeepingPreference(defaultAccountID: account.id),
                accounts: [account]
            ) == .valid(account.id)
        )
    }
}

private extension BookkeepingDefaultResolution {
    var isInvalid: Bool {
        if case .invalid = self { return true }
        return false
    }
}
