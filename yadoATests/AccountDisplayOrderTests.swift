import Foundation
import SwiftData
import Testing
@testable import yadoA

@Suite("账户统一顺序", .serialized)
@MainActor
struct AccountDisplayOrderTests {
    @Test("默认分类顺序与添加账户页一致，且不写入存储")
    func defaultOrderMatchesCreationPage() {
        #expect(AccountDisplayOrder.default.accountTypes == AccountType.allCases)
        #expect(AccountDisplayOrder(storedRawValues: nil) == .default)
        #expect(AccountDisplayOrder.default.storedRawValues == nil)
    }

    @Test("存储的顺序去掉未知和重复值，缺少的分类按默认顺序补在末尾")
    func storedOrderIsSanitizedAndCompleted() {
        let order = AccountDisplayOrder(
            storedRawValues: ["creditCard", "futureType", "cash", "creditCard"]
        )

        #expect(order.accountTypes.prefix(2) == [.creditCard, .cash])
        #expect(Array(order.accountTypes.dropFirst(2)) == AccountType.allCases.filter { $0 != .creditCard && $0 != .cash })
        #expect(order.storedRawValues?.count == AccountType.allCases.count)
    }

    @Test("先按分类排序，同一分类内先创建的在前，时间相同按 UUID，未知类型排最后")
    func sortsByTypeThenCreationTime() {
        let early = Date(timeIntervalSince1970: 100)
        let late = Date(timeIntervalSince1970: 200)
        let unknown = makeAccount(typeRawValue: "futureType", createdAt: early)
        let lateCash = makeAccount(typeRawValue: AccountType.cash.rawValue, createdAt: late)
        let earlyCash = makeAccount(typeRawValue: AccountType.cash.rawValue, createdAt: early)
        let credit = makeAccount(typeRawValue: AccountType.creditCard.rawValue, createdAt: early)
        let tieFirst = makeAccount(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            typeRawValue: AccountType.debitCard.rawValue,
            createdAt: early
        )
        let tieSecond = makeAccount(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            typeRawValue: AccountType.debitCard.rawValue,
            createdAt: early
        )
        let accounts = [unknown, tieSecond, lateCash, credit, earlyCash, tieFirst]

        #expect(
            AccountDisplayOrder.default.sorted(accounts).map(\.id)
                == [earlyCash.id, lateCash.id, tieFirst.id, tieSecond.id, credit.id, unknown.id]
        )
        #expect(
            AccountDisplayOrder(accountTypes: [.creditCard]).sorted(accounts).map(\.id)
                == [credit.id, earlyCash.id, lateCash.id, tieFirst.id, tieSecond.id, unknown.id]
        )
    }

    @Test("按分类分组时跳过没有账户的分类，未知类型合成一组")
    func sectionsSkipEmptyTypesAndMergeUnknown() {
        let cash = makeAccount(typeRawValue: AccountType.cash.rawValue)
        let liability = makeAccount(typeRawValue: AccountType.liability.rawValue)
        let unknownA = makeAccount(typeRawValue: "futureA")
        let unknownB = makeAccount(typeRawValue: "futureB")

        let sections = AccountDisplayOrder(accountTypes: [.liability])
            .sections([unknownA, cash, unknownB, liability])

        #expect(sections.map(\.accountType) == [.liability, .cash, nil])
        #expect(sections.last?.accounts.count == 2)
        #expect(sections.last?.title(locale: Locale(identifier: "en")) == "Unknown Account")
        #expect(sections.first?.title(locale: Locale(identifier: "zh-Hans")) == "负债")
    }

    @Test("仓库保存分类顺序后，账户列表与停用接替候选都跟随新顺序")
    func repositoryOrderFeedsAccountsAndReplacementCandidates() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let repository = LocalAccountRepository(container: container)
        let locale = Locale(identifier: "en_US")
        let cash = AccountDraft(accountType: .cash, name: "现金", amountText: "0", locale: locale)
        let virtual = AccountDraft(
            accountType: .virtualAccount,
            template: AccountTemplate.virtualAccounts.first,
            amountText: "0",
            locale: locale
        )
        let credit = AccountDraft(
            accountType: .creditCard,
            template: AccountTemplate.creditInstitutions.first,
            amountText: "0",
            locale: locale
        )
        try repository.save([virtual, credit, cash], locale: locale)

        #expect(try repository.accounts().map(\.id) == [cash.id, credit.id, virtual.id])

        try repository.saveAccountTypeOrder(AccountDisplayOrder(accountTypes: [.virtualAccount, .creditCard]))

        #expect(try repository.accounts().map(\.id) == [virtual.id, credit.id, cash.id])
        let preference = try #require(try repository.modelContext.canonicalBookkeepingPreference())
        #expect(preference.accountTypeOrder?.prefix(2) == ["virtualAccount", "creditCard"])
        // 首个合格账户 virtual 是默认账户，接替候选按新顺序列出其余账户。
        #expect(try repository.disposalPlan(for: virtual.id).replacementCandidates.map(\.id) == [credit.id, cash.id])

        try repository.saveAccountTypeOrder(.default)

        #expect(try repository.modelContext.canonicalBookkeepingPreference()?.accountTypeOrder == nil)
        #expect(try repository.accounts().map(\.id) == [cash.id, credit.id, virtual.id])
    }

    /// 构造已持久化形态的账户。
    private func makeAccount(
        id: UUID = UUID(),
        typeRawValue: String,
        createdAt: Date = Date(timeIntervalSince1970: 100)
    ) -> Account {
        Account(
            id: id,
            typeRawValue: typeRawValue,
            templateID: nil,
            name: "账户",
            note: nil,
            lastFourDigits: nil,
            balance: 0,
            currencyCode: "CNY",
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }
}
