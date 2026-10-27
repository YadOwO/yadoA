import Charts
import SwiftUI

/// 演示：钱花在哪、怎么变、还剩多少，三张卡对应图表页的分类排行、趋势和账户页的资产汇总。
///
/// 卡片自动往后翻，也可以点标签或左右滑。数字都是示例，第 3 步记下的午饭和打车算在今天里；不读取真实账本。
struct OnboardingInsightStep: View {
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 触感。
    let haptics: OnboardingHaptics

    /// 进入下一行。
    let onContinue: () -> Void

    /// 三张卡。
    enum Beat: Int, CaseIterable, Identifiable {
        /// 花在哪：分类排行。
        case spending
        /// 怎么变：每天的支出走势。
        case trend
        /// 还剩多少：净资产与各账户余额。
        case worth

        var id: Int { rawValue }

        /// 标签文案键。
        var titleKey: String {
            switch self {
            case .spending: "onboarding.insight.tab.spending"
            case .trend: "onboarding.insight.tab.trend"
            case .worth: "onboarding.insight.tab.worth"
            }
        }

        /// 下一张；最后一张为 nil。
        var next: Beat? {
            Beat(rawValue: rawValue + 1)
        }
    }

    @State private var selection = Beat.spending

    /// 标题写完后出现卡片。
    @State private var isDetailVisible = false

    /// 已经展开过数字的卡片；第一次翻到时数字滚到位、条和点依次长出来。
    @State private var revealed: Set<Beat> = []

    /// 用户点过标签后不再自动翻。
    @State private var isAutoAdvanceStopped = false

    @Namespace private var tabUnderline

    var body: some View {
        OnboardingPage {
            OnboardingInkText(
                text: text("onboarding.insight.title"),
                haptics: haptics,
                onWritten: { isDetailVisible = true }
            )
            .accessibilityAddTraits(.isHeader)

            tabs
                .padding(.top, 20)
                .onboardingReveal(isDetailVisible)

            TabView(selection: $selection) {
                ForEach(Beat.allCases) { beat in
                    card(for: beat)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 4)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .tag(beat)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 440)
            .padding(.top, 14)
            .onboardingReveal(isDetailVisible, delay: 0.15)
        } actions: {
            Button(text("onboarding.continue"), action: onContinue)
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .onboardingReveal(isDetailVisible, delay: 0.3)
                .disabled(!isDetailVisible)
        }
        .onChange(of: isDetailVisible) { _, isVisible in
            if isVisible { reveal(selection) }
        }
        .onChange(of: selection) { _, beat in
            haptics.selection()
            reveal(beat)
        }
        // 每翻到一张重新计时；停在最后一张，或用户点过标签后不再自动翻
        .task(id: selection) {
            guard !reduceMotion else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, isDetailVisible, !isAutoAdvanceStopped, let next = selection.next else { return }
            withAnimation(.spring(duration: 0.55, bounce: 0.12)) {
                selection = next
            }
        }
    }

    // MARK: - 标签

    /// 三个标签，选中的下面压一道墨线，跟着选中项滑过去。
    private var tabs: some View {
        HStack(spacing: 18) {
            ForEach(Beat.allCases) { beat in
                Button {
                    isAutoAdvanceStopped = true
                    withAnimation(.spring(duration: 0.45, bounce: 0.15)) {
                        selection = beat
                    }
                } label: {
                    tabLabel(for: beat)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == beat ? .isSelected : [])
            }
            Spacer(minLength: 0)
            OnboardingSampleBadge()
        }
    }

    /// 一个标签：选中时文字加粗，下面压一道账本红的墨线。
    private func tabLabel(for beat: Beat) -> some View {
        let isSelected = selection == beat
        return VStack(spacing: 5) {
            Text(text(beat.titleKey))
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            ZStack {
                if isSelected {
                    HandDrawnRule(seed: 81)
                        .stroke(Color(.ledgerRed), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .matchedGeometryEffect(id: "underline", in: tabUnderline)
                }
            }
            .frame(height: 3)
        }
        .fixedSize()
    }

    // MARK: - 卡片

    @ViewBuilder
    private func card(for beat: Beat) -> some View {
        let isRevealed = revealed.contains(beat)
        switch beat {
        case .spending:
            spendingCard(isRevealed: isRevealed)
        case .trend:
            trendCard(isRevealed: isRevealed)
        case .worth:
            worthCard(isRevealed: isRevealed)
        }
    }

    /// 花在哪：7 天总额加分类排行，排行直接用图表页的组件。
    private func spendingCard(isRevealed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(text("onboarding.insight.spending.caption"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(OnboardingSamples.currency(isRevealed ? OnboardingInsightSamples.weekTotal : Decimal.zero, locale: locale))
                    .font(.system(.title, design: .serif, weight: .medium).monospacedDigit())
                    .contentTransition(.numericText(value: isRevealed ? 1 : 0))
            }
            CategoryRankingView(
                title: text("chart.category.title"),
                items: OnboardingInsightSamples.categories(locale: locale)
            )
            .opacity(isRevealed ? 1 : 0)
            .offset(y: isRevealed || reduceMotion ? 0 : 10)
        }
        .modifier(OnboardingInsightCardFrame(seed: 5))
    }

    /// 怎么变：近 7 天每天的支出折线和日均线，今天那个点标红；写法与图表页的趋势卡一致。
    private func trendCard(isRevealed: Bool) -> some View {
        let days = OnboardingInsightSamples.days(calendar: calendar, locale: locale)
        let average = OnboardingInsightSamples.dailyAverage
        return VStack(alignment: .leading, spacing: 14) {
            Text(AccountLocalization.formatted(
                "onboarding.insight.trend.caption",
                value: OnboardingSamples.currency(OnboardingInsightSamples.today, locale: locale),
                locale: locale
            ))
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)

            Chart {
                ForEach(days) { day in
                    LineMark(
                        x: .value(text("chart.axis.period"), day.label),
                        y: .value(text("chart.axis.expense"), isRevealed ? day.amount : 0)
                    )
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                    PointMark(
                        x: .value(text("chart.axis.period"), day.label),
                        y: .value(text("chart.axis.expense"), isRevealed ? day.amount : 0)
                    )
                    .foregroundStyle(day.isToday ? Color(.ledgerRed) : Color.accentColor)
                    .symbolSize(day.isToday ? 70 : 16)
                    .accessibilityLabel(day.label)
                    .accessibilityValue(OnboardingSamples.currency(Decimal(day.amount), locale: locale))
                }
                RuleMark(y: .value(text("onboarding.insight.trend.average"), isRevealed ? average : 0))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .leading) {
                        Text(text("onboarding.insight.trend.average"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
            }
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0.0, 50.0, 100.0]) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1, lineCap: .round))
                        .foregroundStyle(Color.primary.opacity(0.12))
                    AxisValueLabel()
                        .font(.system(.caption2, design: .serif).monospacedDigit())
                }
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let label = value.as(String.self) {
                            Text(label)
                                .font(.system(.caption2, design: .serif))
                                .foregroundStyle(label == days.last?.label ? Color(.ledgerRed) : Color.secondary)
                        }
                    }
                }
            }
            .frame(height: 190)

            Text(text("onboarding.insight.trend.note"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .modifier(OnboardingInsightCardFrame(seed: 13))
    }

    /// 还剩多少：账户页的资产汇总卡和账户行，净资产 = 资产 − 负债。
    private func worthCard(isRevealed: Bool) -> some View {
        let accounts = OnboardingInsightSamples.accounts(locale: locale)
        return VStack(alignment: .leading, spacing: 12) {
            AccountSummaryCard(presentation: OnboardingInsightSamples.summary(isRevealed: isRevealed, locale: locale))
                .contentTransition(.numericText())

            VStack(spacing: 0) {
                ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                    AccountListRow(presentation: account)
                        .padding(.vertical, 6)
                        .opacity(isRevealed ? 1 : 0)
                        .offset(y: isRevealed || reduceMotion ? 0 : 8)
                        .animation(.spring(duration: 0.45, bounce: 0.2).delay(0.25 + Double(index) * 0.08), value: isRevealed)
                }
            }
            .padding(.horizontal, 8)
        }
    }

    /// 第一次翻到一张卡时展开数字，金额落定时一下，条和点每长出一个一下。
    private func reveal(_ beat: Beat) {
        guard isDetailVisible, !revealed.contains(beat) else { return }
        withAnimation(.spring(duration: 0.8, bounce: 0.1)) {
            _ = revealed.insert(beat)
        }
        let count = switch beat {
        case .spending: OnboardingInsightSamples.categoryAmounts.count
        case .trend: OnboardingInsightSamples.dailyAmounts.count
        case .worth: OnboardingInsightSamples.accountCount
        }
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            haptics.nudge()
            try? await Task.sleep(for: .milliseconds(150))
            haptics.ripple(count: count, interval: 0.08)
        }
    }

    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 演示卡片的手画外框，与图表页趋势卡一致。
private struct OnboardingInsightCardFrame: ViewModifier {
    /// 笔迹种子。
    let seed: UInt64

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                HandDrawnBox(cornerRadius: 22, seed: seed)
                    .stroke(Color.primary.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
    }
}

/// 第 4 步的示例数字：7 天一共 408 元，其中今天 60 元正是第 3 步记下的午饭 32 和打车 28。
enum OnboardingInsightSamples {
    /// 示例中的一天。
    struct Day: Identifiable {
        /// 距今天的天数，今天为 0。
        let offset: Int
        /// 横轴标签：星期几，今天写“今天”。
        let label: String
        /// 当天支出。
        let amount: Double
        /// 是否为今天。
        var isToday: Bool { offset == 0 }
        var id: Int { offset }
    }

    /// 分类与金额，合计 408。
    static let categoryAmounts: [(category: ExpenseCategory, amount: Decimal)] = [
        (.dining, 186), (.shopping, 120), (.transportation, 64), (.dailyNecessities, 38),
    ]

    /// 从 6 天前到今天每天的支出，合计 408，今天 60。
    static let dailyAmounts: [Double] = [64, 38, 92, 55, 84, 15, 60]

    /// 7 天合计。
    static let weekTotal: Decimal = 408

    /// 今天的支出。
    static let today: Decimal = 60

    /// 日均支出。
    static var dailyAverage: Double {
        dailyAmounts.reduce(0, +) / Double(dailyAmounts.count)
    }

    /// 示例账户数。
    static let accountCount = 4

    /// 分类排行的数据。
    static func categories(locale: Locale) -> [CategoryRankingItem] {
        categoryAmounts.map { entry in
            let item = BookkeepingCategoryCatalog.presets.resolvedItem(direction: .expense, key: entry.category.rawValue)
            return CategoryRankingItem(id: item.id, title: item.title(locale: locale), symbolName: item.symbolName, amount: entry.amount)
        }
    }

    /// 近 7 天，横轴是星期几，最后一天写“今天”。
    static func days(calendar: Calendar, locale: Locale) -> [Day] {
        let today = Date.now
        return dailyAmounts.enumerated().map { index, amount in
            let offset = dailyAmounts.count - 1 - index
            let label: String
            if offset == 0 {
                label = AccountLocalization.string("onboarding.sample.today", locale: locale)
            } else {
                let date = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
                label = date.formatted(.dateTime.weekday(.abbreviated).locale(locale))
            }
            return Day(offset: offset, label: label, amount: amount)
        }
    }

    /// 示例账户：招商银行储蓄卡、微信、现金，以及欠款的花呗。
    static func accounts(locale: Locale) -> [AccountRowPresentation] {
        sampleAccounts.map { account in
            AccountListPresentation.row(
                id: account.id,
                accountType: account.type,
                templateID: account.templateID,
                name: AccountListPresentation.template(id: account.templateID, accountType: account.type)?.name(locale: locale)
                    ?? account.type.title(locale: locale),
                lastFourDigits: nil,
                balance: account.balance,
                currencyCode: "CNY",
                locale: locale
            )
        }
    }

    /// 资产汇总；展开前全是 0，展开时滚到位。
    static func summary(isRevealed: Bool, locale: Locale) -> AccountSummaryPresentation {
        var assets = Decimal.zero
        var liabilities = Decimal.zero
        for account in sampleAccounts where isRevealed {
            if account.type.expenseBalanceEffect == .increaseDebt {
                liabilities += account.balance
            } else {
                assets += account.balance
            }
        }
        return AccountSummaryPresentation.summary(assets: assets, liabilities: liabilities, locale: locale)
    }

    /// 示例账户的字段；资产 13,710，负债 2,300，净资产 11,410。
    private static let sampleAccounts: [(id: UUID, type: AccountType, templateID: String?, balance: Decimal)] = [
        (UUID(uuidString: "6F1D2C6E-0000-4000-8000-0000000000B1")!, .debitCard, "debitCard.cmb", 12_400),
        (UUID(uuidString: "6F1D2C6E-0000-4000-8000-0000000000B2")!, .virtualAccount, "virtualAccount.wechat", 1_050),
        (UUID(uuidString: "6F1D2C6E-0000-4000-8000-0000000000B3")!, .cash, nil, 260),
        (UUID(uuidString: "6F1D2C6E-0000-4000-8000-0000000000B4")!, .creditCard, "creditCard.huabei", 2_300),
    ]
}
