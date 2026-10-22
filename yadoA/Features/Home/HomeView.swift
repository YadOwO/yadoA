import SwiftData
import SwiftUI

/// 首页入口，展示导航栏月份入口、紧凑汇总和当前月份的只读明细。
struct HomeView: View {
    @Environment(\.locale) private var locale

    /// 用户最近一次选择的收支汇总显隐状态。
    @AppStorage("home.summary.amountsVisible") private var areAmountsVisible = false

    var body: some View {
        HomeQueryContent(areAmountsVisible: $areAmountsVisible)
            .navigationTitle(AppTab.home.title(locale: locale))
            // 标题仅供返回按钮和辅助功能使用，导航栏中部由月份入口占据。
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: HomeRoute.search) {
                        Label(
                            AccountLocalization.string("bookkeeping.search.title", locale: locale),
                            systemImage: "magnifyingglass"
                        )
                    }
                    .accessibilityIdentifier("home-search")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: HomeRoute.bills) {
                        Label(AccountLocalization.string("bill.title", locale: locale), systemImage: "doc.text")
                    }
                    .accessibilityIdentifier("home-bills")
                }
                // 悬浮按钮留给语音记账，手动记一笔放在导航栏最右侧
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: HomeRoute.expenseEntry) {
                        Label(AccountLocalization.string("expense.entry.action", locale: locale), systemImage: "plus")
                    }
                    .accessibilityIdentifier("home-add-expense")
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding private var areAmountsVisible: Bool
    @Query private var transactions: [AccountTransaction]
    @Query private var categories: [BookkeepingCategory]

    /// 当前已提交的月份；首次出现时由投影根据数据初始化。
    @State private var selectedMonth: HomeMonth?

    /// 是否展示月份选择 Sheet。
    @State private var isMonthPickerPresented = false

    /// 悬浮麦克风按钮占用的底部高度，列表末尾据此留白，保证最后一条流水能滚到按钮上方；麦克风在 Tab Bar 附属栏里时为 0。
    @State private var addButtonClearance: CGFloat = 76

    /// 首页当前是否在导航栈顶部可见；被记账页盖住时不消费新流水提示。
    @State private var isVisible = false

    /// 正在播放变更提示的行，每条提示结束后各自移除；语音记账一次可能有多条。
    @State private var rowMarks: [HomeRowMark] = []

    /// 刚删除、仍在原位置画出残影的流水内容，残影收起后各自移除。
    @State private var deletedRows: [HomeOverviewDeletedRow] = []

    /// 最近一批变更要定位到的流水；每批新建一次，同一笔流水再次变更也会重新定位，到期后清除。
    @State private var scrollRequest: HomeScrollRequest?

    /// 刚新增、修改或删除成功的流水提示通道。
    private let recentEntryHighlight = HomeRecentEntryHighlight.shared

    init(areAmountsVisible: Binding<Bool>) {
        _areAmountsVisible = areAmountsVisible
        _transactions = Query(HomeOverviewPresentation.descriptor())
        _categories = Query()
    }

    var body: some View {
        let presentation = HomeOverviewPresentation(
            transactions: transactions,
            calendar: environmentCalendar,
            locale: locale,
            catalog: BookkeepingCategoryCatalog(categories: categories)
        )
        let activeMonth = selectedMonth ?? presentation.initialMonth
        let monthPresentation = presentation.presentation(for: activeMonth, retaining: deletedRows)

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
                    rowMarks: rowMarks,
                    scrollRequest: scrollRequest,
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
        // 会话卡片浮在明细之上。iPhone 的 iOS 26.1 起麦克风在 Tab Bar 附属栏里，卡片出现在附属栏上方；
        // 其他情况麦克风悬浮在这里且不带整条底栏，居中放置以避开右侧的金额列，卡片出现在它上方。
        .overlay(alignment: .bottom) {
            VoiceBookkeepingDock(
                onLocateChange: locate,
                onButtonHeightChange: { height in
                    addButtonClearance = height
                }
            )
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
            // 从别的页面返回，带动画滚动会和返回转场叠加
            showRecentEntryHighlightIfNeeded(animated: false)
        }
        .onDisappear {
            isVisible = false
        }
        // 截图记账以全屏模态盖在首页之上，关闭时不会再次触发 onAppear，需要直接响应登记。
        // 语音记账在首页上直接改数据，也走这里，此时用户正看着列表，滚动带动画。
        .onChange(of: recentEntryHighlight.pending) { _, _ in
            showRecentEntryHighlightIfNeeded(animated: true)
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
    /// 新增或修改提示从出现到完全回到默认样式所需的总时长，之后清除标记。
    private static let highlightLifetime: Duration = .milliseconds(4500)

    /// 删除残影从出现、划掉到停留结束的时长，之后把这一行从列表中收起。
    private static let deletedRowLifetime: Duration = .milliseconds(1600)

    /// 首页可见时取走刚变更的流水并展示提示。
    ///
    /// - Parameter animated: 是否带动画滚动；切换了月份时列表是新建的，总是直接定位。
    private func showRecentEntryHighlightIfNeeded(animated: Bool) {
        guard isVisible else { return }
        present(recentEntryHighlight.consume(), animated: animated)
    }

    /// 在明细里定位语音卡片上点选的一笔流水：切到它现在所在的月份、滚到汇总下方，并重新播放一次提示。
    ///
    /// 按流水当前的记账日定位，之后的轮次改过日期也能找到；流水已被删除时不做任何事。
    /// - Parameter change: 卡片上点选的流水变更，删除和已撤销的变更不会走到这里。
    private func locate(_ change: VoiceEntryChange) {
        guard let transaction = transactions.first(where: { $0.id == change.transactionID }) else { return }
        // 修改不再对比旧值：之后的轮次可能又改过，只在标题和金额下补笔迹提示"就是这笔"
        let entry = HomeRecentEntryHighlight.Entry(
            id: transaction.id,
            transactionDay: transaction.transactionDay,
            change: change.kind == .updated ? .updated(previous: nil) : .added,
            savedAt: .now
        )
        present([entry], animated: true)
    }

    /// 播放一批流水变更的提示：新增标红写对勾、修改划掉旧值换上新值、删除划掉后收起；
    /// 并切到变更最多的月份，把其中排得最靠上的一笔滚到汇总下方，其余几笔出现在它下方。
    ///
    /// - Parameters:
    ///   - entries: 要展示的流水变更。
    ///   - animated: 是否带动画滚动；切换了月份时列表是新建的，总是直接定位。
    private func present(_ entries: [HomeRecentEntryHighlight.Entry], animated: Bool) {
        for entry in entries {
            show(entry)
        }
        guard let focus = HomeEntryFocus(
            entries: entries,
            currentMonth: selectedMonth,
            today: HomeMonth.from(date: .now, calendar: environmentCalendar, locale: locale)
        ) else { return }

        let switchesMonth = focus.month != selectedMonth
        selectedMonth = focus.month
        let request = HomeScrollRequest(
            transactionIDs: focus.transactionIDs,
            isAnimated: animated && !switchesMonth && !reduceMotion
        )
        scrollRequest = request
        Task {
            try? await Task.sleep(for: Self.highlightLifetime)
            // 到期后不再定位，之后切月份、列表重建时不会又跳回这一笔
            if scrollRequest == request {
                scrollRequest = nil
            }
        }
    }

    /// 为一条流水变更播放提示，到期后只移除这一条，不影响同时播放的其他提示。
    private func show(_ entry: HomeRecentEntryHighlight.Entry) {
        // 同一笔流水的旧提示让位给新提示
        rowMarks.removeAll { $0.transactionID == entry.id }
        switch entry.change {
        case .added, .updated:
            let kind: HomeRowMark.Kind
            if case let .updated(previous) = entry.change {
                kind = .updated(previous: previous)
            } else {
                kind = .added
            }
            let mark = HomeRowMark(transactionID: entry.id, kind: kind)
            rowMarks.append(mark)
            Task {
                try? await Task.sleep(for: Self.highlightLifetime)
                rowMarks.removeAll { $0 == mark }
            }
        case let .deleted(row):
            let mark = HomeRowMark(transactionID: entry.id, kind: .deleted)
            rowMarks.append(mark)
            deletedRows.removeAll { $0.row.id == row.row.id }
            deletedRows.append(row)
            Task {
                try? await Task.sleep(for: Self.deletedRowLifetime)
                guard deletedRows.contains(row) else { return }
                // 收起使用列表原生的删除动画；减少动态效果时直接移除。
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                    deletedRows.removeAll { $0 == row }
                    rowMarks.removeAll { $0 == mark }
                }
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

    /// 用户选择的启动页面；记账页是启动页时汇总框才带装饰。
    @AppStorage(AppStartPage.storageKey) private var startPage: AppStartPage = .home

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
        .startPageDecoration(isEnabled: startPage == .home, cornerRadius: 22, seed: 7)
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

    /// 正在播放变更提示的行；为空时所有行保持默认样式。
    let rowMarks: [HomeRowMark]

    /// 需要定位的变更流水；所在行出现在当前月份明细里时滚到汇总下方。
    let scrollRequest: HomeScrollRequest?

    /// 悬浮记账按钮占用的底部高度，用于列表末尾留白和上拉提示避让。
    let bottomClearance: CGFloat

    /// 月份切换回调。
    let onSelectMonth: (HomeMonth) -> Void

    var body: some View {
        GeometryReader { containerGeometry in
            ScrollViewReader { scrollProxy in
                Group {
                    if monthPresentation.isEmpty {
                        // 空状态不走 List：分组列表自带的边距和末尾留白会让内容高出可视区，产生多余的滚动。
                        // 内容刚好不超过可视高度，只保留边界回弹用于切换月份。
                        ScrollView {
                            HomeEmptyState(isLedgerEmpty: monthNavigator.availableMonths.isEmpty)
                                .frame(
                                    maxWidth: .infinity,
                                    minHeight: max(0, containerGeometry.size.height - 2)
                                )
                        }
                    } else {
                        List {
                            ForEach(monthPresentation.dayGroups) { day in
                                Section {
                                    ForEach(day.rows) { row in
                                        let rowMark = rowMarks.last { $0.transactionID == row.id }
                                        HomeOverviewRow(row: row, mark: rowMark?.kind, markToken: rowMark?.token)
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

                            // 末尾留白计入内容高度，最后一条流水可以完整滚到悬浮按钮上方。
                            Color.clear
                                .frame(height: bottomClearance)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .listSectionSpacing(22)
                .contentMargins(.top, 0, for: .scrollContent)
                .scrollContentBackground(.hidden)
                .scrollBounceBehavior(allowsBoundaryBounce ? .always : .basedOnSize)
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
                // 变更流水所在行进入当前月份数据后，把它滚到列表可视区顶部，也就是汇总卡片正下方，
                // 下方的语音卡片不会挡住它；查询刷新可能晚于登记提示，因此同时观察行是否已出现。
                .onChange(of: scrollTarget, initial: true) { previous, target in
                    guard let target else { return }
                    // 同一请求已经滚过、上次的目标行又不在明细里了，说明是删除残影收起，不跟着往下滚；
                    // 上次的目标行还在时目标变了，说明更靠上的一笔刚出现，需要重新定位。
                    if let previous, previous.request == target.request, !isListed(previous.transactionID) {
                        return
                    }
                    // 等列表完成本轮布局后再滚动
                    Task { @MainActor in
                        withAnimation(target.request.isAnimated ? .easeInOut(duration: 0.35) : nil) {
                            scrollProxy.scrollTo(target.transactionID, anchor: .top)
                        }
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
                HomeMonthPullHint(
                    text: AccountLocalization.formatted(
                        pull.isReady ? "home.month.pull.release" : "home.month.pull.continue",
                        value: month.formatted(locale: locale, calendar: calendar),
                        locale: locale
                    ),
                    direction: pull.direction,
                    isReady: pull.isReady
                )
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

    /// 定位请求在当前月份明细（含删除残影）里落到的行：候选流水中排得最靠上、已经出现的一笔；都还没出现时为 `nil`。
    private var scrollTarget: HomeScrollTarget? {
        guard let scrollRequest else { return nil }
        for day in monthPresentation.dayGroups {
            if let row = day.rows.first(where: { scrollRequest.transactionIDs.contains($0.id) }) {
                return HomeScrollTarget(request: scrollRequest, transactionID: row.id)
            }
        }
        return nil
    }

    /// 流水是否出现在当前月份明细里（含删除残影）。
    private func isListed(_ transactionID: UUID) -> Bool {
        monthPresentation.dayGroups.contains { day in
            day.rows.contains { $0.id == transactionID }
        }
    }

    /// 是否保留边界回弹：有流水的月份始终回弹；空月份只有存在可切换的相邻月份时才回弹，否则完全静止。
    private var allowsBoundaryBounce: Bool {
        guard monthPresentation.isEmpty else { return true }
        return targetMonth(for: .earlier) != nil || targetMonth(for: .later) != nil
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

/// 边界拉动时的换月提示：像写在纸边的一行批注，不垫系统材质胶囊。
///
/// 未到阈值时是淡色小字；拉过阈值后字迹变实、箭头掉头，并在字下划出一条墨线，表示松手即可翻页。
/// 顶部下拉与底部上拉共用这一个样式，只有箭头方向不同。
private struct HomeMonthPullHint: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 已本地化的提示文案，包含目标月份。
    let text: String

    /// 拉动方向，决定箭头朝向。
    let direction: HomeMonthScrollInteraction.Direction

    /// 是否已拉过阈值，松手即切换月份。
    let isReady: Bool

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: direction == .later ? "arrow.down" : "arrow.up")
                    .font(.caption.weight(.medium))
                    .rotationEffect(.degrees(isReady ? 180 : 0))
                    .accessibilityHidden(true)
                Text(text)
                    .font(.system(.footnote, design: .serif))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isReady ? Color.primary : Color.secondary)

            // 墨线从左向右划出，与日期标题下的重线同一种笔迹。
            HandDrawnRule(seed: direction == .later ? 31 : 37)
                .trim(from: 0, to: isReady ? 1 : 0)
                .stroke(Color.primary.opacity(0.6), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                .frame(height: 3)
                .accessibilityHidden(true)
        }
        .fixedSize()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // 垫一块与页面同色的纸，提示压到流水上时仍然清楚，落在空白处则看不出底。
        .background(Color(.paperBackground).opacity(0.92), in: Capsule())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isReady)
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

/// 首页某一行正在播放的变更提示。
private struct HomeRowMark: Equatable {
    /// 三种变更各用一种可区分的纸面动作。
    enum Kind: Equatable {
        /// 新记一笔：账本红 + 图标位置写出对勾。
        case added

        /// 修改：像账本更正一样，把改动的旧值划掉，再换上新值并在下面补一道笔迹。
        ///
        /// 没有修改前快照时只在标题和金额下补笔迹。
        case updated(previous: HomeOverviewRowPresentation?)

        /// 删除：红色墨线划掉整行并变淡，随后收起。
        case deleted
    }

    /// 播放提示的流水标识。
    let transactionID: UUID

    /// 提示类型。
    let kind: Kind

    /// 每次提示的唯一标识；同一笔流水连续两次相同提示时，旧提示到期不会误删新提示。
    let token = UUID()
}

/// 一次把变更流水滚到汇总下方的请求。
private struct HomeScrollRequest: Equatable {
    /// 候选流水；滚到其中在明细里排得最靠上的一笔，其余几笔出现在它下方。
    let transactionIDs: Set<UUID>

    /// 是否带动画滚动。
    let isAnimated: Bool

    /// 每次请求的唯一标识；同一笔流水再次变更时也算新的请求。
    let token = UUID()
}

/// 定位请求在当前明细里实际要滚到的行。
private struct HomeScrollTarget: Equatable {
    /// 所属的定位请求。
    let request: HomeScrollRequest

    /// 候选流水中当前排得最靠上的一笔。
    let transactionID: UUID
}

/// 修改提示的播放阶段。
private enum HomeRowRevisionStep {
    /// 展示修改前的值，旧值上的划线逐渐画出。
    case previous

    /// 已换成新值，改动处下方有一道笔迹。
    case revised

    /// 笔迹褪去，回到普通样式。
    case settled
}

/// 首页单条只读流水行。
private struct HomeOverviewRow: View {
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 已完成本地化的首页行数据。
    let row: HomeOverviewRowPresentation

    /// 当前行正在播放的变更提示；为空时保持默认样式。
    let mark: HomeRowMark.Kind?

    /// 当前提示的唯一标识；从语音卡片再次定位同一笔时提示类型可能不变，靠它从头重播。
    let markToken: UUID?

    /// 新增提示中图标位置手绘对勾的书写进度。
    @State private var tickProgress: CGFloat = 0

    /// 删除或修改提示中旧值划线的书写进度。
    @State private var strikeProgress: CGFloat = 0

    /// 修改提示中新值下方笔迹的书写进度。
    @State private var underlineProgress: CGFloat = 0

    /// 修改提示当前所处的阶段；行首次出现时就处于"旧值"阶段，避免先闪一下新值。
    @State private var revisionStep = HomeRowRevisionStep.previous

    /// 本次新增提示是否已经褪回默认色。
    @State private var hasSettled = false

    /// 当前是否处于"刚记下"的标红状态。
    private var isAddedMarked: Bool {
        mark == .added && !hasSettled
    }

    /// 是否为刚删除流水的残影；为真时整行不再可点。
    private var isDeleted: Bool {
        mark == .deleted
    }

    /// 修改提示的字段差异；不是修改提示时为 `nil`。
    private var revision: HomeOverviewRowRevision? {
        guard case let .updated(previous) = mark else { return nil }
        return HomeOverviewRowRevision(previous: previous ?? row, current: row)
    }

    /// 修改提示是否仍在展示旧值。
    private var showsPrevious: Bool {
        revision != nil && revisionStep == .previous
    }

    /// 当前要展示的行内容：修改提示的旧值阶段展示修改前快照，其余时候展示最新数据。
    private var displayed: HomeOverviewRowPresentation {
        showsPrevious ? revision?.previous ?? row : row
    }

    var body: some View {
        NavigationLink(value: HomeRoute.transactionDetail(row.id)) {
            HStack(spacing: 14) {
                ZStack {
                    // 修改了分类时，旧图标以系统替换动画换成新图标。
                    Image(systemName: displayed.symbolName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .contentTransition(.symbolEffect(.replace))
                        .opacity(isAddedMarked ? 0 : 1)
                    // 标红期间图标位置写出一笔对勾，褪色时再交还给分类图标。
                    HandDrawnTick(progress: tickProgress)
                        .frame(width: 24)
                        .opacity(isAddedMarked ? 1 : 0)
                }
                .frame(width: 38, height: 38)
                // 图标垫在随手涂出的色块上，每条流水的色块形状各不相同。
                .background(
                    isAddedMarked ? Color(.ledgerRed).opacity(0.12) : Color.accentColor.opacity(0.08),
                    in: HandDrawnBlob(seed: row.id.handDrawnSeed)
                )
                .opacity(deletedOpacity)
                .accessibilityHidden(true)

                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                    : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
                layout {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(displayed.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(isAddedMarked ? Color(.ledgerRed) : Color.primary)
                            .contentTransition(.interpolate)
                            .modifier(revisionMarks(isChanged: revision?.isTitleChanged, marksWithoutVisibleChanges: true, seed: 1))
                        if let note = displayed.note {
                            Text(note)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .contentTransition(.interpolate)
                                .modifier(revisionMarks(isChanged: revision?.isNoteChanged, marksWithoutVisibleChanges: false, seed: 2))
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // 金额修改时数字逐位滚动到新值。
                    Text(displayed.formattedAmount)
                        .font(.system(.body, design: .serif).monospacedDigit())
                        .foregroundStyle(isAddedMarked ? Color(.ledgerRed) : Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .contentTransition(.numericText())
                        .modifier(revisionMarks(isChanged: revision?.isAmountChanged, marksWithoutVisibleChanges: true, seed: 3))
                        .layoutPriority(1)
                }
                .opacity(deletedOpacity)
                // 像在账本上把这一笔划掉：一条红色墨线从左到右穿过标题和金额。
                .overlay {
                    if isDeleted {
                        HandDrawnRule(seed: row.id.handDrawnSeed)
                            .trim(from: 0, to: strikeProgress)
                            .stroke(Color(.ledgerRed), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                            .frame(height: 3)
                            .accessibilityHidden(true)
                    }
                }
            }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        // 整行都可点，纸面上不再逐行重复系统的右箭头。
        .navigationLinkIndicatorVisibility(.hidden)
        // 残影对应的流水已不存在，不能再进入详情。
        .disabled(isDeleted)
        .task(id: markToken) {
            await playMark()
        }
        .accessibilityLabel(
            isDeleted
                ? AccountLocalization.formatted("home.transaction.deleted", value: row.accessibilityLabel, locale: locale)
                : row.accessibilityLabel
        )
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
    /// 删除残影随划线逐渐变淡，划完后保留约一半的不透明度。
    private var deletedOpacity: Double {
        isDeleted ? 1 - 0.55 * strikeProgress : 1
    }

    /// 为单个字段生成修改提示的笔迹。
    ///
    /// - Parameters:
    ///   - isChanged: 该字段是否改过；不是修改提示时为 `nil`。
    ///   - marksWithoutVisibleChanges: 行上看不出任何变化（例如只改了账户）时是否仍在该字段下补笔迹，告诉用户这一笔改过了。
    ///   - seed: 区分各字段笔迹形状的种子。
    /// - Returns: 旧值阶段划掉改过的字段，新值阶段在其下方补一道笔迹；不需要笔迹时为空。
    private func revisionMarks(
        isChanged: Bool?,
        marksWithoutVisibleChanges: Bool,
        seed: UInt64
    ) -> HomeRowRevisionMarks {
        let isStruck = isChanged == true
        let isUnderlined = isStruck || (marksWithoutVisibleChanges && revision?.hasVisibleChanges == false)
        return HomeRowRevisionMarks(
            seed: row.id.handDrawnSeed &+ seed,
            strikeProgress: isStruck ? strikeProgress : 0,
            isStrikeVisible: isStruck && showsPrevious,
            underlineProgress: isUnderlined ? underlineProgress : 0,
            isUnderlineVisible: isUnderlined && revisionStep == .revised
        )
    }

    /// 按提示类型播放；提示结束时复位，下一次可以从头播放。
    private func playMark() async {
        guard let mark else {
            hasSettled = false
            tickProgress = 0
            strikeProgress = 0
            underlineProgress = 0
            revisionStep = .previous
            return
        }
        // 上一次提示可能还没播完就被新提示替换，先回到起点再播
        hasSettled = false
        tickProgress = 0
        strikeProgress = 0
        underlineProgress = 0
        revisionStep = .previous

        do {
            // 等返回转场结束后再落笔。
            try await Task.sleep(for: .milliseconds(450))
            switch mark {
            case .added:
                draw(duration: 0.4) { tickProgress = 1 }
                try await Task.sleep(for: .milliseconds(1100))
                // 颜色渐变不涉及位移，减少动态效果时同样保留，只是更短。
                withAnimation(.easeInOut(duration: reduceMotion ? 0.6 : 1.2)) {
                    hasSettled = true
                }
            case .updated:
                try await playRevision()
            case .deleted:
                // 删除只负责划掉，收起由首页在停留片刻后统一处理。
                draw(duration: 0.45) { strikeProgress = 1 }
            }
        } catch {
            // 行被回收或提示被取消时直接结束，状态随视图一起丢弃。
        }
    }

    /// 修改提示的节奏：划掉旧值 → 换成新值（图标替换、数字滚动、文字渐变）→ 新值下补一道笔迹 → 笔迹褪去。
    private func playRevision() async throws {
        if revision?.hasVisibleChanges == true {
            draw(duration: 0.35) { strikeProgress = 1 }
            try await Task.sleep(for: .milliseconds(500))
        }
        // 文字和数字的内容过渡不涉及大幅位移，减少动态效果时同样保留，只是更短。
        withAnimation(.smooth(duration: reduceMotion ? 0.2 : 0.5)) {
            revisionStep = .revised
        }
        try await Task.sleep(for: .milliseconds(300))
        draw(duration: 0.4) { underlineProgress = 1 }
        try await Task.sleep(for: .milliseconds(1500))
        withAnimation(.easeInOut(duration: reduceMotion ? 0.4 : 0.8)) {
            revisionStep = .settled
        }
    }

    /// 以书写动画推进一笔笔迹；减少动态效果时直接画完。
    ///
    /// - Parameters:
    ///   - duration: 书写时长。
    ///   - update: 把对应进度设为完成的状态修改。
    private func draw(duration: Double, _ update: () -> Void) {
        if reduceMotion {
            update()
        } else {
            withAnimation(.easeInOut(duration: duration), update)
        }
    }
}

/// 修改提示落在单个字段上的笔迹：旧值上一道细划线，新值下一道细下划线。
///
/// 两道线都只用墨色细线，和账本上手写更正的样子一致；收起时整道线淡出，而不是倒着擦掉。
private struct HomeRowRevisionMarks: ViewModifier {
    /// 笔迹种子。
    let seed: UInt64

    /// 旧值划线的书写进度。
    let strikeProgress: CGFloat

    /// 旧值划线是否可见；换成新值时随旧值一起淡出。
    let isStrikeVisible: Bool

    /// 新值下划线的书写进度。
    let underlineProgress: CGFloat

    /// 新值下划线是否可见；提示收尾时淡出。
    let isUnderlineVisible: Bool

    func body(content: Content) -> some View {
        content
            .overlay {
                HandDrawnRule(seed: seed)
                    .trim(from: 0, to: strikeProgress)
                    .stroke(Color.primary.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                    .frame(height: 3)
                    .opacity(isStrikeVisible ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .bottom) {
                HandDrawnRule(seed: seed &+ 7)
                    .trim(from: 0, to: underlineProgress)
                    .stroke(Color.primary.opacity(0.45), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                    .frame(height: 3)
                    .offset(y: 4)
                    .opacity(isUnderlineVisible ? 1 : 0)
                    .accessibilityHidden(true)
            }
    }
}

/// 首页没有真实收入或支出流水时的本地化空状态。
private struct HomeEmptyState: View {
    @Environment(\.locale) private var locale

    /// 整个账本是否还没有任何收支；为真时文案指向下方的记账按钮，否则只说明当前月份为空。
    let isLedgerEmpty: Bool

    var body: some View {
        ContentUnavailableView {
            // 沿用系统空状态的排版，只把图标换成手绘小票。
            Label {
                Text(AccountLocalization.string("home.details.empty.title", locale: locale))
            } icon: {
                HandDrawnSlipIllustration()
            }
        } description: {
            Text(AccountLocalization.string(
                isLedgerEmpty ? "home.details.empty.first.message" : "home.details.empty.message",
                locale: locale
            ))
        }
        .accessibilityIdentifier("home-details-empty")
    }
}

#Preview("Home empty") {
    NavigationStack {
        HomeView()
    }
    .environment(AuthStore())
    .environment(VoiceBookkeepingState())
    .modelContainer(
        for: [Account.self, AccountTransaction.self, BookkeepingPreference.self],
        inMemory: true
    )
}
