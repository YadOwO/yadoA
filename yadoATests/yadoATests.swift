//
//  yadoATests.swift
//  yadoATests
//
//  Created by webull_yado on 2026/8/12.
//

import Foundation
import Testing
@testable import yadoA

struct yadoATests {

    @Test func accountTypesMatchPrototypeScope() {
        #expect(AccountType.allCases.count == 8)
        #expect(AccountType.cash.requiresTemplateSelection == false)
        #expect(AccountType.debitCard.requiresTemplateSelection)
        #expect(AccountType.creditCard.requiresTemplateSelection)
        #expect(AccountType.virtualAccount.requiresTemplateSelection)
        #expect(AccountType.investment.requiresTemplateSelection)
        #expect(AccountType.liability.requiresTemplateSelection == false)
        #expect(AccountType.receivable.requiresTemplateSelection == false)
        #expect(AccountType.customAsset.requiresTemplateSelection == false)
    }

    @Test func secondaryTemplatesBelongToSelectedAccountType() {
        for accountType in AccountType.allCases where accountType.requiresTemplateSelection {
            #expect(accountType.templates.isEmpty == false)
            #expect(accountType.templates.allSatisfy { $0.accountType == accountType })
        }
    }

    @Test func knownInstitutionsUseBrandImagesAndOtherOptionsUseFallbackIcons() {
        let debitCardTemplates = AccountTemplate.banks(for: .debitCard)
        #expect(debitCardTemplates.dropLast().allSatisfy { $0.brandImageName != nil })
        #expect(debitCardTemplates.last?.brandImageName == nil)
        #expect(AccountTemplate.creditInstitutions.prefix(3).allSatisfy { $0.brandImageName != nil })
        #expect(AccountTemplate.virtualAccounts.prefix(2).allSatisfy { $0.brandImageName != nil })
        #expect(AccountTemplate.virtualAccounts.last?.brandImageName == nil)
    }

    @Test func draftUsesTemplateNameAndRequiresAnAmount() {
        let template = AccountTemplate.virtualAccounts[0]
        var draft = AccountDraft(accountType: .virtualAccount, template: template)

        #expect(draft.name == "支付宝")
        #expect(draft.isFormValid == false)

        draft.amountText = "1234.56"
        #expect(draft.isFormValid)

        draft.amountText = "不是金额"
        #expect(draft.isFormValid == false)
    }

    @Test func directAccountDraftsUseTheExpectedDefaultName() {
        #expect(AccountDraft(accountType: .cash).name == "现金")
        #expect(AccountDraft(accountType: .liability).name.isEmpty)
        #expect(AccountDraft(accountType: .receivable).name.isEmpty)
        #expect(AccountDraft(accountType: .customAsset).name.isEmpty)
    }

    @Test func amountParsingUsesTheLocaleDecimalSeparator() {
        #expect(
            AccountAmountParser.amount(
                from: "1234.56",
                locale: Locale(identifier: "en_US")
            ) == Decimal(string: "1234.56")
        )
        #expect(
            AccountAmountParser.amount(
                from: "1234,56",
                locale: Locale(identifier: "de_DE")
            ) == Decimal(string: "1234.56")
        )
        #expect(AccountAmountParser.amount(from: "1,23,4", locale: Locale(identifier: "de_DE")) == nil)
        #expect(AccountAmountParser.amount(from: "-1", locale: Locale(identifier: "en_US")) == nil)
    }

}
