import SwiftUI

/// 搜索页日期范围的独立草稿 Sheet。
///
/// 打开就是起止两个日期，确认即按这段范围筛选；"不限时间"不再是一个需要选的模式，
/// 而是已有筛选时页面下方的"清除"动作。
struct BookkeepingSearchTimeFilterView: View {
    @Environment(\.locale) private var locale

    /// DatePicker 使用的业务日公历。
    private let calendar: Calendar

    /// 打开时是否已有生效的日期范围，决定是否提供清除入口。
    private let hasAppliedRange: Bool

    /// 筛选 Sheet 关闭回调。
    private let onCancel: () -> Void

    /// 筛选确认回调。
    private let onConfirm: (BookkeepingSearchTimeFilter) -> Void

    /// 范围的起始日期草稿。
    @State private var startDate: Date

    /// 范围的结束日期草稿。
    @State private var endDate: Date

    /// 从已提交条件创建独立可取消的日期草稿；尚未筛选时默认填入本月初到今天。
    init(
        initialFilter: BookkeepingSearchTimeFilter,
        calendar: Calendar,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (BookkeepingSearchTimeFilter) -> Void
    ) {
        self.calendar = TransactionDay.gregorianCalendar(basedOn: calendar)
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        let today = self.calendar.startOfDay(for: Date())
        switch initialFilter {
        case .all:
            hasAppliedRange = false
            let monthStart = self.calendar.dateInterval(of: .month, for: today)?.start ?? today
            _startDate = State(initialValue: monthStart)
            _endDate = State(initialValue: today)
        case let .custom(range):
            hasAppliedRange = true
            let start = TransactionDay.date(
                from: range.startDay,
                calendar: self.calendar
            ) ?? today
            let end = TransactionDay.date(
                from: range.endDay,
                calendar: self.calendar
            ) ?? start
            _startDate = State(initialValue: start)
            _endDate = State(initialValue: end)
        }
    }

    var body: some View {
        LedgerFormPage {
            LedgerCard(seed: 123) {
                DatePicker(
                    selection: $startDate,
                    displayedComponents: .date
                ) {
                    Text(AccountLocalization.string("bookkeeping.search.filter.start", locale: locale))
                        .foregroundStyle(.secondary)
                }
                .ledgerCardRow()
                .accessibilityIdentifier("bookkeeping-search-filter-start")

                DatePicker(
                    selection: $endDate,
                    displayedComponents: .date
                ) {
                    Text(AccountLocalization.string("bookkeeping.search.filter.end", locale: locale))
                        .foregroundStyle(.secondary)
                }
                .ledgerCardRow()
                .accessibilityIdentifier("bookkeeping-search-filter-end")
            }
            // 起止颠倒时把另一头带过去，范围始终有效，不需要报错。
            .onChange(of: startDate) { _, newValue in
                if newValue > endDate { endDate = newValue }
            }
            .onChange(of: endDate) { _, newValue in
                if newValue < startDate { startDate = newValue }
            }

            Text(AccountLocalization.string("bookkeeping.search.filter.hint", locale: locale))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            if hasAppliedRange {
                Button(AccountLocalization.string("bookkeeping.search.range.clear", locale: locale)) {
                    onConfirm(.all)
                }
                .foregroundStyle(Color(.ledgerRed))
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("bookkeeping-search-filter-clear")
            }
        }
        .navigationTitle(
            AccountLocalization.string(
                "bookkeeping.search.filter.title",
                locale: locale
            )
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(
                    AccountLocalization.string(
                        "bookkeeping.search.filter.cancel",
                        locale: locale
                    ),
                    action: onCancel
                )
                .accessibilityIdentifier("bookkeeping-search-filter-cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(
                    AccountLocalization.string(
                        "bookkeeping.search.filter.apply",
                        locale: locale
                    )
                ) {
                    guard let filter else { return }
                    onConfirm(filter)
                }
                .disabled(filter == nil)
                .accessibilityIdentifier("bookkeeping-search-filter-confirm")
            }
        }
    }

    /// 当前草稿对应的搜索条件；起止颠倒的瞬间返回 `nil`，确认按钮保持禁用。
    private var filter: BookkeepingSearchTimeFilter? {
        BookkeepingSearchDateRange(
            startDay: TransactionDay.encode(startDate, calendar: calendar),
            endDay: TransactionDay.encode(endDate, calendar: calendar)
        ).map(BookkeepingSearchTimeFilter.custom)
    }
}
