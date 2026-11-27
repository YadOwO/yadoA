import Foundation
import SwiftData
import Testing
@testable import yadoA

@Suite("账本币种", .serialized)
@MainActor
struct BookkeepingCurrencyTests {
    private let enUS = Locale(identifier: "en_US")
    private let zhCN = Locale(identifier: "zh_CN")
    private let jaJP = Locale(identifier: "ja_JP")

    // MARK: - 地区默认币种

    @Test("手机地区的货币作为默认币种，没有地区时用 CNY")
    func regionDefaultFollowsLocale() {
        #expect(BookkeepingCurrency.regionDefault(locale: enUS) == "USD")
        #expect(BookkeepingCurrency.regionDefault(locale: zhCN) == "CNY")
        #expect(BookkeepingCurrency.regionDefault(locale: jaJP) == "JPY")
        #expect(BookkeepingCurrency.regionDefault(locale: Locale(identifier: "en")) == "CNY")
    }

    // MARK: - 账本币种的优先级

    @Test("账户 > 本机存的值 > 地区 > CNY")
    func resolveFollowsPriority() {
        #expect(BookkeepingCurrency.resolve(earliestAccountCode: "EUR", storedCode: "USD", locale: jaJP) == "EUR")
        #expect(BookkeepingCurrency.resolve(earliestAccountCode: nil, storedCode: "USD", locale: jaJP) == "USD")
        #expect(BookkeepingCurrency.resolve(earliestAccountCode: nil, storedCode: nil, locale: jaJP) == "JPY")
        #expect(
            BookkeepingCurrency.resolve(
                earliestAccountCode: nil, storedCode: nil, locale: Locale(identifier: "en")
            ) == "CNY"
        )
    }

    @Test("格式不合法的值被跳过，继续往后找")
    func resolveSkipsMalformedValues() {
        // 账户币种不是三位大写字母：跳过，取本机存的值
        #expect(BookkeepingCurrency.resolve(earliestAccountCode: "usd", storedCode: "GBP", locale: zhCN) == "GBP")
        #expect(BookkeepingCurrency.resolve(earliestAccountCode: "", storedCode: "GBP", locale: zhCN) == "GBP")
        // 本机存的值也不合法：取地区
        #expect(BookkeepingCurrency.resolve(earliestAccountCode: "US", storedCode: "XYZ1", locale: jaJP) == "JPY")
        #expect(BookkeepingCurrency.resolve(earliestAccountCode: nil, storedCode: "", locale: enUS) == "USD")
    }

    @Test("格式校验只认三位大写 ASCII 字母")
    func wellFormedAcceptsOnlyThreeUppercaseLetters() {
        #expect(BookkeepingCurrency.isWellFormed("USD"))
        #expect(BookkeepingCurrency.isWellFormed("CNY"))
        for code in ["", "US", "USDX", "usd", "Usd", "US1", "ÜSD", " USD", "US$"] {
            #expect(!BookkeepingCurrency.isWellFormed(code), "\(code) 不该通过")
        }
    }

    @Test("可选币种：常用的在前，去重，其余是 ISO 常用币种")
    func selectableCodesListCommonFirst() {
        let codes = BookkeepingCurrency.selectableCodes()

        #expect(Array(codes.prefix(BookkeepingCurrency.commonCodes.count)) == BookkeepingCurrency.commonCodes)
        #expect(Set(codes).count == codes.count)
        #expect(codes.contains("CHF"))
        #expect(BookkeepingCurrency.isSelectable("USD"))
        #expect(BookkeepingCurrency.isSelectable("CHF"))
        #expect(!BookkeepingCurrency.isSelectable("ZZZ"))
        #expect(!BookkeepingCurrency.isSelectable("usd"))
    }

    // MARK: - 小数位

    @Test("币种自己的小数位：JPY、KRW 没有，USD、CNY 两位，KWD 三位")
    func fractionDigitsFollowCurrency() {
        #expect(BookkeepingCurrency.fractionDigits(for: "JPY") == 0)
        #expect(BookkeepingCurrency.fractionDigits(for: "KRW") == 0)
        #expect(BookkeepingCurrency.fractionDigits(for: "USD") == 2)
        #expect(BookkeepingCurrency.fractionDigits(for: "CNY") == 2)
        #expect(BookkeepingCurrency.fractionDigits(for: "KWD") == 3)
    }

    @Test("输入的小数位不超过存储精度两位")
    func inputFractionDigitsCapAtTwo() {
        #expect(BookkeepingCurrency.inputFractionDigits(for: "JPY") == 0)
        #expect(BookkeepingCurrency.inputFractionDigits(for: "KRW") == 0)
        #expect(BookkeepingCurrency.inputFractionDigits(for: "USD") == 2)
        #expect(BookkeepingCurrency.inputFractionDigits(for: "KWD") == 2)
    }

    // MARK: - 显示

    @Test("金额按币种自己的小数位显示")
    func formattedCurrencyUsesCurrencyDigits() {
        #expect(Decimal(1235).formattedCurrency(locale: enUS, currencyCode: "JPY") == "¥1,235")
        #expect(Decimal(string: "12.5")!.formattedCurrency(locale: enUS, currencyCode: "USD") == "$12.50")
    }

    @Test("币种名称和符号跟着语言走，不认识的代码退回代码本身")
    func displayNameAndSymbol() {
        #expect(BookkeepingCurrency.displayName(for: "USD", locale: enUS) == "US Dollar")
        #expect(BookkeepingCurrency.symbol(for: "USD", locale: enUS) == "$")
        #expect(BookkeepingCurrency.symbol(for: "EUR", locale: enUS) == "€")
        #expect(BookkeepingCurrency.symbols(for: ["USD", "EUR"], locale: enUS) == ["USD": "$", "EUR": "€"])
    }

    // MARK: - 从本机账本推出

    @Test("有账户时取最早建的账户的币种，不看本机存的值和地区")
    func currentUsesEarliestAccount() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let context = ModelContext(container)
        context.autosaveEnabled = false
        context.insert(makeAccount(currency: "USD", createdAt: 2_000))
        context.insert(makeAccount(currency: "EUR", createdAt: 1_000))
        context.insert(makeAccount(currency: "JPY", createdAt: 3_000))
        try context.save()
        let defaults = LedgerTestDefaults.make(currency: "GBP", name: "currentEarliest")

        #expect(try BookkeepingCurrency.current(in: context, defaults: defaults, locale: zhCN) == "EUR")
    }

    @Test("没有账户时取本机存的值，没存过再取地区")
    func currentFallsBackToStoredValueThenRegion() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let context = ModelContext(container)

        let stored = LedgerTestDefaults.make(currency: "GBP", name: "currentStored")
        #expect(try BookkeepingCurrency.current(in: context, defaults: stored, locale: zhCN) == "GBP")

        let empty = LedgerTestDefaults.make(name: "currentEmpty")
        #expect(try BookkeepingCurrency.current(in: context, defaults: empty, locale: jaJP) == "JPY")
        #expect(
            try BookkeepingCurrency.current(in: context, defaults: empty, locale: Locale(identifier: "en")) == "CNY"
        )
    }

    /// 只带币种和创建时间的账户，余额为 0。
    private func makeAccount(currency: String, createdAt: TimeInterval) -> Account {
        Account(
            id: UUID(),
            typeRawValue: AccountType.cash.rawValue,
            templateID: nil,
            name: currency,
            note: nil,
            lastFourDigits: nil,
            balance: 0,
            currencyCode: currency,
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: createdAt)
        )
    }
}
