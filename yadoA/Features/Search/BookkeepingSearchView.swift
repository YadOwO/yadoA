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

        Group {
            if let range = timeFilter.dateRange {
                VStack(spacing: 0) {
                    AppliedSearchRangeView(
                        range: range,
                        calendar: environmentCalendar,
                        locale: locale,
                        onClear: { timeFilter = .all }
                    )
                    searchContent(presentation)
                }
            } else {
                searchContent(presentation)
            }
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isTimeFilterPresented = true
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(
                    Text(AccountLocalization.string("bookkeeping.search.filter", locale: locale))
                )
                .accessibilityValue(Text(filterAccessibilityValue))
                .accessibilityIdentifier("bookkeeping-search-filter")
            }
        }
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
                                HStack(spacing: 8) {
                                    BookkeepingSearchRowView(row: row, locale: locale)
                                    Image(systemName: "chevron.forward")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                        .accessibilityHidden(true)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("bookkeeping-search-result-\(row.id.uuidString)")
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(day.formattedDate)
                                .font(.headline)
                            Text(day.formattedWeekday)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .textCase(nil)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("bookkeeping-search-day-\(day.transactionDay)")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .accessibilityIdentifier("bookkeeping-search-results")
        }
    }

    /// 搜索前说明跨账户范围与金额语义，并提供来自实际记账的类别快捷入口。
    private func initialContent(_ categories: [String]) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text(AccountLocalization.string("bookkeeping.search.initial.title", locale: locale))
                        .font(.title2.bold())
                    Text(AccountLocalization.string("bookkeeping.search.initial.message", locale: locale))
                        .foregroundStyle(.secondary)
                    Text(amountSearchHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
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
                        .accessibilityIdentifier("bookkeeping-search-suggestion-\(category)")
                    }
                } header: {
                    Text(AccountLocalization.string("bookkeeping.search.suggestions.title", locale: locale))
                }
                .textCase(nil)
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

    /// 筛选按钮的可读状态，避免只用图标表达当前条件。
    private var filterAccessibilityValue: String {
        guard let range = timeFilter.dateRange else {
            return AccountLocalization.string("bookkeeping.search.filter.all", locale: locale)
        }
        return dateRangeSummary(range)
    }

    /// 将业务日闭区间格式化为筛选状态摘要。
    private func dateRangeSummary(_ range: BookkeepingSearchDateRange) -> String {
        let start = TransactionDay.date(
            from: range.startDay,
            calendar: environmentCalendar,
            locale: locale
        )
        let end = TransactionDay.date(
            from: range.endDay,
            calendar: environmentCalendar,
            locale: locale
        )
        guard let start, let end else { return "\(range.startDay)-\(range.endDay)" }
        let startText = formattedDate(start)
        let endText = formattedDate(end)
        return String(
            format: AccountLocalization.string(
                "bookkeeping.search.range.format",
                locale: locale
            ),
            locale: locale,
            startText,
            endText
        )
    }

    /// 使用当前语言环境格式化不含时间的日期。
    private func formattedDate(_ date: Date) -> String {
        let calendar = TransactionDay.gregorianCalendar(
            basedOn: environmentCalendar,
            locale: locale
        )
        return date.formatted(
            Date.FormatStyle(
                date: .numeric,
                time: .omitted,
                locale: locale,
                calendar: calendar,
                timeZone: calendar.timeZone
            )
        )
    }
}

/// 搜索页顶部已提交的业务日范围摘要。
private struct AppliedSearchRangeView: View {
    /// 已提交的闭区间条件。
    let range: BookkeepingSearchDateRange

    /// 业务日使用的公历及时区。
    let calendar: Calendar

    /// 日期摘要使用的语言环境。
    let locale: Locale

    /// 清除已提交范围的操作。
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .accessibilityHidden(true)
            Text(summary)
                .font(.subheadline)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                onClear()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                Text(
                    AccountLocalization.string(
                        "bookkeeping.search.range.clear",
                        locale: locale
                    )
                )
            )
            .accessibilityIdentifier("bookkeeping-search-range-clear")
        }
        .padding(.horizontal, 16)
        .background(.thinMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bookkeeping-search-applied-range")
    }

    /// 当前已提交范围的本地化摘要。
    private var summary: String {
        let start = TransactionDay.date(from: range.startDay, calendar: calendar, locale: locale)
        let end = TransactionDay.date(from: range.endDay, calendar: calendar, locale: locale)
        guard let start, let end else { return "\(range.startDay)-\(range.endDay)" }
        let dateCalendar = TransactionDay.gregorianCalendar(basedOn: calendar, locale: locale)
        let format: Date.FormatStyle = Date.FormatStyle(
            date: .numeric,
            time: .omitted,
            locale: locale,
            calendar: dateCalendar,
            timeZone: dateCalendar.timeZone
        )
        return String(
            format: AccountLocalization.string(
                "bookkeeping.search.range.format",
                locale: locale
            ),
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
                    .font(.body.monospacedDigit())
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
        .padding(.vertical, 5)
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
