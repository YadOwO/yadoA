import SwiftData
import SwiftUI

/// 首页入口，展示导航栏月份入口、紧凑汇总和当前月份的只读明细。
struct HomeView: View {
    @Environment(\.locale) private var locale

    /// 用户最近一次选择的收支汇总显隐状态。
    @AppStorage("home.summary.amountsVisible") private var areAmountsVisible = false

    /// 首页头像打开个人设置页。
    @State private var isProfilePresented = false

    var body: some View {
        HomeQueryContent(areAmountsVisible: $areAmountsVisible)
            .navigationTitle(AppTab.home.title(locale: locale))
            // 标题仅供返回按钮和辅助功能使用，导航栏中部由月份入口占据。
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $isProfilePresented) {
                NavigationStack {
                    ProfileView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: HomeRoute.bills) {
                        Label(AccountLocalization.string("bill.title", locale: locale), systemImage: "doc.text")
                    }
                    .accessibilityIdentifier("home-bills")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isProfilePresented = true
                    } label: {
                        // 与旁边的账单图标同为线稿，放在同一块玻璃里轻重一致。
                        Image(systemName: "person.crop.circle")
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

    /// 悬浮记账按钮占用的底部高度，列表末尾据此留白，保证最后一条流水能滚到按钮上方。
    @State private var addButtonClearance: CGFloat = 76

    /// 首页当前是否在导航栈顶部可见；被记账页盖住时不消费新流水提示。
    @State private var isVisible = false

    /// 正在标红提示的新流水，提示结束后清空。
    @State private var highlightedTransactionID: UUID?

    /// 刚保存成功的流水提示通道。
    private let recentEntryHighlight = HomeRecentEntryHighlight.shared

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
                    areAmountsVisible: $areAmountsVisible
                )
                // 大字号与紧凑高度下汇总可能很高，不适合压在明细上方。
                let usesStackedHeader = dynamicTypeSize.isAccessibilitySize || verticalSizeClass == .compact
                if usesStackedHeader {
                    // 此时汇总独立滚动，给原有月份手势列表保留空间。
                    ScrollView {
                        header
                    }
                    .frame(maxHeight: geometry.size.height * 0.5)
                }

                HomeOverviewList(
                    monthPresentation: monthPresentation,
                    monthNavigator: HomeMonthNavigator(availableMonths: presentation.availableMonths),
                    selectedMonth: activeMonth,
                    highlightedTransactionID: highlightedTransactionID,
                    bottomClearance: addButtonClearance,
                    onSelectMonth: { month in
                        selectedMonth = month
                    }
                )
                // 常规布局下汇总作为明细的顶部栏：流水从它下方滑过并在边缘柔和淡出，而不是被一刀切掉。
                .modifier(HomeTopBar(isEnabled: !usesStackedHeader) { header })
            }
        }
        .paperPage()
        // 按钮悬浮在明细之上且不带整条底栏；居中放置以避开右侧的金额列。
        .overlay(alignment: .bottom) {
            HomeAddTransactionButton()
                .padding(.vertical, 12)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    addButtonClearance = height
                }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                HomeMonthSelectorButton(formattedMonth: monthPresentation.formattedMonth) {
                    isMonthPickerPresented = true
                }
            }
        }
        .onAppear {
            if selectedMonth == nil {
                selectedMonth = presentation.initialMonth
            }
            isVisible = true
            showRecentEntryHighlightIfNeeded()
        }
        .onDisappear {
            isVisible = false
        }
        // 截图记账以全屏模态盖在首页之上，关闭时不会再次触发 onAppear，需要直接响应登记。
        .onChange(of: recentEntryHighlight.pending) { _, _ in
            showRecentEntryHighlightIfNeeded()
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

extension HomeQueryContent {
    /// 新流水提示从标红到完全回到默认色所需的总时长，之后清除标记。
    private static let highlightLifetime: Duration = .seconds(4)

    /// 首页可见时取走刚保存的流水：切到它所在的月份，并让对应行短暂标红。
    private func showRecentEntryHighlightIfNeeded() {
        guard isVisible, let entry = recentEntryHighlight.consume() else { return }

        if let month = HomeMonth(value: entry.transactionDay / 100) {
            selectedMonth = month
        }
        highlightedTransactionID = entry.id
        Task {
            try? await Task.sleep(for: Self.highlightLifetime)
            if highlightedTransactionID == entry.id {
                highlightedTransactionID = nil
            }
        }
    }
}

/// 把汇总挂为明细列表的顶部栏。
///
/// iOS 26 使用系统的 `safeAreaBar`，由滚动边缘效果处理内容淡出；
/// 更早的系统用 `safeAreaInset` 加一层向下渐隐的纸色底得到相近的效果。
private struct HomeTopBar<Bar: View>: ViewModifier {
    /// 是否启用顶部栏；关闭时不占用任何空间。
    let isEnabled: Bool

    /// 顶部栏内容。
    @ViewBuilder let bar: () -> Bar

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .safeAreaBar(edge: .top, spacing: 0) {
                    if isEnabled {
                        bar()
                    }
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content.safeAreaInset(edge: .top, spacing: 0) {
                if isEnabled {
                    bar().background {
                        // 上方是实的纸色，靠近明细的一小段渐隐，让流水滑入时不出现硬边。
                        LinearGradient(
                            stops: [
                                .init(color: Color(.paperBackground), location: 0),
                                .init(color: Color(.paperBackground), location: 0.86),
                                .init(color: Color(.paperBackground).opacity(0), location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                }
            }
        }
    }
}

/// 导航栏中部的月份入口，点击后打开月份选择。
private struct HomeMonthSelectorButton: View {
    @Environment(\.locale) private var locale

    /// 当前语言环境下的月份标题。
    let formattedMonth: String

    /// 用户点击月份入口后的回调。
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(formattedMonth)
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            Text(
                AccountLocalization.formatted(
                    "home.month.selector.accessibility",
                    value: formattedMonth,
                    locale: locale
                )
            )
        )
        .accessibilityIdentifier("home-month-selector")
    }
}

/// 首页固定头部：单行展示月度支出、收入和金额显隐控制，尽量把空间留给明细。
private struct HomeOverviewHeader: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 当前月份的已本地化展示数据。
    let monthPresentation: HomeOverviewMonthPresentation

    /// 是否展示收入和支出的实际金额。
    @Binding var areAmountsVisible: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            let summaryLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
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

            visibilityButton
        }
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .padding(.vertical, 14)
        // 汇总不垫灰色卡片，用一笔画成的墨线框圈出来；框内铺纸色，流水从下方滑过时不会透上来。
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(.paperBackground))
            HandDrawnBox(cornerRadius: 22, seed: 7)
                .stroke(
                    Color.primary.opacity(0.85),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                )
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-fixed-header")
    }

    /// 金额显隐开关；只保留图标本身，点击区域保持 44pt。
    private var visibilityButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                areAmountsVisible.toggle()
            }
        } label: {
            Image(systemName: areAmountsVisible ? "eye" : "eye.slash")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: isIncome ? "arrow.down.left" : "arrow.up.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(isVisible ? formattedAmount : AccountLocalization.string("home.summary.mask", locale: locale))
                // 金额用衬线数字，像账本上写下的数目。
                .font(.system(.title, design: .serif, weight: .medium).monospacedDigit())
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

/// 首页主要操作，悬浮在明细上方；新系统是透明玻璃加墨色文字，iOS 18 用材质底加投影表达悬浮层级。
private struct HomeAddTransactionButton: View {
    @Environment(\.locale) private var locale

    var body: some View {
        if #available(iOS 26, *) {
            entryLink.buttonStyle(.glass)
        } else {
            entryLink
                .buttonStyle(.bordered)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
        }
    }

    /// 沿用原有记账路由和本地化标题，整颗胶囊均为点击区域。
    private var entryLink: some View {
        NavigationLink(value: HomeRoute.expenseEntry) {
            Label(AccountLocalization.string("expense.entry.action", locale: locale), systemImage: "plus")
                .font(.headline)
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .foregroundStyle(.primary)
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

    /// 需要短暂标红提示的新流水；为空时所有行保持默认样式。
    let highlightedTransactionID: UUID?

    /// 悬浮记账按钮占用的底部高度，用于列表末尾留白和上拉提示避让。
    let bottomClearance: CGFloat

    /// 月份切换回调。
    let onSelectMonth: (HomeMonth) -> Void

    var body: some View {
        GeometryReader { containerGeometry in
            ScrollViewReader { scrollProxy in
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
                                    HomeOverviewRow(row: row, isHighlighted: row.id == highlightedTransactionID)
                                        .listRowInsets(EdgeInsets(top: 9, leading: 2, bottom: 9, trailing: 2))
                                        // 流水直接写在纸上：不垫卡片，行与行之间是一条手画的账本横线。
                                        .listRowBackground(
                                            HomeLedgerRule(
                                                seed: row.id.handDrawnSeed,
                                                isHidden: row.id == day.rows.last?.id
                                            )
                                        )
                                        .listRowSeparator(.hidden)
                                }
                            } header: {
                                HomeOverviewDayHeader(day: day)
                                    .listRowInsets(EdgeInsets(top: 0, leading: 2, bottom: 2, trailing: 2))
                            }
                        }
                    }

                    // 末尾留白计入内容高度，最后一条流水可以完整滚到悬浮按钮上方。
                    Color.clear
                        .frame(height: bottomClearance)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.insetGrouped)
                .listSectionSpacing(22)
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
                // 新流水所在行进入当前月份数据后滚到可见位置；查询刷新可能晚于返回首页，因此同时观察行是否已出现。
                .onChange(of: highlightScrollTarget, initial: true) { _, target in
                    guard let target else { return }
                    // 等列表完成本轮布局后再滚动，不带动画以免与返回转场叠加。
                    Task { @MainActor in
                        scrollProxy.scrollTo(target, anchor: .center)
                    }
                }
                // 每个月从顶部开始，避免原生回弹与 scrollTo 动画争夺偏移。
                .id(selectedMonth)
                .transition(.opacity)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: selectedMonth)
            }
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
                .padding(.bottom, pull.direction == .earlier ? bottomClearance : 0)
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

    /// 需要标红的新流水已出现在当前月份明细中时返回其标识，否则为 `nil`。
    private var highlightScrollTarget: UUID? {
        guard let highlightedTransactionID,
              monthPresentation.dayGroups.contains(where: { day in
                  day.rows.contains { $0.id == highlightedTransactionID }
              })
        else { return nil }
        return highlightedTransactionID
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

/// 流水行底部的账本横线，作为行背景使用；每条线的起伏由流水标识决定。
private struct HomeLedgerRule: View {
    /// 笔迹种子。
    let seed: UInt64

    /// 当天最后一条流水下方不画线，留给下一天的日期标题。
    let isHidden: Bool

    var body: some View {
        HandDrawnRule(seed: seed)
            .stroke(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            .frame(height: 3)
            .frame(maxHeight: .infinity, alignment: .bottom)
            // 与日期标题下的墨线左右对齐。
            .padding(.horizontal, 2)
            .opacity(isHidden ? 0 : 1)
    }
}

/// 首页原生列表中的日期分组标题。
private struct HomeOverviewDayHeader: View {
    @Environment(\.locale) private var locale

    /// 当前日期组数据。
    let day: HomeOverviewDayPresentation

    var body: some View {
        VStack(spacing: 7) {
            // 优先单行展示以节省高度；较长语言或大字号放不下时改为两行。
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    dateLabel
                    Spacer(minLength: 0)
                    summaryLabel.lineLimit(1)
                }
                VStack(alignment: .leading, spacing: 4) {
                    dateLabel
                    summaryLabel
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 每一天像账本上新起的一栏，日期下面压一条较重的墨线。
            HandDrawnRule(seed: UInt64(truncatingIfNeeded: day.transactionDay))
                .stroke(Color.primary.opacity(0.6), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                .frame(height: 3)
                .accessibilityHidden(true)
        }
        .foregroundStyle(.secondary)
        .padding(.top, 2)
        .textCase(nil)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home-day-\(day.transactionDay)")
    }

    /// 日期与星期并排，日期使用主文字色以便快速定位。
    private var dateLabel: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(day.formattedDate)
                .font(.system(.callout, design: .serif, weight: .medium))
                .foregroundStyle(.primary)
            Text(day.formattedWeekday)
                .font(.caption)
        }
    }

    /// 当日收支摘要，数字等宽以便上下对齐。
    private var summaryLabel: some View {
        Text(daySummary)
            .font(.caption.monospacedDigit())
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 已完成本地化的首页行数据。
    let row: HomeOverviewRowPresentation

    /// 是否为刚保存的新流水；为真时先以账本红呈现，再缓缓回到默认色。
    let isHighlighted: Bool

    /// 图标位置手绘对勾的书写进度。
    @State private var tickProgress: CGFloat = 0

    /// 本次提示是否已经褪回默认色。
    @State private var hasSettled = false

    /// 当前是否处于"刚记下"的标红状态。
    private var isMarked: Bool {
        isHighlighted && !hasSettled
    }

    var body: some View {
        NavigationLink(value: HomeRoute.transactionDetail(row.id)) {
            HStack(spacing: 14) {
                ZStack {
                    Image(systemName: row.symbolName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .opacity(isMarked ? 0 : 1)
                    // 标红期间图标位置写出一笔对勾，褪色时再交还给分类图标。
                    HandDrawnTick(progress: tickProgress)
                        .frame(width: 24)
                        .opacity(isMarked ? 1 : 0)
                }
                .frame(width: 38, height: 38)
                // 图标垫在随手涂出的色块上，每条流水的色块形状各不相同。
                .background(
                    isMarked ? Color(.ledgerRed).opacity(0.12) : Color.accentColor.opacity(0.08),
                    in: HandDrawnBlob(seed: row.id.handDrawnSeed)
                )
                .accessibilityHidden(true)

                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                    : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
                layout {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(isMarked ? Color(.ledgerRed) : Color.primary)
                        if let note = row.note {
                            Text(note)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(row.formattedAmount)
                        .font(.system(.body, design: .serif).monospacedDigit())
                        .foregroundStyle(isMarked ? Color(.ledgerRed) : Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .layoutPriority(1)
                }
            }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        // 整行都可点，纸面上不再逐行重复系统的右箭头。
        .navigationLinkIndicatorVisibility(.hidden)
        .task(id: isHighlighted) {
            await playHighlight()
        }
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

extension HomeOverviewRow {
    /// 新流水提示的节奏：等返回转场结束后写出对勾，停留片刻，再让红色缓缓褪回默认色。
    private func playHighlight() async {
        guard isHighlighted else {
            // 提示结束后复位，下一次标红可以从头播放。
            hasSettled = false
            tickProgress = 0
            return
        }

        do {
            try await Task.sleep(for: .milliseconds(450))
            if reduceMotion {
                tickProgress = 1
            } else {
                withAnimation(.easeInOut(duration: 0.4)) {
                    tickProgress = 1
                }
            }
            try await Task.sleep(for: .milliseconds(1100))
            // 颜色渐变不涉及位移，减少动态效果时同样保留，只是更短。
            withAnimation(.easeInOut(duration: reduceMotion ? 0.6 : 1.2)) {
                hasSettled = true
            }
        } catch {
            // 行被回收或提示被取消时直接结束，状态随视图一起丢弃。
        }
    }
}

/// 首页没有真实收入或支出流水时的本地化空状态。
private struct HomeEmptyState: View {
    @Environment(\.locale) private var locale

    var body: some View {
        ContentUnavailableView {
            // 沿用系统空状态的排版，只把图标换成手绘小票。
            Label {
                Text(AccountLocalization.string("home.details.empty.title", locale: locale))
            } icon: {
                HandDrawnSlipIllustration()
            }
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
