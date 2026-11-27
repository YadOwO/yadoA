import Foundation
import SwiftData
import Testing
@testable import yadoA

@Suite("账户余额走势按日倒推")
@MainActor
struct AccountBalanceHistoryTests {
    @Test("资产账户从当前余额往前倒推，每天的金额是当天流水记完之后的余额")
    func projectsAssetAccountBackwards() throws {
        let cash = makeAccount(type: .cash, balance: 950, createdDay: 20260810)
        let history = AccountBalanceHistory(
            accounts: [cash],
            transactions: [
                try expense(cash.id, amount: 100, day: 20260812),
                try income(cash.id, amount: 50, day: 20260815)
            ],
            today: try day(20260819),
            calendar: utcCalendar
        )

        let series = history.accountSeries(cash.id, range: .threeMonths)

        #expect(series.direction == .asset)
        #expect(series.points.map(\.day) == Array(20260810...20260819))
        #expect(series.points.map(\.amount) == [1000, 1000, 900, 900, 900, 950, 950, 950, 950, 950])
        #expect(series.change == -50)
        #expect(series.tone(forChange: series.change) == .negative)
        #expect(history.hasHistory())
    }

    @Test("信用卡按欠款画：消费让欠款变多，还款转账让欠款变少；欠款变多算负向")
    func projectsDebtAccountAsAmountOwed() throws {
        let cash = makeAccount(type: .cash, balance: 850, createdDay: 20260810)
        let credit = makeAccount(type: .creditCard, balance: 350, createdDay: 20260810)
        let history = AccountBalanceHistory(
            accounts: [cash, credit],
            transactions: [
                try expense(credit.id, amount: 300, day: 20260812),
                try AccountTransaction.validatingTransfer(
                    id: UUID(), fromAccountID: cash.id, toAccountID: credit.id,
                    amount: 150, currencyCode: "CNY", transactionDay: 20260815
                )
            ],
            today: try day(20260815),
            calendar: utcCalendar
        )

        let debt = history.accountSeries(credit.id, range: .all)
        let balance = history.accountSeries(cash.id, range: .all)

        #expect(debt.direction == .debt)
        #expect(debt.points.map(\.amount) == [200, 200, 500, 500, 500, 350])
        #expect(debt.change == 150)
        #expect(debt.tone(forChange: debt.change) == .negative)
        #expect(debt.tone(forChange: -10) == .positive)
        // 欠款本身是正数时与账户行一样用负向色，溢缴（负数）不上色
        #expect(debt.amountTone(for: 350) == .negative)
        #expect(debt.amountTone(for: -20) == .neutral)
        #expect(balance.points.map(\.amount) == [1000, 1000, 1000, 1000, 1000, 850])
    }

    @Test("净资产合计与汇总卡片同一口径，账户建立之前不计入")
    func sumsNetWorthFromAccountStart() throws {
        let cash = makeAccount(type: .cash, balance: 1000, createdDay: 20260810)
        let credit = makeAccount(type: .creditCard, balance: 300, createdDay: 20260814)
        let accounts = [cash, credit]
        let history = AccountBalanceHistory(
            accounts: accounts,
            transactions: [try expense(credit.id, amount: 100, day: 20260816)],
            today: try day(20260819),
            calendar: utcCalendar
        )

        let net = history.netWorthSeries(.netAssets, range: .threeMonths)
        let assets = history.netWorthSeries(.assets, range: .threeMonths)
        let liabilities = history.netWorthSeries(.liabilities, range: .threeMonths)

        #expect(net.points.map(\.day) == Array(20260810...20260819))
        #expect(net.points.map(\.amount) == [1000, 1000, 1000, 1000, 800, 800, 700, 700, 700, 700])
        #expect(assets.points.allSatisfy { $0.amount == 1000 })
        #expect(liabilities.points.first?.amount == 0)
        #expect(liabilities.points.last?.amount == 300)
        #expect(liabilities.direction == .debt)
        #expect(net.points.last?.amount == AccountSummaryPresentation.summary(for: accounts, currencyCode: "CNY").netAssets)
    }

    @Test("日期晚于今天的流水让走势画到那一天，终点仍等于当前余额")
    func extendsToFutureDatedTransactions() throws {
        let cash = makeAccount(type: .cash, balance: 70, createdDay: 20260810)
        let history = AccountBalanceHistory(
            accounts: [cash],
            transactions: [try expense(cash.id, amount: 30, day: 20260825)],
            today: try day(20260819),
            calendar: utcCalendar
        )

        let series = history.accountSeries(cash.id, range: .all)

        #expect(history.endDay == 20260825)
        #expect(series.points.last?.amount == 70)
        #expect(series.points.first(where: { $0.day == 20260819 })?.amount == 100)
    }

    @Test("补记在建账日之前的流水：走势从那笔流水的前一天、期初余额画起")
    func startsBeforeEarliestTransaction() throws {
        let cash = makeAccount(type: .cash, balance: 800, createdDay: 20260815)
        let history = AccountBalanceHistory(
            accounts: [cash],
            transactions: [try expense(cash.id, amount: 200, day: 20260801)],
            today: try day(20260815),
            calendar: utcCalendar
        )

        let series = history.accountSeries(cash.id, range: .threeMonths)

        #expect(series.points.first?.day == 20260731)
        #expect(series.points.first?.amount == 1000)
        #expect(series.points.first(where: { $0.day == 20260801 })?.amount == 800)
        #expect(series.points.last?.amount == 800)
    }

    @Test("建账当天就记了账：前一天是期初余额，当天已经画得成线")
    func drawsFromCreationDayEntry() throws {
        let cash = makeAccount(type: .cash, balance: 70, createdDay: 20260819)
        let history = AccountBalanceHistory(
            accounts: [cash],
            transactions: [try expense(cash.id, amount: 30, day: 20260819)],
            today: try day(20260819),
            calendar: utcCalendar
        )

        let series = history.accountSeries(cash.id, range: .threeMonths)

        #expect(series.canDraw)
        #expect(series.points.map(\.day) == [20260818, 20260819])
        #expect(series.points.map(\.amount) == [100, 70])
    }

    @Test("没记过流水的账户没有走势；只有一天的数据画不成线")
    func reportsMissingHistory() throws {
        let cash = makeAccount(type: .cash, balance: 100, createdDay: 20260819)
        let history = AccountBalanceHistory(
            accounts: [cash],
            transactions: [],
            today: try day(20260819),
            calendar: utcCalendar
        )

        #expect(!history.hasHistory())
        #expect(!history.accountSeries(cash.id, range: .all).canDraw)
        #expect(history.accountSeries(UUID(), range: .all).points.isEmpty)
    }

    @Test("范围：三个月逐日取点；跨度一年多时按周取点，首尾两天都在")
    func samplesDaysByRange() throws {
        let cash = makeAccount(type: .cash, balance: 100, createdDay: 20240101)
        let history = AccountBalanceHistory(
            accounts: [cash],
            transactions: [try income(cash.id, amount: 1, day: 20250101)],
            today: try day(20260819),
            calendar: utcCalendar
        )

        let threeMonths = history.sampleDays(range: .threeMonths, earliestDay: 20240101).map { $0.day }
        #expect(threeMonths.first == 20260519)
        #expect(threeMonths.last == 20260819)
        #expect(threeMonths.count == 93)

        let all = history.sampleDays(range: .all, earliestDay: 20240101)
        #expect(all.first?.day == 20240101)
        #expect(all.last?.day == 20260819)
        #expect(all.count < 200)
        #expect(zip(all, all.dropFirst()).allSatisfy { $0.date < $1.date })
    }

    @Test("转账的余额影响拆成转出、转入两条，信用卡收到还款时欠款减少")
    func splitsTransferIntoTwoChanges() throws {
        let cashID = UUID()
        let creditID = UUID()
        let transfer = try AccountTransaction.validatingTransfer(
            id: UUID(), fromAccountID: cashID, toAccountID: creditID,
            amount: 150, currencyCode: "CNY", transactionDay: 20260815
        )

        let changes = try AccountBalanceRebuilder.balanceChanges(
            of: transfer,
            accountTypes: [cashID: .cash, creditID: .creditCard]
        )

        #expect(changes.map { $0.accountID } == [cashID, creditID])
        #expect(changes.map { $0.amount } == [-150, -150])
        // 对方账户类型未知时只剩已知的一边
        let partial = try AccountBalanceRebuilder.balanceChanges(of: transfer, accountTypes: [cashID: .cash])
        #expect(partial.map { $0.accountID } == [cashID])
    }

    @Test("纵轴范围留白但不越过零；有正有负时标出零线；点按、滑动取最近的一天")
    func seriesHelpers() throws {
        let start = try day(20260810)
        let positive = BalanceTrendSeries(
            points: [
                BalanceTrendPoint(day: 20260810, date: start, amount: 10),
                BalanceTrendPoint(day: 20260811, date: start.addingTimeInterval(86_400), amount: 110)
            ],
            direction: .asset
        )
        #expect(positive.amountDomain.lowerBound == 0)
        #expect(positive.amountDomain.upperBound > 110)
        #expect(!positive.crossesZero)
        #expect(positive.point(nearest: start.addingTimeInterval(60_000))?.day == 20260811)
        #expect(positive.point(nearest: start.addingTimeInterval(-60_000))?.day == 20260810)
        #expect(positive.point(nearest: start.addingTimeInterval(43_200))?.day == 20260810)
        #expect(positive.point(nearest: start.addingTimeInterval(500_000))?.day == 20260811)
        #expect(positive.point(day: 20260811)?.amount == 110)
        #expect(positive.point(day: nil) == nil)

        // 余额都很大、起伏很小时纵轴只框住这一段，线不会被压平
        let large = BalanceTrendSeries(
            points: [
                BalanceTrendPoint(day: 20260810, date: start, amount: 50_000),
                BalanceTrendPoint(day: 20260811, date: start.addingTimeInterval(86_400), amount: 51_000)
            ],
            direction: .asset
        )
        #expect(large.amountDomain.lowerBound > 49_000)
        #expect(large.amountDomain.upperBound < 52_000)

        let mixed = BalanceTrendSeries(
            points: [
                BalanceTrendPoint(day: 20260810, date: start, amount: -50),
                BalanceTrendPoint(day: 20260811, date: start.addingTimeInterval(86_400), amount: 50)
            ],
            direction: .asset
        )
        #expect(mixed.crossesZero)
        #expect(mixed.amountDomain.contains(0))

        let zeros = BalanceTrendSeries(
            points: [BalanceTrendPoint(day: 20260810, date: start, amount: 0)],
            direction: .debt
        )
        #expect(zeros.amountDomain == 0...1)
        #expect(zeros.point(nearest: start) == zeros.points.first)
        #expect(BalanceTrendSeries(points: [], direction: .asset).point(nearest: start) == nil)
    }

    @Test("线的颜色看整段变好还是变坏：资产变多、欠款变少为正向，没有变化不上色")
    func colorsLineByChange() throws {
        let start = try day(20260810)
        func series(_ first: Decimal, _ last: Decimal, _ direction: BalanceTrendDirection) -> BalanceTrendSeries {
            BalanceTrendSeries(
                points: [
                    BalanceTrendPoint(day: 20260810, date: start, amount: first),
                    BalanceTrendPoint(day: 20260811, date: start.addingTimeInterval(86_400), amount: last)
                ],
                direction: direction
            )
        }

        #expect(series(100, 120, .asset).changeTone == .positive)
        #expect(series(120, 100, .asset).changeTone == .negative)
        #expect(series(300, 500, .debt).changeTone == .negative)
        #expect(series(500, 300, .debt).changeTone == .positive)
        #expect(series(100, 100, .asset).changeTone == .neutral)
        // 金额本身的颜色仍与账户行一致：欠款用负向色，资产余额不上色
        #expect(series(500, 300, .debt).amountTone(for: 300) == .negative)
        #expect(series(100, 120, .asset).amountTone(for: 120) == .neutral)
    }

    @Test("读屏上下轻扫逐日切换：没选中时从最后一天开始，到头停住")
    func stepsSelectionForVoiceOver() throws {
        let start = try day(20260810)
        let series = BalanceTrendSeries(
            points: (0..<3).map { offset in
                BalanceTrendPoint(
                    day: 20260810 + offset,
                    date: start.addingTimeInterval(Double(offset) * 86_400),
                    amount: Decimal(offset)
                )
            },
            direction: .asset
        )

        #expect(series.point(steppingFrom: nil, by: -1)?.day == 20260812)
        #expect(series.point(steppingFrom: 20260812, by: -1)?.day == 20260811)
        #expect(series.point(steppingFrom: 20260810, by: -1)?.day == 20260810)
        #expect(series.point(steppingFrom: 20260812, by: 1)?.day == 20260812)
        #expect(series.point(steppingFrom: 20990101, by: 1)?.day == 20260812)
        #expect(BalanceTrendSeries(points: [], direction: .asset).point(steppingFrom: nil, by: 1) == nil)
    }

    @Test("用汇总好的材料建走势与直接用流水建的一致；可以只取部分账户，终点只看这些账户的流水")
    func buildsFromCachedLedgers() throws {
        let cash = makeAccount(type: .cash, balance: 900, createdDay: 20260801)
        let credit = makeAccount(type: .creditCard, balance: 200, createdDay: 20260805)
        let accounts = [cash, credit]
        let transactions = [
            try expense(cash.id, amount: 100, day: 20260810),
            try expense(credit.id, amount: 200, day: 20260812),
            try expense(credit.id, amount: 50, day: 20260830),
            try income(credit.id, amount: 50, day: 20260830)
        ]
        let today = try day(20260819)

        let direct = AccountBalanceHistory(
            accounts: accounts,
            transactions: transactions,
            today: today,
            calendar: utcCalendar
        )
        var builder = AccountBalanceHistory.LedgerBuilder(accounts: accounts)
        transactions.forEach { builder.add($0) }
        let ledgers = builder.ledgers(for: accounts, calendar: utcCalendar)
        let cached = AccountBalanceHistory(ledgers: ledgers, today: today, calendar: utcCalendar)

        #expect(cached.endDay == direct.endDay)
        for range in BalanceTrendRange.allCases {
            for metric in NetWorthTrendMetric.allCases {
                #expect(cached.netWorthSeries(metric, range: range) == direct.netWorthSeries(metric, range: range))
            }
            #expect(cached.accountSeries(cash.id, range: range) == direct.accountSeries(cash.id, range: range))
        }

        // 只看现金账户：信用卡 8/30 那两笔不让走势画到 8/30
        let cashOnly = AccountBalanceHistory(
            ledgers: ledgers,
            accountIDs: [cash.id],
            today: today,
            calendar: utcCalendar
        )
        #expect(cached.endDay == 20260830)
        #expect(cashOnly.endDay == 20260819)
        #expect(Array(cashOnly.ledgers.keys) == [cash.id])
        #expect(cashOnly.netWorthSeries(.netAssets, range: .threeMonths).points.last?.amount == 900)
        #expect(cashOnly.netWorthSeries(.liabilities, range: .threeMonths).points.allSatisfy { $0.amount == 0 })
    }

    @Test("走势缓存从本地数据分批读取，结果与直接推算一致；本地数据保存后标记为过期")
    func storeLoadsAndInvalidatesOnSave() async throws {
        let dataContainer = try AccountDataContainer.inMemory()
        let container = dataContainer.modelContainer
        let cash = makeAccount(type: .cash, balance: 900, createdDay: 20260801)
        let credit = makeAccount(type: .creditCard, balance: 200, createdDay: 20260805)
        let transactions = [
            try expense(cash.id, amount: 100, day: 20260810),
            try expense(credit.id, amount: 200, day: 20260812)
        ]
        let context = ModelContext(container)
        context.insert(cash)
        context.insert(credit)
        transactions.forEach { context.insert($0) }
        try context.save()

        let store = BalanceHistoryStore()
        #expect(store.ledgers == nil)
        await store.reload(container: container, calendar: utcCalendar)

        let ledgers = try #require(store.ledgers)
        let today = try day(20260819)
        let cached = AccountBalanceHistory(ledgers: ledgers, today: today, calendar: utcCalendar)
        let direct = AccountBalanceHistory(
            accounts: [cash, credit],
            transactions: transactions,
            today: today,
            calendar: utcCalendar
        )
        #expect(Set(ledgers.keys) == [cash.id, credit.id])
        #expect(cached.netWorthSeries(.netAssets, range: .all) == direct.netWorthSeries(.netAssets, range: .all))
        #expect(cached.accountSeries(credit.id, range: .all) == direct.accountSeries(credit.id, range: .all))

        // 再保存一次：数据版本加一，页面据此重算
        let before = store.dataVersion
        let writer = ModelContext(container)
        writer.insert(try income(cash.id, amount: 10, day: 20260815))
        try writer.save()
        for _ in 0..<100 where store.dataVersion == before {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.dataVersion > before)
    }

    // MARK: - 辅助

    /// 时区固定为 UTC 的公历，测试结果不随机器时区变化。
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    /// 把 `YYYYMMDD` 换成 UTC 零点。
    private func day(_ value: Int) throws -> Date {
        try #require(TransactionDay.date(from: value, calendar: utcCalendar))
    }

    /// 建一个不落库的账户；`balance` 是当前余额（负债类为欠款）。
    private func makeAccount(type: AccountType, balance: Decimal, createdDay: Int) -> Account {
        let createdAt = TransactionDay.date(from: createdDay, calendar: utcCalendar) ?? .distantPast
        return Account(
            id: UUID(),
            typeRawValue: type.rawValue,
            templateID: nil,
            name: type.rawValue,
            note: nil,
            lastFourDigits: nil,
            balance: balance,
            currencyCode: BookkeepingCurrency.fallbackCode,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    /// 一笔支出流水。
    private func expense(_ accountID: UUID, amount: Decimal, day: Int) throws -> AccountTransaction {
        try AccountTransaction.validatingExpense(
            id: UUID(), accountID: accountID, category: .dining,
            amount: amount, currencyCode: "CNY", transactionDay: day
        )
    }

    /// 一笔收入流水。
    private func income(_ accountID: UUID, amount: Decimal, day: Int) throws -> AccountTransaction {
        try AccountTransaction.validatingIncome(
            id: UUID(), accountID: accountID, category: .salary,
            amount: amount, currencyCode: "CNY", transactionDay: day
        )
    }
}
