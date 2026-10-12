import SwiftData
import SwiftUI

/// 根级搜索 Tab 中的本地记账搜索页。
///
/// 页面从上到下是：系统搜索栏、常驻的筛选条、内容区。内容区在没有任何条件时展示最近搜索和
/// 常用分类，有条件时展示与首页同一写法的按日流水；筛选条在输入关键词时也始终点得到。
struct BookkeepingSearchView: View {
    @Environment(\.calendar) private var environmentCalendar
    @Environment(\.locale) private var locale
    @Query private var transactions: [AccountTransaction]
    @Query private var accounts: [Account]

    /// 系统搜索栏当前实时输入的关键词。
    @State private var query = ""

    /// 系统搜索界面是否处于激活状态。
    @State private var isSearchPresented = false

    /// 已确认并生效的时间条件。
    @State private var timeFilter: BookkeepingSearchTimeFilter = .all

    /// 已选中的收支方向条件。
    @State private var entryFilter: BookkeepingSearchEntryFilter = .all

    /// 是否展示时间筛选 Sheet。
    @State private var isTimeFilterPresented = false

    /// 最近搜索词的存储文本，格式由 `BookkeepingSearchHistory` 约定。
    @AppStorage(BookkeepingSearchHistory.storageKey) private var storedHistory = ""

    /// 请求根级搜索导航栈打开指定流水详情。
    let onOpenTransaction: (UUID) -> Void

    /// 初始化搜索页的跨账户流水和全量账户查询。
    init(onOpenTransaction: @escaping (UUID) -> Void) {
        self.onOpenTransaction = onOpenTransaction
        _transactions = Query(BookkeepingSearchPresentation.descriptor())
        _accounts = Query(BookkeepingSearchPresentation.accountDescriptor())
    }

    var body: some View {
        let presentation = BookkeepingSearchPresentation(
            transactions: transactions,
            accounts: accounts,
            query: query,
            timeFilter: timeFilter,
            entryFilter: entryFilter,
            calendar: environmentCalendar,
            locale: locale
        )

        // 筛选条放在搜索栏正下方的内容区：正在输入关键词时导航栏按钮会被收起，这里始终点得到。
        VStack(spacing: 0) {
            SearchFilterBar(
                timeFilter: $timeFilter,
                entryFilter: $entryFilter,
                calendar: environmentCalendar,
                locale: locale,
                onEditRange: { isTimeFilterPresented = true }
            )
            searchContent(presentation)
        }
        .navigationTitle(text("bookkeeping.search.title"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $query,
            isPresented: $isSearchPresented,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text(text("bookkeeping.search.prompt"))
        )
        .onSubmit(of: .search) {
            remember(query)
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled(true)
        .sheet(isPresented: $isTimeFilterPresented) {
            NavigationStack {
                BookkeepingSearchTimeFilterView(
                    initialFilter: timeFilter,
                    calendar: environmentCalendar,
                    onCancel: {
                        isTimeFilterPresented = false
                    },
                    onConfirm: { newFilter in
                        timeFilter = newFilter
                        isTimeFilterPresented = false
                    }
                )
            }
            // 只有两行日期，半屏足够，背后的搜索结果仍然看得见。
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .paperPage()
    }

    /// 根据投影状态渲染初始、无结果或日期分组结果。
    @ViewBuilder
    private func searchContent(
        _ presentation: BookkeepingSearchPresentation
    ) -> some View {
        switch presentation.state {
        case .initial:
            SearchLandingView(
                suggestions: presentation.suggestions,
                recentQueries: BookkeepingSearchHistory.decode(storedHistory),
                locale: locale,
                onSearch: { query = $0 },
                onClearRecents: { storedHistory = "" }
            )
        case .noResults:
            noResultsContent(presentation)
        case .results:
            VStack(spacing: 0) {
                if let summary = presentation.summary {
                    Text(summaryText(summary))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                        .accessibilityIdentifier("bookkeeping-search-summary")
                }
                resultList(presentation)
            }
        }
    }

    /// 与首页同一写法的按日流水：日期下压一条重线，行与行之间是账本细线。
    private func resultList(_ presentation: BookkeepingSearchPresentation) -> some View {
        List {
            ForEach(presentation.dayGroups) { day in
                Section {
                    ForEach(day.rows) { row in
                        Button {
                            openDetail(transactionID: row.id)
                        } label: {
                            BookkeepingSearchRowView(row: row, query: presentation.normalizedQuery, locale: locale)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .ledgerRow(
                            seed: row.id.handDrawnSeed,
                            showsRule: row.id != day.rows.last?.id
                        )
                        .accessibilityLabel(Text(row.accessibilityLabel))
                        .accessibilityHint(
                            Text(
                                AccountLocalization.formatted(
                                    "bookkeeping.detail.open",
                                    value: row.categoryTitle,
                                    locale: locale
                                )
                            )
                        )
                        .accessibilityIdentifier("bookkeeping-search-result-\(row.id.uuidString)")
                    }
                } header: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(day.formattedDate)
                            .font(.system(.callout, design: .serif, weight: .medium))
                            .foregroundStyle(Color.primary)
                        Text(day.formattedWeekday)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                    .ledgerHeadingRule(seed: UInt64(truncatingIfNeeded: day.transactionDay))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("bookkeeping-search-day-\(day.transactionDay)")
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(22)
        .contentMargins(.top, 8, for: .scrollContent)
        .scrollDismissesKeyboard(.immediately)
        .accessibilityIdentifier("bookkeeping-search-results")
    }

    /// 无结果时展示实际搜索词；清除筛选只放宽时间和收支方向，保留关键词。
    private func noResultsContent(_ presentation: BookkeepingSearchPresentation) -> some View {
        let hasFilters = !timeFilter.isUnbounded || !entryFilter.isUnbounded
        return ContentUnavailableView {
            // 沿用系统空状态的排版，只把图标换成手绘放大镜。
            Label {
                Text(text("bookkeeping.search.empty.title"))
            } icon: {
                HandDrawnMagnifierIllustration()
            }
        } description: {
            if !presentation.normalizedQuery.isEmpty {
                Text(String(
                    format: text("bookkeeping.search.empty.query.format"),
                    locale: locale,
                    presentation.normalizedQuery
                ))
            }
            Text(text(hasFilters ? "bookkeeping.search.empty.filtered.message" : "bookkeeping.search.empty.message"))
        } actions: {
            if hasFilters {
                Button(text("bookkeeping.search.filters.clear")) {
                    timeFilter = .all
                    entryFilter = .all
                }
                .accessibilityIdentifier("bookkeeping-search-empty-range-clear")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bookkeeping-search-no-results")
    }

    /// 结果上方的一行小结：共几笔，支出和收入各多少；为零的一项不写。
    private func summaryText(_ summary: BookkeepingSearchSummary) -> String {
        var parts = [
            String(format: text("bookkeeping.search.summary.count"), locale: locale, summary.count)
        ]
        if summary.expenseTotal > 0 {
            parts.append(String(
                format: text("bookkeeping.search.summary.expense"),
                locale: locale,
                summary.expenseTotal.formatted(.currency(code: "CNY").locale(locale))
            ))
        }
        if summary.incomeTotal > 0 {
            parts.append(String(
                format: text("bookkeeping.search.summary.income"),
                locale: locale,
                summary.incomeTotal.formatted(.currency(code: "CNY").locale(locale))
            ))
        }
        return parts.joined(separator: " · ")
    }

    /// 把用过的关键词记入最近搜索。
    private func remember(_ query: String) {
        storedHistory = BookkeepingSearchHistory.encode(
            BookkeepingSearchHistory.adding(query, to: BookkeepingSearchHistory.decode(storedHistory))
        )
    }

    /// 记录目标流水并结束系统搜索界面，使详情直接成为当前导航页。
    private func openDetail(transactionID: UUID) {
        // 点开结果说明这个关键词有用，记入最近搜索。
        remember(query)
        onOpenTransaction(transactionID)
        isSearchPresented = false
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 没有任何搜索条件时的内容：最近搜索、常用分类和一段搜索说明。
///
/// 账本还没有可搜的记账、也没有搜索记录时，改为一幅手绘放大镜的空状态。
private struct SearchLandingView: View {
    /// 来自实际记账的分类快捷入口。
    let suggestions: [BookkeepingSearchSuggestion]

    /// 最近用过的关键词，最新的在前。
    let recentQueries: [String]

    /// 当前语言环境。
    let locale: Locale

    /// 用某个关键词直接开始搜索。
    let onSearch: (String) -> Void

    /// 清空最近搜索。
    let onClearRecents: () -> Void

    var body: some View {
        if suggestions.isEmpty, recentQueries.isEmpty {
            ContentUnavailableView {
                Label {
                    Text(text("bookkeeping.search.initial.title"))
                } icon: {
                    HandDrawnMagnifierIllustration()
                }
            } description: {
                Text(text("bookkeeping.search.initial.message"))
            }
            .accessibilityIdentifier("bookkeeping-search-initial")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if !recentQueries.isEmpty {
                        section("bookkeeping.search.recent.title", seed: 41) {
                            Button(text("bookkeeping.search.recent.clear"), action: onClearRecents)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("bookkeeping-search-recent-clear")
                        } content: {
                            ForEach(recentQueries, id: \.self) { recent in
                                Button {
                                    onSearch(recent)
                                } label: {
                                    SearchChipLabel(
                                        title: recent,
                                        systemImage: "clock.arrow.circlepath",
                                        seed: recent.handDrawnSeed
                                    )
                                }
                                .accessibilityIdentifier("bookkeeping-search-recent-\(recent)")
                            }
                        }
                    }

                    if !suggestions.isEmpty {
                        section("bookkeeping.search.suggestions.title", seed: 42) {
                            EmptyView()
                        } content: {
                            ForEach(suggestions) { suggestion in
                                Button {
                                    onSearch(suggestion.title)
                                } label: {
                                    SearchChipLabel(
                                        title: suggestion.title,
                                        systemImage: suggestion.symbolName,
                                        seed: suggestion.title.handDrawnSeed
                                    )
                                }
                                .accessibilityIdentifier("bookkeeping-search-suggestion-\(suggestion.title)")
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(text("bookkeeping.search.initial.message"))
                        Text(amountSearchHint)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("bookkeeping-search-initial")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.immediately)
        }
    }

    /// 一段快捷入口：衬线标题压一条重线，下面是自动换行的一组标签。
    private func section<Trailing: View, Content: View>(
        _ titleKey: String,
        seed: UInt64,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(text(titleKey))
                    .font(.system(.callout, design: .serif, weight: .medium))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                trailing()
            }
            .ledgerHeadingRule(seed: seed)

            LedgerFlowLayout(spacing: 10) {
                content()
            }
        }
    }

    /// 金额示例使用当前区域的数字格式，避免小数分隔符与输入习惯不一致。
    private var amountSearchHint: String {
        String(
            format: text("bookkeeping.search.initial.amount_hint.format"),
            locale: locale,
            Decimal(30).formatted(.number.locale(locale).precision(.fractionLength(0))),
            Decimal(30).formatted(.number.locale(locale).precision(.fractionLength(2))),
            (Decimal(305) / 10).formatted(.number.locale(locale).precision(.fractionLength(2)))
        )
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 搜索栏下方常驻的筛选条：收支方向和时间范围都是点一下选中、再点一下取消的标签。
private struct SearchFilterBar: View {
    /// 已生效的时间条件。
    @Binding var timeFilter: BookkeepingSearchTimeFilter

    /// 已选中的收支方向条件。
    @Binding var entryFilter: BookkeepingSearchEntryFilter

    /// 业务日使用的公历及时区。
    let calendar: Calendar

    /// 标签和日期摘要使用的语言环境。
    let locale: Locale

    /// 打开自定义日期范围的操作。
    let onEditRange: () -> Void

    var body: some View {
        let today = Date()
        // 当前范围正好等于某个常用范围时点亮对应标签，否则算作自定义范围。
        let activePreset = BookkeepingSearchTimePreset.allCases.first { preset in
            guard let range = preset.range(today: today, calendar: calendar) else { return false }
            return range == timeFilter.dateRange
        }
        let hasCustomRange = timeFilter.dateRange != nil && activePreset == nil

        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                entryChip(.expense, titleKey: "bookkeeping.entry.type.expense", seed: 51)
                    .accessibilityIdentifier("bookkeeping-search-type-expense")
                entryChip(.income, titleKey: "bookkeeping.entry.type.income", seed: 52)
                    .accessibilityIdentifier("bookkeeping-search-type-income")

                // 收支方向和时间是两类条件，中间隔一道短竖线。
                Rectangle()
                    .fill(Color.primary.opacity(0.16))
                    .frame(width: 1, height: 18)
                    .padding(.horizontal, 2)
                    .accessibilityHidden(true)

                ForEach(BookkeepingSearchTimePreset.allCases) { preset in
                    Button {
                        if activePreset == preset {
                            timeFilter = .all
                        } else if let range = preset.range(today: today, calendar: calendar) {
                            timeFilter = .custom(range)
                        }
                    } label: {
                        SearchChipLabel(
                            title: text(preset.titleLocalizationKey),
                            isSelected: activePreset == preset,
                            seed: preset.rawValue.handDrawnSeed
                        )
                    }
                    .accessibilityAddTraits(activePreset == preset ? .isSelected : [])
                    .accessibilityIdentifier("bookkeeping-search-preset-\(preset.rawValue)")
                }

                customRangeChip(isSelected: hasCustomRange)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .frame(minHeight: 52)
        }
        .scrollIndicators(.hidden)
        // 筛选条和下面的内容同在一张纸上，用一条账本细线隔开即可。
        .background(alignment: .bottom) {
            HandDrawnRule(seed: 43)
                .stroke(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                .frame(height: 3)
                .padding(.horizontal, 20)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bookkeeping-search-filter-bar")
    }

    /// 收支方向标签：点一下只看这个方向，再点一下恢复全部。
    private func entryChip(
        _ filter: BookkeepingSearchEntryFilter,
        titleKey: String,
        seed: UInt64
    ) -> some View {
        Button {
            entryFilter = entryFilter == filter ? .all : filter
        } label: {
            SearchChipLabel(title: text(titleKey), isSelected: entryFilter == filter, seed: seed)
        }
        .accessibilityAddTraits(entryFilter == filter ? .isSelected : [])
    }

    /// 自定义日期标签：未选中时点开日期选择；选中后显示这段日期，左边改日期、右边的叉清除。
    private func customRangeChip(isSelected: Bool) -> some View {
        HStack(spacing: 0) {
            Button(action: onEditRange) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.footnote.weight(.medium))
                        .accessibilityHidden(true)
                    Text(isSelected ? rangeSummary : text("bookkeeping.search.filter.custom"))
                        .lineLimit(1)
                }
                .padding(.leading, 13)
                .padding(.trailing, isSelected ? 6 : 13)
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(Text(text("bookkeeping.search.filter")))
            .accessibilityValue(Text(rangeSummary))
            .accessibilityIdentifier("bookkeeping-search-filter")

            if isSelected {
                Button {
                    timeFilter = .all
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .frame(minWidth: 36, minHeight: 36)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text(text("bookkeeping.search.range.clear")))
                .accessibilityIdentifier("bookkeeping-search-range-clear")
            }
        }
        .font(.system(.subheadline, design: .serif))
        .modifier(SearchChipStyle(isSelected: isSelected, seed: 53))
    }

    /// 当前时间条件的本地化摘要；没有范围时为"不限时间"。
    private var rangeSummary: String {
        guard let range = timeFilter.dateRange else {
            return text("bookkeeping.search.filter.all")
        }
        let start = TransactionDay.date(from: range.startDay, calendar: calendar, locale: locale)
        let end = TransactionDay.date(from: range.endDay, calendar: calendar, locale: locale)
        guard let start, let end else { return "\(range.startDay)-\(range.endDay)" }
        let dateCalendar = TransactionDay.gregorianCalendar(basedOn: calendar, locale: locale)
        return String(
            format: text("bookkeeping.search.range.format"),
            locale: locale,
            BookkeepingDateFormatting.shortDate(start, locale: locale, calendar: dateCalendar),
            BookkeepingDateFormatting.shortDate(end, locale: locale, calendar: dateCalendar)
        )
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 搜索页标签的外形：未选中是一圈铅笔线，选中后涂成墨色实底。
private struct SearchChipStyle: ViewModifier {
    /// 是否为选中状态。
    let isSelected: Bool

    /// 边框的笔迹种子。
    let seed: UInt64

    func body(content: Content) -> some View {
        content
            .foregroundStyle(isSelected ? Color(.onAccent) : Color.primary)
            .background {
                if isSelected {
                    HandDrawnBox(cornerRadius: 14, seed: seed)
                        .fill(Color.accentColor)
                } else {
                    HandDrawnBox(cornerRadius: 14, seed: seed)
                        .stroke(
                            Color.primary.opacity(0.4),
                            style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round)
                        )
                }
            }
            .contentShape(Rectangle())
    }
}

/// 搜索页的一枚标签：可选的图标加一行文字。
private struct SearchChipLabel: View {
    /// 已本地化的标签文字。
    let title: String

    /// 文字前的 SF Symbol；不需要图标时为空。
    var systemImage: String?

    /// 是否为选中状态。
    var isSelected = false

    /// 边框的笔迹种子。
    let seed: UInt64

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.footnote.weight(.medium))
                    .accessibilityHidden(true)
            }
            Text(title)
                .lineLimit(1)
        }
        .font(.system(.subheadline, design: .serif))
        .padding(.horizontal, 13)
        .frame(minHeight: 36)
        .modifier(SearchChipStyle(isSelected: isSelected, seed: seed))
    }
}

/// 搜索结果行：与首页流水同一写法，另外写出所属账户，并用账本红标出命中的字。
private struct BookkeepingSearchRowView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 结果行的纯展示数据。
    let row: BookkeepingSearchRowPresentation

    /// 已清理的关键词，用于标出命中的字。
    let query: String

    /// 当前语言环境。
    let locale: Locale

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: row.symbolName)
                .font(.body.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38)
                // 图标垫在随手涂出的色块上，每条流水的色块形状各不相同。
                .background(Color.accentColor.opacity(0.08), in: HandDrawnBlob(seed: row.id.handDrawnSeed))
                .accessibilityHidden(true)

            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
            layout {
                VStack(alignment: .leading, spacing: 3) {
                    Text(highlighted(row.categoryTitle))
                        .font(.body.weight(.medium))
                    if let note = row.note {
                        Text(highlighted(note))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text(accountText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(row.formattedAmount)
                    .font(.system(.body, design: .serif).monospacedDigit())
                    .foregroundStyle(row.matchesAmount ? Color(.ledgerRed) : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .layoutPriority(1)
            }
        }
        .frame(minHeight: 44)
    }

    /// 正常账户只写名称；已停用或已不存在的账户补上状态。
    private var accountText: String {
        let status = row.accountState == .active ? nil : row.accountState.localizedTitle(locale: locale)
        return [row.accountName, status].compactMap { $0 }.joined(separator: " · ")
    }

    /// 把文字里命中关键词的部分标成账本红。
    private func highlighted(_ value: String) -> AttributedString {
        var attributed = AttributedString(value)
        if let match = BookkeepingSearchPresentation.matchRange(of: query, in: value, locale: locale),
           let range = Range<AttributedString.Index>(match, in: attributed) {
            attributed[range].foregroundColor = Color(.ledgerRed)
        }
        return attributed
    }
}
