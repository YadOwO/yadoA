//
//  yadoATests.swift
//  yadoATests
//
//  Created by webull_yado on 2026/8/12.
//

import Foundation
import Testing
import UIKit
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

    @Test func allAccountTypesExposeLocalizedDisplayContract() throws {
        let english = Locale(identifier: "en")
        let simplifiedChinese = Locale(identifier: "zh-Hans")
        let expectedTitles: [AccountType: (english: String, chinese: String)] = [
            .cash: ("Cash", "现金"),
            .debitCard: ("Debit Card", "储蓄卡"),
            .creditCard: ("Credit Card", "信用卡"),
            .virtualAccount: ("Virtual Account", "虚拟账户"),
            .investment: ("Investment Account", "投资账户"),
            .liability: ("Liability", "负债"),
            .receivable: ("Receivable", "债权"),
            .customAsset: ("Custom Asset", "自定义资产")
        ]

        for accountType in AccountType.allCases {
            let expectedTitle = try #require(expectedTitles[accountType])
            #expect(accountType.title(locale: english) == expectedTitle.english)
            #expect(accountType.title(locale: simplifiedChinese) == expectedTitle.chinese)
            #expect(accountType.titleLocalizationKey.hasPrefix("account.type."))
            #expect(accountType.symbolName.isEmpty == false)
            #expect(accountType.amountLabel(locale: english).isEmpty == false)
            #expect(accountType.amountLabel(locale: simplifiedChinese).isEmpty == false)
            #expect(accountType.amountLabelLocalizationKey.hasPrefix("account.amount."))

            if accountType.requiresTemplateSelection {
                #expect(accountType.templates.isEmpty == false)
            } else {
                #expect(accountType.templates.isEmpty)
            }
        }

        #expect(AccountType.cash.amountLabel(locale: english) == "Balance")
        #expect(AccountType.creditCard.amountLabel(locale: simplifiedChinese) == "欠款")
        #expect(AccountType.customAsset.amountLabel(locale: english) == "Amount")
    }

    @Test func secondaryTemplatesBelongToSelectedAccountType() {
        for accountType in AccountType.allCases where accountType.requiresTemplateSelection {
            #expect(accountType.templates.isEmpty == false)
            #expect(accountType.templates.allSatisfy { $0.accountType == accountType })
        }
    }

    @Test func knownInstitutionsUseBrandImagesAndOtherOptionsUseFallbackIcons() throws {
        let debitCardTemplates = AccountTemplate.banks(for: .debitCard)
        #expect(debitCardTemplates.dropLast().allSatisfy { $0.brandImageName != nil })
        #expect(debitCardTemplates.last?.brandImageName == nil)
        #expect(AccountTemplate.creditInstitutions.prefix(3).allSatisfy { $0.brandImageName != nil })
        #expect(AccountTemplate.virtualAccounts.prefix(2).allSatisfy { $0.brandImageName != nil })
        #expect(AccountTemplate.virtualAccounts.last?.brandImageName == nil)

        let brandedTemplates = AccountType.allCases
            .flatMap(\.templates)
            .filter { $0.brandImageName != nil }
        for template in brandedTemplates {
            let imageName = try #require(template.brandImageName)
            #expect(UIImage(named: imageName) != nil)
        }

        let fallbackTemplates = AccountType.allCases
            .flatMap(\.templates)
            .filter { $0.brandImageName == nil }
        #expect(fallbackTemplates.isEmpty == false)
        #expect(fallbackTemplates.allSatisfy { $0.symbolName.isEmpty == false })

        let unknownTemplate = AccountTemplate(
            id: "virtualAccount.unknown",
            accountType: .virtualAccount,
            nameLocalizationKey: "account.template.unknown",
            symbolName: AccountType.virtualAccount.symbolName
        )
        #expect(unknownTemplate.brandImageName == nil)
        #expect(unknownTemplate.symbolName == AccountType.virtualAccount.symbolName)
        #expect(unknownTemplate.name(locale: Locale(identifier: "en")) == "account.template.unknown")
    }

    @Test func templateIdentifiersStayStableWhileNamesFollowTheLocale() throws {
        let alipay = AccountTemplate.virtualAccounts[0]
        #expect(alipay.id == "virtualAccount.alipay")
        #expect(alipay.name(locale: Locale(identifier: "en")) == "Alipay")
        #expect(alipay.name(locale: Locale(identifier: "zh-Hans")) == "支付宝")

        let otherBank = try #require(AccountTemplate.banks(for: .debitCard).last)
        #expect(otherBank.id == "debitCard.other")
        #expect(otherBank.name(locale: Locale(identifier: "en")) == "Other Bank")
        #expect(otherBank.name(locale: Locale(identifier: "zh-Hans")) == "其他银行")
    }

    @Test func draftUsesTemplateNameAndRequiresAnAmount() {
        let template = AccountTemplate.virtualAccounts[0]
        var draft = AccountDraft(accountType: .virtualAccount, template: template)

        #expect(draft.name == template.name)
        #expect(draft.isFormValid == false)

        draft.amountText = "1234.56"
        #expect(draft.isFormValid)

        draft.amountText = "不是金额"
        #expect(draft.isFormValid == false)
    }

    @Test func directAccountDraftsUseTheExpectedDefaultName() {
        #expect(AccountDraft(accountType: .cash).name == AccountType.cash.title)
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
