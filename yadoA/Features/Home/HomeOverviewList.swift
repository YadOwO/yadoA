import SwiftData
import SwiftUI

/// 当前月份的独立明细滚动区域。
struct HomeOverviewList: View {
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

    /// 流水行的左滑和长按操作。
    let rowActions: HomeRowActions

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
                                        HomeOverviewRow(
                                            row: row,
                                            mark: rowMark?.kind,
                                            markToken: rowMark?.token,
                                            actions: rowActions
                                        )
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
        .appHaptic(.selection, trigger: isReadyToSwitch) { _, isReady in isReady }
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
        let income = day.incomeTotal.formattedCurrency(locale: locale)
        let expense = day.expenseTotal.formattedCurrency(locale: locale)
        return String(
            format: AccountLocalization.string("home.day.summary", locale: locale),
            locale: locale,
            income,
            expense
        )
    }
}

/// 一次把变更流水滚到汇总下方的请求。
struct HomeScrollRequest: Equatable {
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

/// 首页流水行的快捷操作。
struct HomeRowActions {
    /// 可以删除的流水；已停用账户下的流水只能查看，但仍可以作为模板再记一笔。
    let editableTransactionIDs: Set<UUID>

    /// 以这笔流水为模板再记一笔。
    let onRepeat: (UUID) -> Void

    /// 请求删除这笔流水，确认由首页负责。
    let onDelete: (HomeOverviewRowPresentation) -> Void
}

/// 首页单条流水行：整行点开进入详情，左滑删除，长按可再记一笔；纸面样式与变更提示由 `HomeOverviewRowContent` 负责。
private struct HomeOverviewRow: View {
    @Environment(\.locale) private var locale

    /// 已完成本地化的首页行数据。
    let row: HomeOverviewRowPresentation

    /// 当前行正在播放的变更提示；为空时保持默认样式。
    let mark: HomeRowMark.Kind?

    /// 当前提示的唯一标识，交给纸面内容从头重播提示。
    let markToken: UUID?

    /// 左滑和长按操作。
    let actions: HomeRowActions

    /// 这一行是否还对应真实流水；删除残影不再提供任何操作。
    private var isExisting: Bool {
        mark != .deleted
    }

    /// 这一行是否可以删除。
    private var isDeletable: Bool {
        isExisting && actions.editableTransactionIDs.contains(row.id)
    }

    /// 删除操作的标题。
    private var deleteTitle: String {
        AccountLocalization.string("bookkeeping.delete.action", locale: locale)
    }

    var body: some View {
        NavigationLink(value: HomeRoute.transactionDetail(row.id)) {
            HomeOverviewRowContent(row: row, mark: mark, markToken: markToken)
        }
        .buttonStyle(.plain)
        // 整行都可点，纸面上不再逐行重复系统的右箭头。
        .navigationLinkIndicatorVisibility(.hidden)
        // 残影对应的流水已不存在，不能再进入详情。
        .disabled(mark == .deleted)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if isDeletable {
                // 不用 destructive 角色：它会让行先消失，而这里还要等确认，取消后行又会闪回来
                Button {
                    actions.onDelete(row)
                } label: {
                    Label(deleteTitle, systemImage: "trash")
                }
                .tint(Color(.ledgerRed))
            }
        }
        .contextMenu {
            if isExisting {
                Button {
                    actions.onRepeat(row.id)
                } label: {
                    Label(
                        AccountLocalization.string("home.transaction.repeat", locale: locale),
                        systemImage: "plus.square.on.square"
                    )
                }
                .accessibilityIdentifier("home-transaction-repeat")
            }
            if isDeletable {
                Button(role: .destructive) {
                    actions.onDelete(row)
                } label: {
                    Label(deleteTitle, systemImage: "trash")
                }
            }
        }
        .accessibilityLabel(
            mark == .deleted
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
        // 先声明为容器，标识才落在整个空状态上，而不是被下发给内部文字。
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-details-empty")
    }
}
