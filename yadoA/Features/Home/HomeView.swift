import SwiftData
import SwiftUI

/// 首页入口，展示导航栏月份入口、紧凑汇总和当前月份的只读明细。
struct HomeView: View {
    @Environment(\.locale) private var locale

    /// 用户最近一次选择的收支汇总显隐状态。
    @AppStorage("home.summary.amountsVisible") private var areAmountsVisible = false

    /// 最多取一条收支，仅用于判断账本是否为空；搜索只覆盖收支，空账本时隐藏搜索入口。
    @Query private var anyBookkeepingEntry: [AccountTransaction]

    /// 长按流水选择“再记一笔”后，带着预填好的草稿进入新增页面。
    private let onRepeatEntry: (DiningExpenseDraft) -> Void

    /// 创建首页。
    ///
    /// - Parameter onRepeatEntry: 选择“再记一笔”后的导航动作。
    init(onRepeatEntry: @escaping (DiningExpenseDraft) -> Void = { _ in }) {
        self.onRepeatEntry = onRepeatEntry
        var descriptor = AccountTransaction.bookkeepingEntriesDescriptor()
        descriptor.fetchLimit = 1
        _anyBookkeepingEntry = Query(descriptor)
    }

    var body: some View {
        HomeQueryContent(areAmountsVisible: $areAmountsVisible, onRepeatEntry: onRepeatEntry)
            .navigationTitle(AppTab.home.title(locale: locale))
            // 标题仅供返回按钮和辅助功能使用，导航栏中部由月份入口占据。
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !anyBookkeepingEntry.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink(value: HomeRoute.search) {
                            Label(
                                AccountLocalization.string("bookkeeping.search.title", locale: locale),
                                systemImage: "magnifyingglass"
                            )
                        }
                        .accessibilityIdentifier("home-search")
                    }
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
    @Environment(\.modelContext) private var modelContext
    /// 语音记账共享状态；卡片上点选的流水通过它交给首页定位。
    @Environment(VoiceBookkeepingState.self) private var voice
    @Binding private var areAmountsVisible: Bool
    @Query private var transactions: [AccountTransaction]
    @Query private var categories: [BookkeepingCategory]
    /// 判断流水所在账户是否还能修改，以及删除确认里显示账户名称。
    @Query private var accounts: [Account]

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

    /// 等待确认删除的流水行。
    @State private var deletionCandidate: HomeOverviewRowPresentation?

    /// 是否显示删除确认。
    @State private var isDeleteConfirmationPresented = false

    /// 最近一次删除是否失败。
    @State private var isDeleteFailed = false

    /// 刚新增、修改或删除成功的流水提示通道。
    private let recentEntryHighlight = HomeRecentEntryHighlight.shared

    /// 选择“再记一笔”后的导航动作。
    private let onRepeatEntry: (DiningExpenseDraft) -> Void

    init(areAmountsVisible: Binding<Bool>, onRepeatEntry: @escaping (DiningExpenseDraft) -> Void) {
        _areAmountsVisible = areAmountsVisible
        self.onRepeatEntry = onRepeatEntry
        _transactions = Query(HomeOverviewPresentation.descriptor())
        _categories = Query()
    }

    /// 存储中的分类设置与预置默认值合并后的目录。
    private var catalog: BookkeepingCategoryCatalog {
        BookkeepingCategoryCatalog(categories: categories)
    }

    var body: some View {
        let presentation = HomeOverviewPresentation(
            transactions: transactions,
            calendar: environmentCalendar,
            locale: locale,
            catalog: catalog
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
                    rowActions: HomeRowActions(
                        editableTransactionIDs: HomeOverviewPresentation.editableTransactionIDs(
                            transactions: transactions,
                            accounts: accounts
                        ),
                        onRepeat: { transactionID in
                            repeatEntry(transactionID: transactionID)
                        },
                        onDelete: { row in
                            deletionCandidate = row
                            isDeleteConfirmationPresented = true
                        }
                    ),
                    onSelectMonth: { month in
                        selectedMonth = month
                    }
                )
                // 常规布局下汇总作为明细的顶部栏：流水从它下方滑过并在边缘柔和淡出，而不是被一刀切掉。
                .paperTopBar(isEnabled: !usesStackedHeader) { header }
            }
        }
        .paperPage()
        // 会话卡片浮在明细之上。iPhone 的 iOS 26.1 起麦克风在 Tab Bar 附属栏里，卡片出现在附属栏上方；
        // 其他情况麦克风悬浮在这里且不带整条底栏，居中放置以避开右侧的金额列，卡片出现在它上方。
        // 明细自己按麦克风高度留白，不用 `voiceBookkeepingDock()` 的安全区留白。
        .overlay(alignment: .bottom) {
            VoiceBookkeepingDock { height in
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
            recentEntryHighlight.homeDidAppear()
            // 从别的页面返回，带动画滚动会和返回转场叠加
            showRecentEntryHighlightIfNeeded(animated: false)
            // 在别的 Tab 点了卡片上的流水，切过来后再定位；放在最后，定位的月份不被上面的提示改掉
            locatePendingChangeIfNeeded(animated: false)
        }
        .onDisappear {
            isVisible = false
            recentEntryHighlight.homeDidDisappear()
        }
        // 截图记账以全屏模态盖在首页之上，关闭时不会再次触发 onAppear，需要直接响应登记。
        // 语音记账在首页上直接改数据，也走这里，此时用户正看着列表，滚动带动画。
        .onChange(of: recentEntryHighlight.pending) { _, _ in
            showRecentEntryHighlightIfNeeded(animated: true)
        }
        // 在首页上点了卡片上的流水，直接定位
        .onChange(of: voice.pendingLocate) { _, _ in
            locatePendingChangeIfNeeded(animated: true)
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
        .alert(
            text("bookkeeping.delete.title"),
            isPresented: $isDeleteConfirmationPresented,
            presenting: deletionCandidate
        ) { row in
            Button(text("bookkeeping.delete.action"), role: .destructive) {
                delete(row)
            }
            Button(text("common.cancel"), role: .cancel) {}
        } message: { row in
            Text(String(
                format: text("bookkeeping.delete.message"),
                locale: locale,
                row.title,
                row.formattedAmount,
                accountName(forTransaction: row.id)
            ))
        }
        .alert(text("bookkeeping.delete.failed"), isPresented: $isDeleteFailed) {
            Button(text("common.close"), role: .cancel) {}
        }
    }
}

// MARK: - 流水快捷操作

extension HomeQueryContent {
    /// 以这笔流水为模板再记一笔：沿用分类、金额、账户和备注，日期改为今天。
    ///
    /// - Parameter transactionID: 作为模板的流水 UUID。
    private func repeatEntry(transactionID: UUID) {
        guard let transaction = transactions.first(where: { $0.id == transactionID }),
              let draft = DiningExpenseDraft(
                  repeating: transaction,
                  accounts: accounts,
                  transactionDay: TransactionDay.encode(.now, calendar: environmentCalendar),
                  catalog: catalog
              )
        else { return }
        onRepeatEntry(draft)
    }

    /// 确认后删除一笔流水并回滚余额；成功时在原位置划掉，失败时提示。
    ///
    /// - Parameter row: 要删除的流水行。
    private func delete(_ row: HomeOverviewRowPresentation) {
        // 删除后流水对象即失效，先拷贝首页行快照，供首页在原位置画出被划掉的残影。
        let deletedRow = transactions.first { $0.id == row.id }.flatMap {
            HomeOverviewPresentation.deletedRow(
                for: $0, locale: locale, calendar: environmentCalendar, catalog: catalog
            )
        }
        do {
            try LocalExpenseRepository(container: modelContext.container).delete(id: row.id)
            AppHaptics.play(.destructive)
            if let deletedRow {
                // 用户正看着这一行，直接就地划掉；不走 `present`，避免列表滚动到这一行
                show(HomeRecentEntryHighlight.Entry(
                    id: row.id,
                    transactionDay: deletedRow.transactionDay,
                    change: .deleted(deletedRow),
                    savedAt: .now
                ))
            }
        } catch {
            AppHaptics.play(.error)
            isDeleteFailed = true
        }
    }

    /// 流水所在账户的名称，用于删除确认；账户不存在时为空。
    ///
    /// - Parameter transactionID: 流水 UUID。
    private func accountName(forTransaction transactionID: UUID) -> String {
        guard let accountID = transactions.first(where: { $0.id == transactionID })?.accountID else { return "" }
        return accounts.first { $0.id == accountID }?.name ?? ""
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
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

    /// 首页可见时取走语音卡片上点选的流水并定位；从别的 Tab 切过来时首页还没出现，等出现时再取。
    ///
    /// - Parameter animated: 是否带动画滚动；刚切过来时列表才出现，直接定位。
    private func locatePendingChangeIfNeeded(animated: Bool) {
        guard isVisible, let change = voice.pendingLocate else { return }
        voice.pendingLocate = nil
        locate(change, animated: animated)
    }

    /// 在明细里定位语音卡片上点选的一笔流水：切到它现在所在的月份、滚到汇总下方，并重新播放一次提示。
    ///
    /// 按流水当前的记账日定位，之后的轮次改过日期也能找到；流水已被删除时不做任何事。
    /// - Parameters:
    ///   - change: 卡片上点选的流水变更，删除和已撤销的变更不会走到这里。
    ///   - animated: 是否带动画滚动。
    private func locate(_ change: VoiceEntryChange, animated: Bool) {
        guard let transaction = transactions.first(where: { $0.id == change.transactionID }) else { return }
        // 修改不再对比旧值：之后的轮次可能又改过，只在标题和金额下补笔迹提示"就是这笔"
        let entry = HomeRecentEntryHighlight.Entry(
            id: transaction.id,
            transactionDay: transaction.transactionDay,
            change: change.kind == .updated ? .updated(previous: nil) : .added,
            savedAt: .now
        )
        present([entry], animated: animated)
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

#Preview("Home empty") {
    NavigationStack {
        HomeView()
    }
    .environment(AuthStore())
    .environment(SignInPresentation())
    .environment(VoiceBookkeepingState())
    .modelContainer(
        for: [Account.self, AccountTransaction.self, BookkeepingPreference.self],
        inMemory: true
    )
}
