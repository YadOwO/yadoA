import Foundation

/// 余额走势可选的时间范围。
enum BalanceTrendRange: String, CaseIterable, Identifiable, Hashable {
    /// 最近三个月。
    case threeMonths

    /// 最近一年。
    case oneYear

    /// 从最早计入的账户开始。
    case all

    /// 切换控件使用的稳定标识。
    var id: Self { self }

    /// 范围标题对应的稳定本地化键。
    var titleLocalizationKey: String {
        "account.trend.range.\(rawValue)"
    }

    /// 当前语言环境下的范围标题。
    func title(locale: Locale = .current) -> String {
        AccountLocalization.string(titleLocalizationKey, locale: locale)
    }

    /// 范围的起始日期；「全部」没有固定起点，返回 `nil`。
    ///
    /// - Parameters:
    ///   - end: 走势的最后一天。
    ///   - calendar: 推算日期使用的公历。
    /// - Returns: 往前推三个月或一年的日期。
    func startDate(endingAt end: Date, calendar: Calendar) -> Date? {
        switch self {
        case .threeMonths:
            calendar.date(byAdding: .month, value: -3, to: end)
        case .oneYear:
            calendar.date(byAdding: .year, value: -1, to: end)
        case .all:
            nil
        }
    }
}

/// 走势金额的方向语义，决定线画在零的哪一侧和涨跌算好还是算坏。
enum BalanceTrendDirection: Equatable, Sendable {
    /// 资产余额或净资产：从零往上画，变多是好事。
    case asset

    /// 信用卡、负债的欠款：取负后从零往下画，变多是坏事。
    case debt
}

/// 资产趋势页可切换的三种金额，与账户页汇总卡片的三项一一对应。
enum NetWorthTrendMetric: String, CaseIterable, Identifiable, Hashable {
    /// 净资产：资产减负债。
    case netAssets

    /// 资产：非负债类账户的余额合计。
    case assets

    /// 负债：信用卡和负债类账户的欠款合计。
    case liabilities

    /// 切换控件使用的稳定标识。
    var id: Self { self }

    /// 与汇总卡片共用的标题键，两处叫法保持一致。
    var titleLocalizationKey: String {
        switch self {
        case .netAssets:
            "account.summary.net_assets"
        case .assets:
            "account.summary.assets"
        case .liabilities:
            "account.summary.liabilities"
        }
    }

    /// 当前语言环境下的标题。
    func title(locale: Locale = .current) -> String {
        AccountLocalization.string(titleLocalizationKey, locale: locale)
    }

    /// 负债变多是坏事，其余变多是好事。
    var direction: BalanceTrendDirection {
        self == .liabilities ? .debt : .asset
    }
}

/// 走势上的一个点：某个业务日结束时的金额。
struct BalanceTrendPoint: Identifiable, Equatable {
    /// `YYYYMMDD` 业务日。
    let day: Int

    /// 业务日在当前时区的零点，作为横轴位置。
    let date: Date

    /// 当天所有流水记完之后的金额；负债类是欠款，正数表示欠了多少。
    let amount: Decimal

    /// 图表点使用的稳定标识。
    var id: Int { day }
}

/// 一条可以直接画出来的走势。
struct BalanceTrendSeries: Equatable {
    /// 按日期从早到晚排列的点。
    let points: [BalanceTrendPoint]

    /// 金额的方向语义。
    let direction: BalanceTrendDirection

    /// 至少两个点才连得成线。
    var canDraw: Bool { points.count >= 2 }

    /// 范围内金额从第一点到最后一点的变化。
    var change: Decimal {
        guard let first = points.first, let last = points.last else { return .zero }
        return last.amount - first.amount
    }

    /// 金额变化的上色语义：资产变多、欠款变少是正向，反过来是负向。
    ///
    /// - Parameter change: 带符号的金额变化。
    /// - Returns: 正向、负向或中性。
    func tone(forChange change: Decimal) -> AmountTone {
        AmountTone(signOf: direction == .debt ? -change : change)
    }

    /// 某一点金额本身的上色语义，与账户行一致：欠款、透支、净资产为负时用负向色。
    ///
    /// - Parameter amount: 走势上某一点的金额。
    func amountTone(for amount: Decimal) -> AmountTone {
        AccountListPresentation.amountTone(isDebt: direction == .debt, balance: amount)
    }

    /// 离给定日期最近的点，供点按、滑动图表时选中；没有点时为 `nil`。
    ///
    /// - Parameter date: 手指位置对应的日期。
    /// - Returns: 日期最接近的点；两边一样近时取较早的一个。
    func point(nearest date: Date) -> BalanceTrendPoint? {
        points.min { lhs, rhs in
            abs(lhs.date.timeIntervalSince(date)) < abs(rhs.date.timeIntervalSince(date))
        }
    }

    /// 金额画在图上的位置：资产原样在零上方，欠款取负画在零下方。
    ///
    /// 这样零以上都是撑起净资产的部分、零以下都是拉低净资产的部分，线按所在一侧取正向色或负向色。
    ///
    /// - Parameter amount: 走势上某一点的金额。
    /// - Returns: 带符号的纵轴值。
    func plotValue(of amount: Decimal) -> Decimal {
        direction == .debt ? -amount : amount
    }

    /// 按零上、零下切开的几段线，供分段上色。
    ///
    /// 相邻两点一正一负时，在两点连线与零的交点补一个零点，前一段在这里收尾、后一段从这里开始，
    /// 两段颜色在零处接上，不会出现一截线颜色画错一侧。值为零的点跟着前面的段走。
    var segments: [BalanceTrendSegment] {
        var result: [BalanceTrendSegment] = []
        var current: [BalanceTrendPlotPoint] = []
        // 当前段的正负号；段开头全是零时还没定下来，记为 0
        var currentSign = 0

        func closeSegment() {
            guard !current.isEmpty else { return }
            result.append(BalanceTrendSegment(id: result.count, isBelowZero: currentSign < 0, points: current))
        }

        for point in points {
            let value = plotValue(of: point.amount).doubleValue
            let sign = value > 0 ? 1 : (value < 0 ? -1 : 0)
            if sign != 0, currentSign != 0, sign != currentSign, let previous = current.last {
                let crossing: BalanceTrendPlotPoint
                if previous.value == 0 {
                    crossing = previous
                } else {
                    // 两点一正一负，比例一定落在 0 和 1 之间
                    let fraction = previous.value / (previous.value - value)
                    crossing = BalanceTrendPlotPoint(
                        date: previous.date.addingTimeInterval(point.date.timeIntervalSince(previous.date) * fraction),
                        value: 0,
                        amount: nil
                    )
                    current.append(crossing)
                }
                closeSegment()
                current = [crossing]
                currentSign = sign
            }
            if currentSign == 0 { currentSign = sign }
            current.append(BalanceTrendPlotPoint(date: point.date, value: value, amount: point.amount))
        }
        closeSegment()
        return result
    }

    /// 完整走势的纵轴范围：总包含零，资产从零往上、欠款从零往下；远离零的一侧留一点空白。
    ///
    /// 全是零时按方向留出一格：资产线贴在底部，欠款线贴在顶部。
    var valueDomain: ClosedRange<Double> {
        let values = points.map { plotValue(of: $0.amount).doubleValue }
        let low = min(values.min() ?? 0, 0)
        let high = max(values.max() ?? 0, 0)
        guard high > low else { return direction == .debt ? -1...0 : 0...1 }
        let padding = (high - low) * 0.08
        return (low < 0 ? low - padding : 0)...(high > 0 ? high + padding : 0)
    }

    /// 迷你走势的纵轴范围：只框住线本身，上下留一点空白，让小图也看得出起伏。
    ///
    /// 都不为负时下沿不低于零，都不为正时上沿不高于零；全是零时按方向留出一格。
    var fittedDomain: ClosedRange<Double> {
        let values = points.map { plotValue(of: $0.amount).doubleValue }
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        if low == 0, high == 0 { return direction == .debt ? -1...0 : 0...1 }
        let padding = high > low ? (high - low) * 0.12 : max(abs(high) * 0.1, 1)
        var lower = low - padding
        var upper = high + padding
        if low >= 0 { lower = max(lower, 0) }
        if high <= 0 { upper = min(upper, 0) }
        return lower...upper
    }

    /// 线是否同时有零上和零下的部分；迷你走势只在这时画零线。
    var crossesZero: Bool {
        points.contains { $0.amount < 0 } && points.contains { $0.amount > 0 }
    }
}

/// 画在图上的一个位置：日期和带符号的纵轴值。
struct BalanceTrendPlotPoint: Equatable {
    /// 横轴日期；跨零处补的点落在两天之间。
    let date: Date

    /// 纵轴值：零上为资产，零下为欠款。
    let value: Double

    /// 对应那一天的金额，供读屏播报；跨零处补的点不是某一天，为 `nil`。
    let amount: Decimal?
}

/// 同在零上或同在零下的一段连续走势。
struct BalanceTrendSegment: Identifiable, Equatable {
    /// 段的序号，从早到晚递增。
    let id: Int

    /// 是否在零下方，决定用负向色还是正向色。
    let isBelowZero: Bool

    /// 段内按日期从早到晚排列的点。
    let points: [BalanceTrendPlotPoint]
}

/// 按日推算账户余额的历史。
///
/// 以账户当前余额为终点，往前每跨过一天就减去那天流水的影响，所以走势的最后一点总是等于账户页上显示的金额。
/// 流水规则与余额缓存一致，都来自 `AccountBalanceRebuilder.balanceChanges`。
/// 账户从建账那天、或最早一笔流水的前一天（取更早的）开始计入，在此之前不算；
/// 留出前一天是为了让期初余额也成为线上的一点，建账当天就记了账也能看到第一笔带来的变化。
struct AccountBalanceHistory {
    /// 单个账户推算走势需要的材料。
    struct Ledger {
        /// 账户开始计入走势的业务日。
        let startDay: Int

        /// 当前余额；负债类为欠款，也是走势的终点。
        let balance: Decimal

        /// 是否是信用卡、负债这类余额表示欠款的账户。
        let isDebt: Bool

        /// 各业务日的余额变化合计，按业务日从晚到早排列。
        let changes: [(day: Int, amount: Decimal)]
    }

    /// 参与推算的账户，键为账户 UUID。
    let ledgers: [UUID: Ledger]

    /// 走势的最后一天：今天和最晚一笔流水取更晚的，让终点包含所有已记的流水。
    let endDay: Int

    /// 推算日期使用的公历，时区沿用调用方。
    private let calendar: Calendar

    /// 由账户和流水建立推算材料。
    ///
    /// 未知类型的账户无法判断流水方向，按当前余额从建账日起保持不变；与汇总卡片一样计入资产。
    ///
    /// - Parameters:
    ///   - accounts: 参与推算的账户。
    ///   - transactions: 流水，可以包含与这些账户无关的流水。
    ///   - today: 今天，决定走势至少画到哪天。
    ///   - calendar: 提供时区的日历，内部统一换成公历。
    init(
        accounts: [Account],
        transactions: [AccountTransaction],
        today: Date = .now,
        calendar sourceCalendar: Calendar = .current
    ) {
        let calendar = TransactionDay.gregorianCalendar(basedOn: sourceCalendar)
        self.calendar = calendar

        var accountTypes: [UUID: AccountType] = [:]
        for account in accounts {
            if let type = account.accountType { accountTypes[account.id] = type }
        }

        var changesByAccount: [UUID: [Int: Decimal]] = [:]
        var endDay = TransactionDay.encode(today, calendar: calendar)
        for transaction in transactions where TransactionDay.isValid(transaction.transactionDay) {
            // 展示用的推算：极端金额算不出来时跳过这一笔，不影响页面其他内容
            guard let changes = try? AccountBalanceRebuilder.balanceChanges(
                of: transaction,
                accountTypes: accountTypes
            ), !changes.isEmpty else { continue }
            let day = transaction.transactionDay
            endDay = max(endDay, day)
            for change in changes {
                changesByAccount[change.accountID, default: [:]][day, default: .zero] += change.amount
            }
        }

        var ledgers: [UUID: Ledger] = [:]
        for account in accounts {
            let changes = changesByAccount[account.id] ?? [:]
            let createdDay = TransactionDay.encode(account.createdAt, calendar: calendar)
            let openingDay = changes.keys.min().map { Self.day(before: $0, calendar: calendar) } ?? createdDay
            ledgers[account.id] = Ledger(
                startDay: min(createdDay, openingDay),
                balance: account.balance,
                isDebt: account.accountType?.expenseBalanceEffect == .increaseDebt,
                changes: changes
                    .map { (day: $0.key, amount: $0.value) }
                    .sorted { $0.day > $1.day }
            )
        }
        self.ledgers = ledgers
        self.endDay = endDay
    }

    /// 是否有可以看的走势：参与推算的账户里至少记过一笔流水。
    ///
    /// - Parameter accountIDs: 要看的账户；为 `nil` 时看全部账户。
    func hasHistory(for accountIDs: Set<UUID>? = nil) -> Bool {
        ledgers.contains { id, ledger in
            (accountIDs?.contains(id) ?? true) && !ledger.changes.isEmpty
        }
    }

    /// 单个账户在给定范围内的走势；信用卡、负债的金额是欠款。
    ///
    /// - Parameters:
    ///   - accountID: 账户 UUID。
    ///   - range: 时间范围。
    /// - Returns: 账户不在推算材料里时返回没有点的走势。
    func accountSeries(_ accountID: UUID, range: BalanceTrendRange) -> BalanceTrendSeries {
        guard let ledger = ledgers[accountID] else {
            return BalanceTrendSeries(points: [], direction: .asset)
        }
        let samples = sampleDays(range: range, earliestDay: ledger.startDay)
        let amounts = Self.amounts(of: ledger, at: samples.map { $0.day })
        return BalanceTrendSeries(
            points: zip(samples, amounts).map { sample, amount in
                BalanceTrendPoint(day: sample.day, date: sample.date, amount: amount ?? .zero)
            },
            direction: ledger.isDebt ? .debt : .asset
        )
    }

    /// 全部账户合计的净资产、资产或负债走势，与汇总卡片同一口径。
    ///
    /// 三种金额共用同一段横轴（从最早计入的账户开始），切换时线的起止不变。
    ///
    /// - Parameters:
    ///   - metric: 净资产、资产或负债。
    ///   - range: 时间范围。
    /// - Returns: 没有账户时返回没有点的走势。
    func netWorthSeries(_ metric: NetWorthTrendMetric, range: BalanceTrendRange) -> BalanceTrendSeries {
        guard let earliestDay = ledgers.values.map(\.startDay).min() else {
            return BalanceTrendSeries(points: [], direction: metric.direction)
        }
        let samples = sampleDays(range: range, earliestDay: earliestDay)
        let days = samples.map { $0.day }
        var assets = [Decimal](repeating: .zero, count: days.count)
        var liabilities = [Decimal](repeating: .zero, count: days.count)
        for ledger in ledgers.values {
            for (index, amount) in Self.amounts(of: ledger, at: days).enumerated() {
                guard let amount else { continue }
                if ledger.isDebt {
                    liabilities[index] += amount
                } else {
                    assets[index] += amount
                }
            }
        }

        return BalanceTrendSeries(
            points: samples.indices.map { index in
                let amount = switch metric {
                case .netAssets: assets[index] - liabilities[index]
                case .assets: assets[index]
                case .liabilities: liabilities[index]
                }
                return BalanceTrendPoint(day: samples[index].day, date: samples[index].date, amount: amount)
            },
            direction: metric.direction
        )
    }

    /// 范围内要取点的业务日，从早到晚；最后一天总在里面。
    ///
    /// 一年多以内逐日取点；更长时按周取点，再长按月（30 天）取点，避免一条线上挤上千个点。
    ///
    /// - Parameters:
    ///   - range: 时间范围。
    ///   - earliestDay: 最早计入的业务日；范围起点早于它时从它开始，不留一段空白。
    /// - Returns: 业务日和对应日期；日期无法解析时只返回最后一天。
    func sampleDays(range: BalanceTrendRange, earliestDay: Int) -> [(day: Int, date: Date)] {
        guard let endDate = TransactionDay.date(from: endDay, calendar: calendar) else { return [] }
        let earliestDate = TransactionDay.date(from: earliestDay, calendar: calendar) ?? endDate
        let rangeStart = range.startDate(endingAt: endDate, calendar: calendar) ?? earliestDate
        let startDate = max(earliestDate, rangeStart)
        guard startDate < endDate else { return [(day: endDay, date: endDate)] }

        let dayCount = calendar.dateComponents([.day], from: startDate, to: endDate).day ?? 0
        let step = switch dayCount {
        case ...400: 1
        case ...2_800: 7
        default: 30
        }

        var samples: [(day: Int, date: Date)] = []
        var offset = 0
        while let date = calendar.date(byAdding: .day, value: -offset, to: endDate), date >= startDate {
            samples.append((day: TransactionDay.encode(date, calendar: calendar), date: date))
            offset += step
        }
        // 按周或按月取点时起点不一定正好落上，补上起点让线从第一天画起
        if samples.last?.date != startDate {
            samples.append((day: TransactionDay.encode(startDate, calendar: calendar), date: startDate))
        }
        return samples.reversed()
    }

    /// 业务日的前一天；日期无法解析时原样返回。
    ///
    /// - Parameters:
    ///   - day: `YYYYMMDD` 业务日。
    ///   - calendar: 公历。
    private static func day(before day: Int, calendar: Calendar) -> Int {
        guard let date = TransactionDay.date(from: day, calendar: calendar),
              let previous = calendar.date(byAdding: .day, value: -1, to: date)
        else { return day }
        return TransactionDay.encode(previous, calendar: calendar)
    }

    /// 账户在各采样日结束时的金额：从当前余额开始往前倒推。
    ///
    /// - Parameters:
    ///   - ledger: 账户推算材料。
    ///   - days: 从早到晚排列的采样业务日。
    /// - Returns: 与 `days` 一一对应；账户开始计入之前为 `nil`。
    static func amounts(of ledger: Ledger, at days: [Int]) -> [Decimal?] {
        var amounts = [Decimal?](repeating: nil, count: days.count)
        var running = ledger.balance
        var changeIndex = 0
        for index in days.indices.reversed() {
            let day = days[index]
            // 减去这一天之后的流水，得到这一天结束时的金额
            while changeIndex < ledger.changes.count, ledger.changes[changeIndex].day > day {
                running -= ledger.changes[changeIndex].amount
                changeIndex += 1
            }
            amounts[index] = day >= ledger.startDay ? running : nil
        }
        return amounts
    }
}
