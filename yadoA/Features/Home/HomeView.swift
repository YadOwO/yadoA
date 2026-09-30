import SwiftData
import SwiftUI

/// 首页入口，展示固定头部和当前月份的只读明细。
struct HomeView: View {
    @Environment(\.locale) private var locale

    /// 用户最近一次选择的收支汇总显隐状态。
    @AppStorage("home.summary.amountsVisible") private var areAmountsVisible = false

    /// 首页头像打开个人设置页。
    @State private var isProfilePresented = false

    var body: some View {
        HomeQueryContent(areAmountsVisible: $areAmountsVisible)
            .navigationTitle(AppTab.home.title(locale: locale))
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $isProfilePresented) {
                NavigationStack {
                    ProfileView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isProfilePresented = true
                    } label: {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.title2.weight(.regular))
                            .foregroundStyle(Color.accentColor)
                    }
                    .accessibilityLabel(AccountLocalization.string("profile.title", locale: locale))
                    .accessibilityIdentifier("home-profile")
                }
            }
    }
}

/// 首页跨账户查询内容，负责把 SwiftData 结果转换为当前月份展示。
private struct HomeQueryContent: View {
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var environmentCalendar
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Binding private var areAmountsVisible: Bool
    @Query private var transactions: [AccountTransaction]

    /// 当前已提交的月份；首次出现时由投影根据数据初始化。
    @State private var selectedMonth: HomeMonth?

    /// 是否展示月份选择 Sheet。
    @State private var isMonthPickerPresented = false

    init(areAmountsVisible: Binding<Bool>) {
        _areAmountsVisible = areAmountsVisible
        _transactions = Query(HomeOverviewPresentation.descriptor())
    }

    var body: some View {
        let presentation = HomeOverviewPresentation(
            transactions: transactions,
            calendar: environmentCalendar,
            locale: locale
        )
        let activeMonth = selectedMonth ?? presentation.initialMonth
        let monthPresentation = presentation.presentation(for: activeMonth)

        GeometryReader { geometry in
            VStack(spacing: 0) {
                let header = HomeOverviewHeader(
                    monthPresentation: monthPresentation,
                    areAmountsVisible: $areAmountsVisible,
                    onSelectMonth: {
                        isMonthPickerPresented = true
                    }
                )
                if dynamicTypeSize.isAccessibilitySize || verticalSizeClass == .compact {
                    // 大字号与紧凑高度下汇总独立滚动，给原有月份手势列表保留空间。
                    ScrollView {
                        header
                    }
                    .frame(maxHeight: geometry.size.height * 0.5)
                } else {
                    header
                }

                HomeOverviewList(
                    monthPresentation: monthPresentation,
                    monthNavigator: HomeMonthNavigator(availableMonths: presentation.availableMonths),
                    selectedMonth: activeMonth,
                    onSelectMonth: { month in
                        selectedMonth = month
                    }
                )
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Spacer()
                HomeAddTransactionButton()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Color(uiColor: .systemGroupedBackground))
        }
        .onAppear {
            if selectedMonth == nil {
                selectedMonth = presentation.initialMonth
            }
        }
        .sheet(isPresented: $isMonthPickerPresented) {
            NavigationStack {
                HomeMonthPickerView(
                    initialMonth: activeMonth,
                    onCancel: {
                        isMonthPickerPresented = false
                    },
                    onConfirm: { month in
                        selectedMonth = month
                        isMonthPickerPresented = false
                    }
                )
            }
        }
    }
}

/// 首页固定头部，展示月份入口、月度收支和金额显隐控制。
private struct HomeOverviewHeader: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 当前月份的已本地化展示数据。
    let monthPresentation: HomeOverviewMonthPresentation

    /// 是否展示收入和支出的实际金额。
    @Binding var areAmountsVisible: Bool

    /// 用户点击月份入口后的回调。
    let onSelectMonth: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center, spacing: 12) {
                    Button(action: onSelectMonth) {
                        HStack(spacing: 8) {
                            Text(monthPresentation.formattedMonth)
                                .font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        Text(
                            AccountLocalization.formatted(
                                "home.month.selector.accessibility",
                                value: monthPresentation.formattedMonth,
                                locale: locale
                            )
                        )
                    )
                    .accessibilityIdentifier("home-month-selector")

                    Spacer()

                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            areAmountsVisible.toggle()
                        }
                    } label: {
                        Image(systemName: areAmountsVisible ? "eye" : "eye.slash")
                            .font(.system(size: 17))
                            .foregroundStyle(.secondary)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 44, height: 44)
                            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        Text(
                            AccountLocalization.string(
                                areAmountsVisible
                                    ? "home.summary.hide"
                                    : "home.summary.show",
                                locale: locale
                            )
                        )
                    )
                    .accessibilityValue(
                        Text(
                            AccountLocalization.string(
                                areAmountsVisible
                                    ? "home.summary.visible"
                                    : "home.summary.hidden",
                                locale: locale
                            )
                        )
                    )
                    .accessibilityIdentifier("home-summary-visibility")
                }

                Divider().overlay(Color.primary.opacity(0.02))

                let summaryLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                summaryLayout {
                    HomeSummaryColumn(
                        title: AccountLocalization.string("home.summary.expense", locale: locale),
                        amount: monthPresentation.expenseTotal,
                        isVisible: areAmountsVisible,
                        isIncome: false,
                        locale: locale
                    )

                    HomeSummaryColumn(
                        title: AccountLocalization.string("home.summary.income", locale: locale),
                        amount: monthPresentation.incomeTotal,
                        isVisible: areAmountsVisible,
                        isIncome: true,
                        locale: locale
                    )
                }
            }
            .padding(20)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))

            HStack {
                Text(
                    AccountLocalization.string(
                        monthPresentation.isEmpty
                            ? "home.details.empty.title"
                            : "home.details.title",
                        locale: locale
                    )
                )
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                Spacer()
                Image(systemName: "list.bullet")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-fixed-header")
    }
}

/// 首页顶部单个收入或支出汇总列。
private struct HomeSummaryColumn: View {
    /// 汇总标题。
    let title: String

    /// 精确的月度金额。
    let amount: Decimal

    /// 是否显示实际金额。
    let isVisible: Bool

    /// 是否为收入列，用于稳定生成自动化标识。
    let isIncome: Bool

    /// 当前语言环境。
    let locale: Locale

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: isIncome ? "arrow.down.left" : "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isIncome ? Color.accentColor : Color.primary)
                    .frame(width: 24, height: 24)
                    .background(
                        isIncome ? Color.accentColor.opacity(0.09) : Color.primary.opacity(0.05),
                        in: Circle()
                    )
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(isVisible ? formattedAmount : AccountLocalization.string("home.summary.mask", locale: locale))
                .font(.system(.title, design: .rounded, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
                .accessibilityLabel(Text(title))
                .accessibilityValue(
                    Text(
                        isVisible
                            ? formattedAmount
                            : AccountLocalization.string("home.summary.hidden", locale: locale)
                    )
                )
                .accessibilityIdentifier(isIncome ? "home-summary-income" : "home-summary-expense")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 使用应用当前固定的 CNY 货币格式化金额。
    private var formattedAmount: String {
        amount.formatted(.currency(code: "CNY").locale(locale))
    }
}

/// 首页主要操作，使用系统按钮反馈；新系统显示玻璃效果，iOS 18 保留原生实色按钮。
private struct HomeAddTransactionButton: View {
    @Environment(\.locale) private var locale

    var body: some View {
        if #available(iOS 26, *) {
            entryLink.buttonStyle(.glassProminent)
        } else {
            entryLink.buttonStyle(.borderedProminent)
        }
    }

    /// 沿用原有记账路由和本地化标题，整颗胶囊均为点击区域。
    private var entryLink: some View {
        NavigationLink(value: HomeRoute.expenseEntry) {
            Label(AccountLocalization.string("expense.entry.action", locale: locale), systemImage: "plus")
                .font(.headline)
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
        .accessibilityIdentifier("home-add-expense")
    }
}

/// 当前月份的独立明细滚动区域。
private struct HomeOverviewList: View {
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 边界拉动与松手提交状态。
    @State private var interaction = HomeMonthScrollInteraction()

    /// 当前月份的按日展示数据。
    let monthPresentation: HomeOverviewMonthPresentation

    /// 仅在有真实流水的月份之间导航，找不到目标时禁止切换。
    let monthNavigator: HomeMonthNavigator

    /// 当前已提交月份。
    let selectedMonth: HomeMonth

    /// 月份切换回调。
    let onSelectMonth: (HomeMonth) -> Void

    var body: some View {
        GeometryReader { containerGeometry in
            List {
                if monthPresentation.isEmpty {
                    HomeEmptyState()
                        .frame(
                            maxWidth: .infinity,
                            minHeight: max(0, containerGeometry.size.height - 2)
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(monthPresentation.dayGroups) { day in
                        Section {
                            ForEach(day.rows) { row in
                                HomeOverviewRow(row: row)
                                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                                    .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
                                    .alignmentGuide(.listRowSeparatorLeading) { _ in 58 }
                            }
                        } header: {
                            HomeOverviewDayHeader(day: day)
                        }
                    }
                }

                Color.clear
                    .frame(height: 1)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(20)
            .contentMargins(.top, 0, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .scrollBounceBehavior(.always)
            .accessibilityIdentifier("home-details-scroll")
            .onScrollGeometryChange(for: HomeMonthScrollInteraction.Pull?.self) { geometry in
                pull(for: geometry)
            } action: { _, pull in
                interaction.update(pull)
            }
            .onScrollPhaseChange { oldPhase, phase, context in
                if phase == .interacting {
                    interaction.beginDragging()
                    interaction.update(pull(for: context.geometry))
                } else if oldPhase == .interacting {
                    interaction.update(pull(for: context.geometry))
                    interaction.endDragging()
                }
                if phase == .idle,
                   let direction = interaction.settle(),
                   let month = targetMonth(for: direction) {
                    onSelectMonth(month)
                }
            }
            // 每个月从顶部开始，避免原生回弹与 scrollTo 动画争夺偏移。
            .id(selectedMonth)
            .transition(.opacity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: selectedMonth)
        }
        .overlay(alignment: interaction.pull?.direction == .earlier ? .bottom : .top) {
            if let pull = interaction.pull,
               let month = targetMonth(for: pull.direction) {
                Label {
                    Text(AccountLocalization.formatted(
                        pull.isReady ? "home.month.pull.release" : "home.month.pull.continue",
                        value: month.formatted(locale: locale, calendar: calendar),
                        locale: locale
                    ))
                } icon: {
                    Image(systemName: pull.direction == .later ? "arrow.down" : "arrow.up")
                        .rotationEffect(.degrees(pull.isReady ? 180 : 0))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(8)
                .allowsHitTesting(false)
                .accessibilityIdentifier("home-month-pull-hint")
            }
        }
        .sensoryFeedback(.selection, trigger: isReadyToSwitch) { _, isReady in
            isReady
        }
        .onChange(of: selectedMonth) { _, _ in
            interaction = HomeMonthScrollInteraction()
        }
        .onDisappear {
            interaction = HomeMonthScrollInteraction()
        }
    }

    /// 仅在确实存在目标月份时提供越过阈值的触觉反馈。
    private var isReadyToSwitch: Bool {
        guard let pull = interaction.pull, pull.isReady else { return false }
        return targetMonth(for: pull.direction) != nil
    }

    /// 把原生几何归约为离散的提示状态。
    private func pull(for geometry: ScrollGeometry) -> HomeMonthScrollInteraction.Pull? {
        HomeMonthScrollInteraction.pull(
            offsetY: geometry.contentOffset.y,
            contentHeight: geometry.contentSize.height,
            containerHeight: geometry.containerSize.height,
            topInset: geometry.contentInsets.top,
            bottomInset: geometry.contentInsets.bottom
        )
    }

    /// 下拉查看更晚、上拉查看更早的最近有数据月份；没有目标时停止切换。
    private func targetMonth(for direction: HomeMonthScrollInteraction.Direction) -> HomeMonth? {
        switch direction {
        case .earlier: return monthNavigator.earlierMonth(from: selectedMonth)
        case .later: return monthNavigator.laterMonth(from: selectedMonth)
        }
    }
}

/// 首页原生列表中的日期分组标题。
private struct HomeOverviewDayHeader: View {
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 当前日期组数据。
    let day: HomeOverviewDayPresentation

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        layout {
            VStack(alignment: .leading, spacing: 4) {
                Text(day.formattedDate)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(day.formattedWeekday)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(daySummary)
                .font(.caption.monospacedDigit())
                .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
        .textCase(nil)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home-day-\(day.transactionDay)")
    }

    /// 当前日期组的收入和支出摘要。
    private var daySummary: String {
        let income = day.incomeTotal.formatted(.currency(code: "CNY").locale(locale))
        let expense = day.expenseTotal.formatted(.currency(code: "CNY").locale(locale))
        return String(
            format: AccountLocalization.string("home.day.summary", locale: locale),
            locale: locale,
            income,
            expense
        )
    }
}

/// 首页单条只读流水行。
private struct HomeOverviewRow: View {
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 已完成本地化的首页行数据。
    let row: HomeOverviewRowPresentation

    var body: some View {
        NavigationLink(value: HomeRoute.transactionDetail(row.id)) {
            HStack(spacing: 14) {
                Image(systemName: row.symbolName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 42, height: 44)
                    .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 14))
                    .accessibilityHidden(true)

                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                    : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
                layout {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(row.title)
                            .font(.body.weight(.medium))
                        if let note = row.note {
                            Text(note)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(row.formattedAmount)
                        .font(.system(.body, design: .rounded, weight: .semibold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .layoutPriority(1)
                }
            }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityHint(
            Text(
                AccountLocalization.formatted(
                    "bookkeeping.detail.open",
                    value: row.title,
                    locale: locale
                )
            )
        )
        .accessibilityIdentifier("home-transaction-\(row.id.uuidString)")
    }
}

/// 首页没有真实收入或支出流水时的本地化空状态。
private struct HomeEmptyState: View {
    @Environment(\.locale) private var locale

    var body: some View {
        ContentUnavailableView {
            Label(
                AccountLocalization.string("home.details.empty.title", locale: locale),
                systemImage: "tray"
            )
        } description: {
            Text(AccountLocalization.string("home.details.empty.message", locale: locale))
        }
        .accessibilityIdentifier("home-details-empty")
    }
}

#Preview("Home empty") {
    NavigationStack {
        HomeView()
    }
    .modelContainer(
        for: [Account.self, AccountTransaction.self, BookkeepingPreference.self],
        inMemory: true
    )
}
