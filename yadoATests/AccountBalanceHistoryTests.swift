import Foundation
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
                    amount: 150, transactionDay: 20260815
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
        #expect(net.points.last?.amount == AccountSummaryPresentation.summary(for: accounts).netAssets)
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
            amount: 150, transactionDay: 20260815
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

    @Test("完整走势的纵轴从零起：资产往上、欠款往下；迷你走势只框住线；点按、滑动取最近的一天")
    func seriesHelpers() throws {
        let start = try day(20260810)
        let asset = BalanceTrendSeries(
            points: [
                BalanceTrendPoint(day: 20260810, date: start, amount: 100),
                BalanceTrendPoint(day: 20260811, date: start.addingTimeInterval(86_400), amount: 110)
            ],
            direction: .asset
        )
        #expect(asset.valueDomain.lowerBound == 0)
        #expect(asset.valueDomain.upperBound > 110)
        #expect(asset.fittedDomain.lowerBound > 0)
        #expect(asset.fittedDomain.lowerBound < 100)
        #expect(asset.fittedDomain.upperBound > 110)
        #expect(!asset.crossesZero)
        #expect(asset.point(nearest: start.addingTimeInterval(60_000))?.day == 20260811)
        #expect(asset.point(nearest: start.addingTimeInterval(-60_000))?.day == 20260810)

        // 欠款取负画在零下方，零在纵轴顶端
        let debt = BalanceTrendSeries(
            points: [
                BalanceTrendPoint(day: 20260810, date: start, amount: 100),
                BalanceTrendPoint(day: 20260811, date: start.addingTimeInterval(86_400), amount: 300)
            ],
            direction: .debt
        )
        #expect(debt.plotValue(of: 300) == -300)
        #expect(debt.valueDomain.upperBound == 0)
        #expect(debt.valueDomain.lowerBound < -300)
        #expect(debt.fittedDomain.upperBound < 0)
        #expect(debt.segments.count == 1)
        #expect(debt.segments.first?.isBelowZero == true)
        #expect(debt.segments.first?.points.map(\.value) == [-100, -300])

        let mixed = BalanceTrendSeries(
            points: [
                BalanceTrendPoint(day: 20260810, date: start, amount: -50),
                BalanceTrendPoint(day: 20260811, date: start.addingTimeInterval(86_400), amount: 50)
            ],
            direction: .asset
        )
        #expect(mixed.crossesZero)
        #expect(mixed.valueDomain.contains(-50))
        #expect(mixed.valueDomain.contains(50))

        let zeroAssets = BalanceTrendSeries(
            points: [BalanceTrendPoint(day: 20260810, date: start, amount: 0)],
            direction: .asset
        )
        #expect(zeroAssets.valueDomain == 0...1)
        #expect(zeroAssets.fittedDomain == 0...1)

        let zeroDebt = BalanceTrendSeries(
            points: [BalanceTrendPoint(day: 20260810, date: start, amount: 0)],
            direction: .debt
        )
        #expect(zeroDebt.valueDomain == -1...0)
        #expect(zeroDebt.fittedDomain == -1...0)
    }

    @Test("跨过零时在两点之间补一个零点，前后两段在零上接起来，分别算零下和零上")
    func splitsSegmentsAtZero() throws {
        let start = try day(20260810)
        let series = BalanceTrendSeries(
            points: [
                BalanceTrendPoint(day: 20260810, date: start, amount: -50),
                BalanceTrendPoint(day: 20260811, date: start.addingTimeInterval(86_400), amount: 50),
                BalanceTrendPoint(day: 20260812, date: start.addingTimeInterval(172_800), amount: 80)
            ],
            direction: .asset
        )
        let segments = series.segments
        #expect(segments.map(\.isBelowZero) == [true, false])
        #expect(segments.map(\.id) == [0, 1])

        let crossing = try #require(segments.first?.points.last)
        #expect(crossing.value == 0)
        #expect(crossing.amount == nil)
        #expect(crossing.date == start.addingTimeInterval(43_200))
        #expect(segments.last?.points.first == crossing)
        #expect(segments.first?.points.map(\.value) == [-50, 0])
        #expect(segments.last?.points.map(\.value) == [0, 50, 80])
        #expect(segments.last?.points.last?.amount == 80)

        // 正好落在零上的点直接当接头，不再另补
        let touching = BalanceTrendSeries(
            points: [
                BalanceTrendPoint(day: 20260810, date: start, amount: 5),
                BalanceTrendPoint(day: 20260811, date: start.addingTimeInterval(86_400), amount: 0),
                BalanceTrendPoint(day: 20260812, date: start.addingTimeInterval(172_800), amount: -3)
            ],
            direction: .asset
        )
        #expect(touching.segments.map(\.isBelowZero) == [false, true])
        #expect(touching.segments.first?.points.map(\.value) == [5, 0])
        #expect(touching.segments.last?.points.map(\.value) == [0, -3])
        #expect(touching.segments.last?.points.first?.amount == 0)
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
            currencyCode: BookkeepingCurrency.code,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    /// 一笔支出流水。
    private func expense(_ accountID: UUID, amount: Decimal, day: Int) throws -> AccountTransaction {
        try AccountTransaction.validatingExpense(
            id: UUID(), accountID: accountID, category: .dining,
            amount: amount, transactionDay: day
        )
    }

    /// 一笔收入流水。
    private func income(_ accountID: UUID, amount: Decimal, day: Int) throws -> AccountTransaction {
        try AccountTransaction.validatingIncome(
            id: UUID(), accountID: accountID, category: .salary,
            amount: amount, transactionDay: day
        )
    }
}
