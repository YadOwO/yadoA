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

/// 走势金额的方向语义，决定涨跌算好还是算坏。
enum BalanceTrendDirection: Equatable, Sendable {
    /// 资产余额或净资产：变多是好事。
    case asset

    /// 信用卡、负债的欠款：按欠了多少（正数）画，变多是坏事。
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

    /// 整段走势变好还是变坏：线和「较某天」那一行都按它上色，跟随「正负颜色」设置；没有变化时不上色。
    var changeTone: AmountTone {
        tone(forChange: change)
    }

    /// 某一点金额本身的上色语义，与账户行一致：欠款、透支、净资产为负时用负向色。
    ///
    /// - Parameter amount: 走势上某一点的金额。
    func amountTone(for amount: Decimal) -> AmountTone {
        AccountListPresentation.amountTone(isDebt: direction == .debt, balance: amount)
    }

    /// 某个业务日对应的点；没有这一天或传入 `nil` 时为 `nil`。
    ///
    /// - Parameter day: `YYYYMMDD` 业务日。
    func point(day: Int?) -> BalanceTrendPoint? {
        guard let day else { return nil }
        return points.first { $0.day == day }
    }

    /// 离给定日期最近的点，供点按、滑动图表时选中；没有点时为 `nil`。
    ///
    /// 点按日期排好序，用二分查找，滑动时每一帧都要找一次。
    ///
    /// - Parameter date: 手指位置对应的日期。
    /// - Returns: 日期最接近的点；两边一样近时取较早的一个。
    func point(nearest date: Date) -> BalanceTrendPoint? {
        guard let first = points.first, let last = points.last else { return nil }
        // 找第一个不早于它的点，再和前一个比远近
        var low = 0
        var high = points.count
        while low < high {
            let middle = (low + high) / 2
            if points[middle].date < date {
                low = middle + 1
            } else {
                high = middle
            }
        }
        if low == 0 { return first }
        if low == points.count { return last }
        let before = points[low - 1]
        let after = points[low]
        return date.timeIntervalSince(before.date) <= after.date.timeIntervalSince(date) ? before : after
    }

    /// 读屏上下轻扫时换到的点：从选中的那天往后或往前挪几个点，到头就停在头上。
    ///
    /// - Parameters:
    ///   - day: 当前选中的业务日；还没选中时从最后一天开始。
    ///   - offset: 往后为正，往前为负。
    /// - Returns: 挪到的点；没有点时为 `nil`。
    func point(steppingFrom day: Int?, by offset: Int) -> BalanceTrendPoint? {
        guard !points.isEmpty else { return nil }
        guard let day, let index = points.firstIndex(where: { $0.day == day }) else {
            return points.last
        }
        return points[min(max(index + offset, 0), points.count - 1)]
    }

    /// 纵轴范围：上下各留一点空白，让线不贴边，起伏看得清；金额全都一样时围绕它展开。
    ///
    /// 金额都不为负时下沿不低于零，都不为正时上沿不高于零，避免出现没有意义的负数或正数刻度。
    var amountDomain: ClosedRange<Double> {
        let amounts = points.map(\.amount.doubleValue)
        guard let low = amounts.min(), let high = amounts.max() else { return 0...1 }
        // 全是零（例如没有负债）：把线放在底部
        if low == 0, high == 0 { return 0...1 }
        let padding = high > low ? (high - low) * 0.12 : max(abs(high) * 0.1, 1)
        var lower = low - padding
        var upper = high + padding
        if low >= 0 { lower = max(lower, 0) }
        if high <= 0 { upper = min(upper, 0) }
        return lower...upper
    }

    /// 金额是否有正有负；跨过零时在零处画一道淡线，看得出什么时候转正、转负。
    var crossesZero: Bool {
        points.contains { $0.amount < 0 } && points.contains { $0.amount > 0 }
    }
}

/// 按日推算账户余额的历史。
///
/// 以账户当前余额为终点，往前每跨过一天就减去那天流水的影响，所以走势的最后一点总是等于账户页上显示的金额。
/// 流水规则与余额缓存一致，都来自 `AccountBalanceRebuilder.balanceChanges`。
/// 账户从建账那天、或最早一笔流水的前一天（取更早的）开始计入，在此之前不算；
/// 留出前一天是为了让期初余额也成为线上的一点，建账当天就记了账也能看到第一笔带来的变化。
///
/// 最费时的是把全部流水汇总成每个账户每天的变化（`Ledger`）。界面上由 `BalanceHistoryStore`
/// 在本地数据变化后汇总一次并缓存，这里只用汇总好的材料取点，切换范围、金额种类和滑动查看都不再读流水。
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

    /// 逐笔汇总流水，得到各账户每天的余额变化；缓存分批读取流水时一笔一笔加进来。
    ///
    /// 未知类型的账户无法判断流水方向，不汇总它的流水，按当前余额从建账日起保持不变；与汇总卡片一样计入资产。
    struct LedgerBuilder {
        /// 已知类型的账户，决定流水让余额变多还是变少。
        private let accountTypes: [UUID: AccountType]

        /// 账户 UUID → 业务日 → 当天余额变化合计。
        private var changesByAccount: [UUID: [Int: Decimal]] = [:]

        /// - Parameter accounts: 要汇总的账户。
        init(accounts: [Account]) {
            var accountTypes: [UUID: AccountType] = [:]
            for account in accounts {
                if let type = account.accountType { accountTypes[account.id] = type }
            }
            self.accountTypes = accountTypes
        }

        /// 加入一笔流水；业务日无效、字段损坏或与这些账户无关的不计。
        ///
        /// - Parameter transaction: 一笔流水。
        mutating func add(_ transaction: AccountTransaction) {
            let day = transaction.transactionDay
            // 展示用的推算：极端金额算不出来时跳过这一笔，不影响页面其他内容
            guard TransactionDay.isValid(day),
                  let changes = try? AccountBalanceRebuilder.balanceChanges(
                      of: transaction,
                      accountTypes: accountTypes
                  )
            else { return }
            for change in changes {
                changesByAccount[change.accountID, default: [:]][day, default: .zero] += change.amount
            }
        }

        /// 生成各账户的推算材料。
        ///
        /// - Parameters:
        ///   - accounts: 与建立时相同的账户，提供当前余额和建账日。
        ///   - calendar: 提供时区的日历，内部统一换成公历。
        /// - Returns: 账户 UUID 到推算材料的映射。
        func ledgers(for accounts: [Account], calendar sourceCalendar: Calendar) -> [UUID: Ledger] {
            let calendar = TransactionDay.gregorianCalendar(basedOn: sourceCalendar)
            var ledgers: [UUID: Ledger] = [:]
            for account in accounts {
                let changes = changesByAccount[account.id] ?? [:]
                let createdDay = TransactionDay.encode(account.createdAt, calendar: calendar)
                let openingDay = changes.keys.min()
                    .map { AccountBalanceHistory.day(before: $0, calendar: calendar) } ?? createdDay
                ledgers[account.id] = Ledger(
                    startDay: min(createdDay, openingDay),
                    balance: account.balance,
                    isDebt: account.accountType?.expenseBalanceEffect == .increaseDebt,
                    changes: changes
                        .map { (day: $0.key, amount: $0.value) }
                        .sorted { $0.day > $1.day }
                )
            }
            return ledgers
        }
    }

    /// 参与推算的账户，键为账户 UUID。
    let ledgers: [UUID: Ledger]

    /// 走势的最后一天：今天和最晚一笔流水取更晚的，让终点包含所有已记的流水。
    let endDay: Int

    /// 推算日期使用的公历，时区沿用调用方。
    private let calendar: Calendar

    /// 由已经汇总好的材料建立；界面用 `BalanceHistoryStore` 缓存的材料走这里，不读流水。
    ///
    /// - Parameters:
    ///   - ledgers: 各账户的推算材料。
    ///   - accountIDs: 只看这些账户；为 `nil` 时看全部。
    ///   - today: 今天，决定走势至少画到哪天。
    ///   - calendar: 提供时区的日历，内部统一换成公历。
    init(
        ledgers: [UUID: Ledger],
        accountIDs: Set<UUID>? = nil,
        today: Date = .now,
        calendar sourceCalendar: Calendar = .current
    ) {
        let calendar = TransactionDay.gregorianCalendar(basedOn: sourceCalendar)
        let selected = accountIDs.map { ids in ledgers.filter { ids.contains($0.key) } } ?? ledgers
        self.calendar = calendar
        self.ledgers = selected
        // 变化按从晚到早排，第一条就是这个账户最晚的一笔
        let latestDay = selected.values.compactMap { $0.changes.first?.day }.max()
        self.endDay = max(TransactionDay.encode(today, calendar: calendar), latestDay ?? .min)
    }

    /// 由账户和流水直接建立，测试和预览用；界面上走 `BalanceHistoryStore` 的缓存。
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
        var builder = LedgerBuilder(accounts: accounts)
        for transaction in transactions {
            builder.add(transaction)
        }
        self.init(
            ledgers: builder.ledgers(for: accounts, calendar: sourceCalendar),
            today: today,
            calendar: sourceCalendar
        )
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
