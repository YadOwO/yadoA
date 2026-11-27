import Foundation
import Testing
@testable import yadoA

@Suite("资产分析投影")
@MainActor
struct AssetAnalysisPresentationTests {
    @Test("合计与汇总卡片同一口径：停用账户不算，信用卡算负债，未知类型算资产")
    func totalsMatchSummaryCard() {
        let accounts = [
            makeAccount(type: .debitCard, templateID: "debitCard.cmb", name: "招商银行", balance: 10_000),
            makeAccount(type: .cash, name: "现金", balance: 500),
            makeAccount(typeRawValue: "futureType", name: "新类型", balance: 300),
            makeAccount(type: .creditCard, templateID: "creditCard.huabei", name: "花呗", balance: 2_000),
            makeAccount(type: .liability, name: "房贷", balance: 6_000),
            makeAccount(type: .cash, name: "旧钱包", balance: 9_999, deactivated: true)
        ]

        let analysis = AssetAnalysisPresentation(accounts: accounts, locale: chineseLocale, currencyCode: "CNY")
        let summary = AccountSummaryPresentation.summary(for: accounts, locale: chineseLocale, currencyCode: "CNY")

        #expect(analysis.assets == 10_800)
        #expect(analysis.liabilities == 8_000)
        #expect(analysis.netAssets == 2_800)
        #expect(analysis.assets == summary.assets)
        #expect(analysis.liabilities == summary.liabilities)
        #expect(analysis.debtRatio.map { ($0 * 1000).doubleValue.rounded() } == 741)
        #expect(analysis.debtRatioLevel == .partial(perHundred: 74))
    }

    @Test("资产负债率的说明分档")
    func debtRatioLevels() {
        let noDebt = AssetAnalysisPresentation(accounts: [
            makeAccount(type: .cash, name: "现金", balance: 100),
            // 信用卡多还了：欠款为负，不算有负债
            makeAccount(type: .creditCard, name: "信用卡", balance: -50)
        ], currencyCode: "CNY")
        #expect(noDebt.debtRatioLevel == .noDebt)
        #expect(noDebt.debtRatio == 0)

        let negligible = AssetAnalysisPresentation(accounts: [
            makeAccount(type: .cash, name: "现金", balance: 100_000),
            makeAccount(type: .creditCard, name: "信用卡", balance: 100)
        ], currencyCode: "CNY")
        #expect(negligible.debtRatioLevel == .negligible)

        let full = AssetAnalysisPresentation(accounts: [
            makeAccount(type: .cash, name: "现金", balance: 1_000),
            makeAccount(type: .liability, name: "借款", balance: 1_000)
        ], currencyCode: "CNY")
        #expect(full.debtRatioLevel == .partial(perHundred: 100))

        let exceeds = AssetAnalysisPresentation(accounts: [
            makeAccount(type: .cash, name: "现金", balance: 1_000),
            makeAccount(type: .liability, name: "借款", balance: 3_000)
        ], currencyCode: "CNY")
        #expect(exceeds.debtRatioLevel == .exceedsAssets)

        // 没有资产却有负债：比率没有意义，写成「—」，说明按负债超过资产
        let noAssets = AssetAnalysisPresentation(accounts: [
            makeAccount(type: .liability, name: "借款", balance: 3_000)
        ], currencyCode: "CNY")
        #expect(noAssets.debtRatio == nil)
        #expect(noAssets.debtRatioLevel == .exceedsAssets)
    }

    @Test("构成按账户类型合计，从大到小排，合计不为正的类型不画")
    func compositionGroupsByType() {
        let analysis = AssetAnalysisPresentation(accounts: [
            makeAccount(type: .debitCard, templateID: "debitCard.cmb", name: "招商银行", balance: 3_000),
            makeAccount(type: .debitCard, templateID: "debitCard.icbc", name: "工商银行", balance: 2_000),
            makeAccount(type: .virtualAccount, templateID: "virtualAccount.wechat", name: "微信", balance: 1_000),
            // 透支的现金账户：类型合计为负，不进环形图
            makeAccount(type: .cash, name: "现金", balance: -10),
            makeAccount(type: .creditCard, name: "信用卡", balance: 800),
            makeAccount(type: .liability, name: "房贷", balance: 1_200)
        ], locale: chineseLocale, currencyCode: "CNY")

        #expect(analysis.assetComposition.segments.map(\.id) == ["debitCard", "virtualAccount"])
        #expect(analysis.assetComposition.segments.first?.amount == 5_000)
        #expect(analysis.assetComposition.totalAmount == 6_000)
        #expect(analysis.liabilityComposition.segments.map(\.id) == ["liability", "creditCard"])
        #expect(analysis.composition(for: .liabilities) == analysis.liabilityComposition)
        #expect(analysis.composition(for: .assets) == analysis.assetComposition)
    }

    @Test("构成超过三类时，较小的合并成「其他」")
    func compositionFoldsLongTail() {
        let analysis = AssetAnalysisPresentation(accounts: [
            makeAccount(type: .debitCard, name: "储蓄卡", balance: 5_000),
            makeAccount(type: .virtualAccount, name: "微信", balance: 4_000),
            makeAccount(type: .investment, name: "基金", balance: 3_000),
            makeAccount(type: .cash, name: "现金", balance: 200),
            makeAccount(type: .receivable, name: "借给朋友", balance: 100)
        ], locale: chineseLocale, currencyCode: "CNY")

        let segments = analysis.assetComposition.segments
        #expect(segments.count == AssetAnalysisPresentation.maxCompositionSegments + 1)
        #expect(segments.prefix(3).map(\.id) == ["debitCard", "virtualAccount", "investment"])
        #expect(segments.last?.id == CategoryBreakdownPresentation.remainingID)
        #expect(segments.last?.amount == 300)
        #expect(segments.last?.title == "其他")
    }

    @Test("排行按余额从多到少，零余额不列，透支没有占比")
    func rankingSortsAccounts() {
        let cmb = makeAccount(type: .debitCard, templateID: "debitCard.cmb", name: "招商银行", balance: 3_000)
        let wechat = makeAccount(type: .virtualAccount, templateID: "virtualAccount.wechat", name: "微信", balance: 1_000)
        let empty = makeAccount(type: .cash, name: "空钱包", balance: 0)
        let overdrawn = makeAccount(type: .cash, name: "现金", balance: -20)

        let analysis = AssetAnalysisPresentation(accounts: [wechat, empty, overdrawn, cmb], locale: chineseLocale, currencyCode: "CNY")
        let ranking = analysis.assetRanking

        #expect(ranking.map(\.id) == [cmb.id, wechat.id, overdrawn.id])
        #expect(ranking[0].share == 0.75)
        #expect(ranking[1].share == 0.25)
        #expect(ranking[2].share == nil)
        // 品牌图标与账户列表一致
        #expect(ranking[0].row.icon.brandImageName == "BrandCMB")
        #expect(analysis.liabilityRanking.isEmpty)
        #expect(analysis.ranking(for: .assets) == ranking)
    }

    // MARK: - 芽豆有物物品估值

    @Test("传入物品估值后资产合计增加，负债不变，净资产和资产负债率跟着变；传 nil、0 或负数时与原来完全一致")
    func itemValuationAddsToAssets() {
        let accounts = [
            makeAccount(type: .debitCard, templateID: "debitCard.cmb", name: "招商银行", balance: 1_000),
            makeAccount(type: .liability, name: "房贷", balance: 500)
        ]

        let base = AssetAnalysisPresentation(accounts: accounts, locale: chineseLocale, currencyCode: "CNY")
        let withValuation = AssetAnalysisPresentation(accounts: accounts, itemValuation: 1_000, locale: chineseLocale, currencyCode: "CNY")

        #expect(base.assets == 1_000)
        #expect(withValuation.assets == 2_000)
        #expect(withValuation.assets == base.assets + 1_000)
        #expect(withValuation.liabilities == base.liabilities)
        #expect(withValuation.netAssets == base.netAssets + 1_000)
        // 资产负债率用含估值的资产：500 ÷ 2000 = 25%
        #expect(withValuation.debtRatio.map { ($0 * 1000).doubleValue.rounded() } == 250)
        #expect(base.debtRatio.map { ($0 * 1000).doubleValue.rounded() } == 500)
        // 负债一侧不受影响
        #expect(withValuation.liabilityComposition == base.liabilityComposition)
        #expect(withValuation.liabilityRanking == base.liabilityRanking)

        #expect(AssetAnalysisPresentation(accounts: accounts, itemValuation: nil, locale: chineseLocale, currencyCode: "CNY") == base)
        #expect(AssetAnalysisPresentation(accounts: accounts, itemValuation: 0, locale: chineseLocale, currencyCode: "CNY") == base)
        #expect(AssetAnalysisPresentation(accounts: accounts, itemValuation: -50, locale: chineseLocale, currencyCode: "CNY") == base)
    }

    @Test("资产构成里多一项 yadoi.itemValuation：名称是「物品估值」，金额是估值，按金额参与排序")
    func itemValuationJoinsComposition() {
        let accounts = [
            makeAccount(type: .debitCard, templateID: "debitCard.cmb", name: "招商银行", balance: 3_000),
            makeAccount(type: .virtualAccount, templateID: "virtualAccount.wechat", name: "微信", balance: 1_000)
        ]

        let analysis = AssetAnalysisPresentation(accounts: accounts, itemValuation: 2_000, locale: chineseLocale, currencyCode: "CNY")

        #expect(AssetAnalysisPresentation.itemValuationID == "yadoi.itemValuation")
        #expect(analysis.assetComposition.segments.map(\.id) == ["debitCard", "yadoi.itemValuation", "virtualAccount"])
        let item = analysis.assetComposition.segments[1]
        #expect(item.title == "物品估值")
        #expect(item.symbolName == "shippingbox")
        #expect(item.amount == 2_000)
        #expect(analysis.assetComposition.totalAmount == 6_000)

        // 不传估值时没有这一项
        let base = AssetAnalysisPresentation(accounts: accounts, locale: chineseLocale, currencyCode: "CNY")
        #expect(base.assetComposition.segments.map(\.id) == ["debitCard", "virtualAccount"])
    }

    @Test("排行里有估值行：点进去是估值详情，占比按含估值的正数合计算；账户行点进去是账户详情")
    func itemValuationJoinsRanking() {
        let cmb = makeAccount(type: .debitCard, templateID: "debitCard.cmb", name: "招商银行", balance: 4_000)
        let wechat = makeAccount(type: .virtualAccount, templateID: "virtualAccount.wechat", name: "微信", balance: 1_000)

        let analysis = AssetAnalysisPresentation(accounts: [wechat, cmb], itemValuation: 3_000, locale: chineseLocale, currencyCode: "CNY")
        let ranking = analysis.assetRanking

        #expect(ranking.map(\.id) == [cmb.id, ItemValuationPresentation.rowID, wechat.id])
        #expect(ranking.map(\.destination) == [.detail(cmb.id), .itemValuation, .detail(wechat.id)])
        // 正数合计 8000：4000 占一半，3000 占 3/8，1000 占 1/8
        #expect(isClose(ranking[0].share, to: 0.5))
        #expect(isClose(ranking[1].share, to: 0.375))
        #expect(isClose(ranking[2].share, to: 0.125))
        #expect(ranking[1].amount == 3_000)
        #expect(ranking[1].row.name == "物品估值")
        #expect(ranking[1].row.amountLabel == "估值")
        #expect(ranking[1].row.icon.symbolName == "shippingbox.fill")
        #expect(analysis.ranking(for: .assets) == ranking)
        #expect(analysis.liabilityRanking.isEmpty)
    }

    @Test("估值是资产一侧的一行：账户透支时它仍有占比，透支的账户没有占比")
    func itemValuationShareIgnoresOverdraft() {
        let cash = makeAccount(type: .cash, name: "现金", balance: -20)
        let analysis = AssetAnalysisPresentation(accounts: [cash], itemValuation: 500, locale: chineseLocale, currencyCode: "CNY")

        #expect(analysis.assets == 480)
        #expect(analysis.assetRanking.map(\.destination) == [.itemValuation, .detail(cash.id)])
        #expect(isClose(analysis.assetRanking[0].share, to: 1))
        #expect(analysis.assetRanking[1].share == nil)
    }

    @Test("普通账户行的 destination 是 .detail(id)，没有估值时排行里没有估值行")
    func accountRowsOpenAccountDetail() {
        let cmb = makeAccount(type: .debitCard, templateID: "debitCard.cmb", name: "招商银行", balance: 3_000)
        let loan = makeAccount(type: .liability, name: "房贷", balance: 800)

        let analysis = AssetAnalysisPresentation(accounts: [cmb, loan], locale: chineseLocale, currencyCode: "CNY")

        #expect(analysis.assetRanking.map(\.destination) == [.detail(cmb.id)])
        #expect(analysis.liabilityRanking.map(\.destination) == [.detail(loan.id)])
        #expect(!analysis.assetRanking.contains(where: { $0.id == ItemValuationPresentation.rowID }))
    }

    // MARK: - 工具

    /// 占比是否等于期望值；占比从 Decimal 转成 Double，允许极小的浮点误差。
    ///
    /// - Parameters:
    ///   - share: 排行行的占比；没有占比时为 nil。
    ///   - expected: 期望的占比。
    private func isClose(_ share: Double?, to expected: Double) -> Bool {
        guard let share else { return false }
        return abs(share - expected) < 1e-9
    }

    /// 测试用的中文语言环境。
    private var chineseLocale: Locale { Locale(identifier: "zh-Hans") }

    /// 建一个不落库的账户。
    ///
    /// - Parameters:
    ///   - type: 账户类型；传 `typeRawValue` 时忽略。
    ///   - typeRawValue: 直接指定类型原始值，用来模拟未知类型。
    ///   - templateID: 模板标识。
    ///   - name: 账户名称。
    ///   - balance: 当前余额或欠款。
    ///   - deactivated: 是否已停用。
    private func makeAccount(
        type: AccountType = .cash,
        typeRawValue: String? = nil,
        templateID: String? = nil,
        name: String,
        balance: Decimal,
        deactivated: Bool = false
    ) -> Account {
        Account(
            id: UUID(),
            typeRawValue: typeRawValue ?? type.rawValue,
            templateID: templateID,
            name: name,
            note: nil,
            lastFourDigits: nil,
            balance: balance,
            currencyCode: "CNY",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            deactivatedAt: deactivated ? Date(timeIntervalSince1970: 2) : nil
        )
    }
}
