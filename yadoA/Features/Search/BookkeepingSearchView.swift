import SwiftData
import SwiftUI

/// 根级搜索 Tab 中的本地记账搜索页。
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

    /// 是否展示时间筛选 Sheet。
    @State private var isTimeFilterPresented = false

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
            calendar: environmentCalendar,
            locale: locale
        )

        // 日期条放在搜索栏正下方的内容区：正在输入关键词时导航栏按钮会被收起，这里始终点得到。
        VStack(spacing: 0) {
            SearchDateFilterBar(
                range: timeFilter.dateRange,
                calendar: environmentCalendar,
                locale: locale,
                onEdit: { isTimeFilterPresented = true },
                onClear: { timeFilter = .all }
            )
            searchContent(presentation)
        }
        .navigationTitle(AccountLocalization.string("bookkeeping.search.title", locale: locale))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $query,
            isPresented: $isSearchPresented,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text(AccountLocalization.string("bookkeeping.search.prompt", locale: locale))
        )
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
            initialContent(presentation.suggestedCategories)
        case .noResults:
            noResultsContent(presentation)
        case .results:
            List {
                ForEach(presentation.dayGroups) { day in
                    Section {
                        ForEach(day.rows) { row in
                            Button {
                                openDetail(transactionID: row.id)
                            } label: {
                                BookkeepingSearchRowView(row: row, locale: locale)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .ledgerRow(
                                seed: row.id.handDrawnSeed,
                                showsRule: row.id != day.rows.last?.id
                            )
                            .accessibilityIdentifier("bookkeeping-search-result-\(row.id.uuidString)")
                        }
                    } header: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(day.formattedDate)
                                .font(.system(.callout, design: .serif, weight: .medium))
                                .foregroundStyle(Color.primary)
                            Text(day.formattedWeekday)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .ledgerHeadingRule(seed: UInt64(truncatingIfNeeded: day.transactionDay))
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("bookkeeping-search-day-\(day.transactionDay)")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(22)
            .accessibilityIdentifier("bookkeeping-search-results")
        }
    }

    /// 搜索前说明跨账户范围与金额语义，并提供来自实际记账的类别快捷入口。
    private func initialContent(_ categories: [String]) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text(AccountLocalization.string("bookkeeping.search.initial.title", locale: locale))
                        .font(.system(.title2, design: .serif, weight: .medium))
                    Text(AccountLocalization.string("bookkeeping.search.initial.message", locale: locale))
                        .foregroundStyle(.secondary)
                    Text(amountSearchHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
                .ledgerRow(seed: 41, showsRule: false)
                .accessibilityIdentifier("bookkeeping-search-initial")
            }

            if !categories.isEmpty {
                Section {
                    ForEach(categories, id: \.self) { category in
                        Button {
                            query = category
                        } label: {
                            Label(category, systemImage: "magnifyingglass")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .ledgerRow(
                            seed: category.handDrawnSeed,
                            showsRule: category != categories.last
                        )
                        .accessibilityIdentifier("bookkeeping-search-suggestion-\(category)")
                    }
                } header: {
                    Text(AccountLocalization.string("bookkeeping.search.suggestions.title", locale: locale))
                        .font(.system(.callout, design: .serif, weight: .medium))
                        .foregroundStyle(Color.primary)
                        .ledgerHeadingRule(seed: 42)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// 无结果时展示实际搜索词；清除日期条件只扩大时间范围，保留关键词。
    private func noResultsContent(_ presentation: BookkeepingSearchPresentation) -> some View {
        ContentUnavailableView {
            Label(
                AccountLocalization.string("bookkeeping.search.empty.title", locale: locale),
                systemImage: "magnifyingglass"
            )
        } description: {
            if !presentation.normalizedQuery.isEmpty {
                Text(String(
                    format: AccountLocalization.string("bookkeeping.search.empty.query.format", locale: locale),
                    locale: locale,
                    presentation.normalizedQuery
                ))
            }
            Text(AccountLocalization.string(
                timeFilter.isUnbounded
                    ? "bookkeeping.search.empty.message"
                    : "bookkeeping.search.empty.filtered.message",
                locale: locale
            ))
        } actions: {
            if !timeFilter.isUnbounded {
                Button(AccountLocalization.string("bookkeeping.search.range.clear", locale: locale)) {
                    timeFilter = .all
                }
                .accessibilityIdentifier("bookkeeping-search-empty-range-clear")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bookkeeping-search-no-results")
    }

    /// 金额示例使用当前区域的数字格式，避免小数分隔符与输入习惯不一致。
    private var amountSearchHint: String {
        String(
            format: AccountLocalization.string("bookkeeping.search.initial.amount_hint.format", locale: locale),
            locale: locale,
            Decimal(30).formatted(.number.locale(locale).precision(.fractionLength(0))),
            Decimal(30).formatted(.number.locale(locale).precision(.fractionLength(2))),
            (Decimal(305) / 10).formatted(.number.locale(locale).precision(.fractionLength(2)))
        )
    }

    /// 记录目标流水并结束系统搜索界面，使详情直接成为当前导航页。
    private func openDetail(transactionID: UUID) {
        onOpenTransaction(transactionID)
        isSearchPresented = false
    }

}

/// 搜索栏下方常驻的日期条：显示当前的日期范围，点一下修改，有范围时右侧可以直接清除。
private struct SearchDateFilterBar: View {
    /// 已提交的闭区间条件；`nil` 表示不限时间。
    let range: BookkeepingSearchDateRange?

    /// 业务日使用的公历及时区。
    let calendar: Calendar

    /// 日期摘要使用的语言环境。
    let locale: Locale

    /// 打开日期范围选择的操作。
    let onEdit: () -> Void

    /// 清除已提交范围的操作。
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onEdit) {
                HStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .foregroundStyle(.secondary)
                    Text(summary)
                        .font(.system(.subheadline, design: .serif))
                        .foregroundStyle(range == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.primary))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                Text(AccountLocalization.string("bookkeeping.search.filter", locale: locale))
            )
            .accessibilityValue(Text(summary))
            .accessibilityIdentifier("bookkeeping-search-filter")

            Spacer(minLength: 0)

            if range != nil {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    Text(AccountLocalization.string("bookkeeping.search.range.clear", locale: locale))
                )
                .accessibilityIdentifier("bookkeeping-search-range-clear")
            }
        }
        .padding(.horizontal, 20)
        // 日期条和下面的结果同在一张纸上，用一条账本细线隔开即可。
        .background(alignment: .bottom) {
            HandDrawnRule(seed: 43)
                .stroke(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                .frame(height: 3)
                .padding(.horizontal, 20)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            range == nil ? "bookkeeping-search-date-bar" : "bookkeeping-search-applied-range"
        )
    }

    /// 当前范围的本地化摘要；没有范围时为"不限时间"。
    private var summary: String {
        guard let range else {
            return AccountLocalization.string("bookkeeping.search.filter.all", locale: locale)
        }
        let start = TransactionDay.date(from: range.startDay, calendar: calendar, locale: locale)
        let end = TransactionDay.date(from: range.endDay, calendar: calendar, locale: locale)
        guard let start, let end else { return "\(range.startDay)-\(range.endDay)" }
        let dateCalendar = TransactionDay.gregorianCalendar(basedOn: calendar, locale: locale)
        let format = Date.FormatStyle(
            date: .numeric,
            time: .omitted,
            locale: locale,
            calendar: dateCalendar,
            timeZone: dateCalendar.timeZone
        )
        return String(
            format: AccountLocalization.string("bookkeeping.search.range.format", locale: locale),
            locale: locale,
            start.formatted(format),
            end.formatted(format)
        )
    }
}

/// 搜索结果行，使用纵向信息层级适配动态字体。
private struct BookkeepingSearchRowView: View {
    /// 结果行的纯展示数据。
    let row: BookkeepingSearchRowPresentation

    /// 当前语言环境。
    let locale: Locale

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(row.categoryTitle)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(row.formattedAmount)
                    .font(.system(.body, design: .serif).monospacedDigit())
                    .lineLimit(1)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.formattedDate)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                accountText
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)

            if let note = row.note {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(row.accessibilityLabel))
    }

    /// 正常账户只展示名称，异常账户额外展示生命周期状态。
    private var accountText: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let accountName = row.accountName {
                Text(accountName)
                    .lineLimit(1)
            }
            if row.accountState != .active {
                Text(statusText)
            }
        }
        .multilineTextAlignment(.trailing)
    }

    /// 账户生命周期状态的本地化标题。
    private var statusText: String {
        row.accountState.localizedTitle(locale: locale)
    }
}
