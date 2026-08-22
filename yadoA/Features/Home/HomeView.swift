import SwiftData
import SwiftUI

/// 首页入口，展示固定头部和当前月份的只读明细。
struct HomeView: View {
    @Environment(\.locale) private var locale

    /// 用户最近一次选择的收支汇总显隐状态。
    @AppStorage("home.summary.amountsVisible") private var areAmountsVisible = false

    var body: some View {
        NavigationStack {
            HomeQueryContent(areAmountsVisible: $areAmountsVisible)
                .navigationTitle(AppTab.home.title(locale: locale))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Image(systemName: "person.circle")
                            .accessibilityHidden(true)
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 18) {
                            Image(systemName: "magnifyingglass")
                            Image(systemName: "calendar")
                        }
                        .foregroundStyle(.primary)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            Text(
                                AccountLocalization.string(
                                    "home.decorative.actions",
                                    locale: locale
                                )
                            )
                        )
                    }
                }
        }
    }
}

/// 首页跨账户查询内容，负责把 SwiftData 结果转换为当前月份展示。
private struct HomeQueryContent: View {
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var environmentCalendar
    @Environment(\.modelContext) private var modelContext
    @Binding private var areAmountsVisible: Bool
    @Query private var transactions: [AccountTransaction]

    /// 当前已提交的月份；首次出现时由投影根据数据初始化。
    @State private var selectedMonth: HomeMonth?

    /// 是否展示月份选择 Sheet。
    @State private var isMonthPickerPresented = false

    /// 当前正在快速修改的单笔流水。
    @State private var transactionEditSelection: HomeTransactionEditSelection?

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

        VStack(spacing: 0) {
            HomeOverviewHeader(
                monthPresentation: monthPresentation,
                areAmountsVisible: $areAmountsVisible,
                onSelectMonth: {
                    isMonthPickerPresented = true
                }
            )

            HomeOverviewList(
                monthPresentation: monthPresentation,
                presentation: presentation,
                selectedMonth: activeMonth,
                onSelectMonth: { month in
                    selectedMonth = month
                },
                onEditTransaction: { transactionID in
                    beginEditing(transactionID: transactionID)
                }
            )
        }
        .background(Color(uiColor: .systemBackground))
        .overlay(alignment: .bottomTrailing) {
            NavigationLink {
                DiningExpenseEntryView { draft in
                    let repository = LocalExpenseRepository(
                        container: modelContext.container
                    )
                    try repository.save(draft)
                }
            } label: {
                Image(systemName: "plus")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.primary)
                    .frame(width: 58, height: 58)
                    .background(Circle().fill(Color.yellow))
                    .overlay {
                        Circle()
                            .stroke(.white.opacity(0.8), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
            }
            .accessibilityLabel(
                Text(AccountLocalization.string("expense.entry.action", locale: locale))
            )
            .accessibilityIdentifier("home-add-expense")
            .padding(.trailing, 18)
            .padding(.bottom, 18)
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
        .sheet(item: $transactionEditSelection) { selection in
            NavigationStack {
                DiningExpenseQuickEditView(draft: selection.draft) { draft in
                    let repository = LocalExpenseRepository(
                        container: modelContext.container
                    )
                    try repository.update(draft)
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    /// 根据首页行 ID 生成快速修改草稿，避免编辑页直接持有查询模型。
    private func beginEditing(transactionID: UUID) {
        guard let transaction = transactions.first(where: { $0.id == transactionID }),
              let row = HomeOverviewPresentation.row(
                  for: transaction,
                  locale: locale,
                  calendar: environmentCalendar
              ),
              let amount = transaction.amount
        else { return }

        transactionEditSelection = HomeTransactionEditSelection(
            draft: DiningExpenseEditDraft(
                id: transaction.id,
                title: row.title,
                amountText: Self.amountText(for: amount)
            )
        )
    }

    /// 把精确 Decimal 转成编辑草稿使用的英文句点金额字符。
    private static func amountText(for amount: Decimal) -> String {
        var amount = amount
        return NSDecimalString(&amount, Locale(identifier: "en_US_POSIX"))
    }
}

/// 首页固定头部，展示月份入口、月度收支和金额显隐控制。
private struct HomeOverviewHeader: View {
    @Environment(\.locale) private var locale

    /// 当前月份的已本地化展示数据。
    let monthPresentation: HomeOverviewMonthPresentation

    /// 是否展示收入和支出的实际金额。
    @Binding var areAmountsVisible: Bool

    /// 用户点击月份入口后的回调。
    let onSelectMonth: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                Button(action: onSelectMonth) {
                    HStack(spacing: 6) {
                        Text(monthPresentation.formattedMonth)
                            .font(.headline)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
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
                    areAmountsVisible.toggle()
                } label: {
                    Image(systemName: areAmountsVisible ? "eye" : "eye.slash")
                        .font(.headline)
                        .frame(width: 44, height: 44)
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
            .padding(.horizontal, 20)

            HStack(spacing: 24) {
                HomeSummaryColumn(
                    title: AccountLocalization.string("home.summary.income", locale: locale),
                    amount: monthPresentation.incomeTotal,
                    isVisible: areAmountsVisible,
                    isIncome: true,
                    locale: locale
                )

                HomeSummaryColumn(
                    title: AccountLocalization.string("home.summary.expense", locale: locale),
                    amount: monthPresentation.expenseTotal,
                    isVisible: areAmountsVisible,
                    isIncome: false,
                    locale: locale
                )

                Spacer()
            }
            .padding(.horizontal, 20)

            HStack(spacing: 12) {
                Image(systemName: "calendar.badge.clock")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(
                    AccountLocalization.string(
                        monthPresentation.isEmpty
                            ? "home.details.empty.title"
                            : "home.details.title",
                        locale: locale
                    )
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .padding(.top, 8)
        .background(Color.yellow.opacity(0.32))
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
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(isVisible ? formattedAmount : AccountLocalization.string("home.summary.mask", locale: locale))
                .font(.body.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
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
        .frame(minWidth: 72, alignment: .leading)
    }

    /// 使用应用当前固定的 CNY 货币格式化金额。
    private var formattedAmount: String {
        amount.formatted(.currency(code: "CNY").locale(locale))
    }
}

/// 当前月份的独立明细滚动区域。
private struct HomeOverviewList: View {
    @State private var boundaryLatch = false
    @State private var scrollPhase: ScrollPhase = .idle

    /// 当前月份的按日展示数据。
    let monthPresentation: HomeOverviewMonthPresentation

    /// 用于寻找边界目标月份的完整投影。
    let presentation: HomeOverviewPresentation

    /// 当前已提交月份。
    let selectedMonth: HomeMonth

    /// 月份切换回调。
    let onSelectMonth: (HomeMonth) -> Void

    /// 用户请求快速修改某一笔流水时的回调。
    let onEditTransaction: (UUID) -> Void

    var body: some View {
        GeometryReader { containerGeometry in
            ScrollViewReader { scrollProxy in
                List {
                    Color.clear
                        .frame(height: 1)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .id(HomeOverviewScrollAnchor.top)

                    if monthPresentation.isEmpty {
                        HomeEmptyState()
                            .frame(
                                maxWidth: .infinity,
                                minHeight: max(220, containerGeometry.size.height - 2)
                            )
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(monthPresentation.dayGroups) { day in
                            Section {
                                ForEach(day.rows) { row in
                                    HomeOverviewRow(
                                        row: row,
                                        onEdit: {
                                            onEditTransaction(row.id)
                                        }
                                    )
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
                        .id(HomeOverviewScrollAnchor.bottom)
                }
                .listStyle(.insetGrouped)
                .scrollBounceBehavior(.always)
                .accessibilityIdentifier("home-details-scroll")
                .onScrollGeometryChange(for: HomeScrollMetrics.self) { geometry in
                    HomeScrollMetrics(
                        offsetY: geometry.contentOffset.y,
                        contentHeight: geometry.contentSize.height,
                        visibleHeight: geometry.visibleRect.height,
                        topInset: geometry.contentInsets.top,
                        bottomInset: geometry.contentInsets.bottom
                    )
                } action: { _, metrics in
                    guard !boundaryLatch, scrollPhase != .idle else { return }
                    let navigator = HomeMonthNavigator(
                        availableMonths: presentation.availableMonths
                    )

                    if metrics.isPulledPastTop {
                        boundaryLatch = true
                        if let earlierMonth = navigator.earlierMonth(from: selectedMonth) {
                            onSelectMonth(earlierMonth)
                        }
                    } else if metrics.isPulledPastBottom {
                        boundaryLatch = true
                        if let laterMonth = navigator.laterMonth(from: selectedMonth) {
                            onSelectMonth(laterMonth)
                        }
                    }
                }
                .onScrollPhaseChange { _, phase in
                    scrollPhase = phase
                    if phase == .idle {
                        boundaryLatch = false
                    }
                }
                .onChange(of: selectedMonth) { _, _ in
                    scrollToTop(using: scrollProxy)
                }
            }
        }
    }

    /// 把当前月份滚动到统一的顶部锚点。
    private func scrollToTop(using proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(HomeOverviewScrollAnchor.top, anchor: .top)
            }
        }
    }
}

/// 首页原生列表中的日期分组标题。
private struct HomeOverviewDayHeader: View {
    @Environment(\.locale) private var locale

    /// 当前日期组数据。
    let day: HomeOverviewDayPresentation

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(day.formattedDate)
            Text(day.formattedWeekday)
            Spacer(minLength: 8)
            Text(daySummary)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .textCase(nil)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home-day-\(day.transactionDay)")
    }

    /// 当前日期组的收入和支出摘要。
    private var daySummary: String {
        let expense = day.expenseTotal.formatted(.currency(code: "CNY").locale(locale))
        return AccountLocalization.formatted(
            "home.day.expense",
            value: expense,
            locale: locale
        )
    }
}

/// 首页单条只读流水行。
private struct HomeOverviewRow: View {
    @Environment(\.locale) private var locale

    /// 已完成本地化的首页行数据。
    let row: HomeOverviewRowPresentation

    /// 打开该流水快速编辑页的回调。
    let onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            HStack(spacing: 14) {
                Image(systemName: "fork.knife")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.yellow)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color.secondary.opacity(0.12)))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title)
                        .font(.body)
                    if let note = row.note {
                        Text(note)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                Text(row.formattedAmount)
                    .font(.body.monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityHint(
            Text(
                AccountLocalization.formatted(
                    "home.transaction.edit",
                    value: row.title,
                    locale: locale
                )
            )
        )
        .accessibilityIdentifier("home-transaction-\(row.id.uuidString)")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(action: onEdit) {
                Label(
                    AccountLocalization.string("home.transaction.edit.action", locale: locale),
                    systemImage: "pencil"
                )
            }
            .tint(.blue)
            .accessibilityIdentifier("home-transaction-edit-\(row.id.uuidString)")
        }
    }
}

/// 首页快速编辑 Sheet 使用的稳定流水草稿包装。
private struct HomeTransactionEditSelection: Identifiable {
    /// 快速编辑页面使用的草稿。
    let draft: DiningExpenseEditDraft

    /// `sheet(item:)` 使用流水 UUID 作为稳定标识。
    var id: UUID { draft.id }
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

/// 明细区域使用的稳定顶部和底部锚点。
private enum HomeOverviewScrollAnchor {
    /// 所有月份共用的顶部锚点。
    static let top = "home-details-top"

    /// 所有月份共用的底部锚点。
    static let bottom = "home-details-bottom"
}

/// 滚动边界观察所需的最小几何数据。
private struct HomeScrollMetrics: Equatable {
    /// 当前滚动偏移的 Y 值。
    let offsetY: CGFloat

    /// 内容高度。
    let contentHeight: CGFloat

    /// 可见滚动区域高度。
    let visibleHeight: CGFloat

    /// 顶部内容 inset。
    let topInset: CGFloat

    /// 底部内容 inset。
    let bottomInset: CGFloat

    /// 是否已经向下拉过顶部边界。
    var isPulledPastTop: Bool {
        offsetY < -topInset - 24
    }

    /// 是否已经向上滑过底部边界。
    var isPulledPastBottom: Bool {
        let visibleBottom = offsetY + visibleHeight
        return visibleBottom > contentHeight + bottomInset + 24
    }
}

#Preview("Home empty") {
    HomeView()
    .modelContainer(
        for: [Account.self, AccountTransaction.self, BookkeepingPreference.self],
        inMemory: true
    )
}
