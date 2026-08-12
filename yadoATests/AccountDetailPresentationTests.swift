import Foundation
import Testing
@testable import yadoA

@Suite("账户详情展示", .serialized)
@MainActor
struct AccountDetailPresentationTests {
    @Test("选择列表 UUID 后展示同一账户的当前详情")
    func selectedUUIDResolvesMatchingCurrentDetails() throws {
        let selectedID = UUID()
        let selected = makeAccount(
            id: selectedID,
            typeRawValue: AccountType.debitCard.rawValue,
            templateID: "debitCard.ccb",
            name: "日常卡",
            note: "生活费",
            lastFourDigits: "1234",
            balance: 40
        )
        let other = makeAccount(name: "不应展示", balance: 999)

        let resolved = try #require(
            AccountDetailPresentationFactory.account(
                id: selectedID,
                in: [other, selected]
            )
        )
        let detail = AccountDetailPresentationFactory.detail(
            for: resolved,
            locale: Locale(identifier: "en_US")
        )

        #expect(resolved === selected)
        #expect(detail.id == selectedID)
        #expect(detail.name == "China Construction Bank")
        #expect(detail.typeTitle == "Debit Card")
        #expect(detail.institution == "China Construction Bank")
        #expect(detail.lastFourDigits == "1234")
        #expect(detail.note == "生活费")
        #expect(detail.amountLabel == "Balance")
        #expect(detail.formattedAmount.contains("40"))
        #expect(detail.formattedAmount.contains("¥"))
    }

    @Test("空备注与后缀不会生成详情可选字段")
    func absentOptionalFieldsRemainAbsent() {
        let account = makeAccount(note: nil, lastFourDigits: nil)

        let detail = AccountDetailPresentationFactory.detail(for: account)

        #expect(detail.note == nil)
        #expect(detail.lastFourDigits == nil)
        #expect(detail.institution == nil)
    }

    @Test("缺失 UUID 显示不可用且绝不降级到首个账户")
    func missingUUIDDoesNotFallBackToFirstAccount() {
        let first = makeAccount(name: "首个账户")

        let resolved = AccountDetailPresentationFactory.account(
            id: UUID(),
            in: [first]
        )

        #expect(resolved == nil)
        #expect(
            AccountLocalization.string(
                "account.detail.unavailable.title",
                locale: Locale(identifier: "en")
            ) == "Account Unavailable"
        )
        #expect(
            AccountLocalization.string(
                "account.detail.unavailable.title",
                locale: Locale(identifier: "zh-Hans")
            ) == "账户不可用"
        )
    }

    @Test("未知模板保留持久化名称并使用类型降级图标")
    func unknownTemplateUsesPersistedNameAndTypeIcon() {
        let account = makeAccount(
            typeRawValue: AccountType.investment.rawValue,
            templateID: "investment.removed",
            name: "旧证券账户"
        )

        let detail = AccountDetailPresentationFactory.detail(
            for: account,
            locale: Locale(identifier: "zh-Hans")
        )

        #expect(detail.name == "旧证券账户")
        #expect(detail.institution == nil)
        #expect(detail.typeTitle == "投资账户")
        #expect(detail.icon.brandImageName == nil)
        #expect(detail.icon.symbolName == AccountType.investment.symbolName)
    }

    @Test("文件存储重开后相同 UUID 仍解析为相同详情")
    func reopenedFileStorePreservesRoutableDetail() throws {
        let storeURL = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
        let id = UUID()
        let draft = AccountDraft(
            id: id,
            accountType: .cash,
            name: "旅行现金",
            note: "备用",
            amountText: "88.50"
        )

        do {
            let dataContainer = try AccountDataContainer.fileBacked(storeURL: storeURL)
            let repository = LocalAccountRepository(container: dataContainer.modelContainer)
            try repository.save(draft, locale: Locale(identifier: "en_US"))
        }

        let reopened = try AccountDataContainer.fileBacked(storeURL: storeURL)
        let reopenedRepository = LocalAccountRepository(container: reopened.modelContainer)
        let accounts = try reopenedRepository.accounts()
        let restored = try #require(
            AccountDetailPresentationFactory.account(id: id, in: accounts)
        )
        let detail = AccountDetailPresentationFactory.detail(
            for: restored,
            locale: Locale(identifier: "en_US")
        )

        #expect(accounts.count == 1)
        #expect(detail.id == id)
        #expect(detail.name == "旅行现金")
        #expect(detail.typeTitle == "Cash")
        #expect(detail.note == "备用")
        #expect(detail.formattedAmount.contains("88.50"))
        #expect(detail.amountLabel == "Balance")
    }

    /// 构造持久账户，隔离验证详情解析与展示契约。
    private func makeAccount(
        id: UUID = UUID(),
        typeRawValue: String = AccountType.cash.rawValue,
        templateID: String? = nil,
        name: String = "现金",
        note: String? = nil,
        lastFourDigits: String? = nil,
        balance: Decimal = 40
    ) -> Account {
        Account(
            id: id,
            typeRawValue: typeRawValue,
            templateID: templateID,
            name: name,
            note: note,
            lastFourDigits: lastFourDigits,
            balance: balance,
            currencyCode: "CNY",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
    }

    /// 为文件存储重开测试创建隔离位置。
    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "accounts.store")
    }
}
