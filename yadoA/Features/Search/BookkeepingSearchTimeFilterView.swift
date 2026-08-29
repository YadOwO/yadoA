import SwiftUI

/// 搜索页时间条件的独立草稿 Sheet。
struct BookkeepingSearchTimeFilterView: View {
    /// 筛选模式的本地化选择值。
    private enum SelectionMode: String, CaseIterable, Identifiable {
        case all
        case custom

        var id: Self { self }
    }

    @Environment(\.locale) private var locale

    /// DatePicker 使用的业务日公历。
    private let calendar: Calendar

    /// 筛选 Sheet 关闭回调。
    private let onCancel: () -> Void

    /// 筛选确认回调。
    private let onConfirm: (BookkeepingSearchTimeFilter) -> Void

    /// Sheet 内尚未提交的筛选模式。
    @State private var selectionMode: SelectionMode

    /// 自定义范围的起始日期草稿。
    @State private var startDate: Date

    /// 自定义范围的结束日期草稿。
    @State private var endDate: Date

    /// 从已提交条件创建独立可取消的日期草稿。
    init(
        initialFilter: BookkeepingSearchTimeFilter,
        calendar: Calendar,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (BookkeepingSearchTimeFilter) -> Void
    ) {
        self.calendar = TransactionDay.gregorianCalendar(basedOn: calendar)
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        switch initialFilter {
        case .all:
            _selectionMode = State(initialValue: .all)
            let today = Self.today(calendar: self.calendar)
            _startDate = State(initialValue: today)
            _endDate = State(initialValue: today)
        case let .custom(range):
            _selectionMode = State(initialValue: .custom)
            let start = TransactionDay.date(
                from: range.startDay,
                calendar: self.calendar
            ) ?? Self.today(calendar: self.calendar)
            let end = TransactionDay.date(
                from: range.endDay,
                calendar: self.calendar
            ) ?? start
            _startDate = State(initialValue: start)
            _endDate = State(initialValue: end)
        }
    }

    var body: some View {
        Form {
            Section {
                Picker(
                    AccountLocalization.string(
                        "bookkeeping.search.filter.mode",
                        locale: locale
                    ),
                    selection: $selectionMode
                ) {
                    Text(
                        AccountLocalization.string(
                            "bookkeeping.search.filter.all",
                            locale: locale
                        )
                    )
                    .tag(SelectionMode.all)
                    Text(
                        AccountLocalization.string(
                            "bookkeeping.search.filter.custom",
                            locale: locale
                        )
                    )
                    .tag(SelectionMode.custom)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("bookkeeping-search-filter-mode")
                .onChange(of: selectionMode) { oldValue, newValue in
                    guard oldValue == .all, newValue == .custom else { return }
                    let today = Self.today(calendar: calendar)
                    startDate = today
                    endDate = today
                }
            }

            if selectionMode == .custom {
                Section {
                    DatePicker(
                        AccountLocalization.string(
                            "bookkeeping.search.filter.start",
                            locale: locale
                        ),
                        selection: $startDate,
                        displayedComponents: .date
                    )
                    .accessibilityIdentifier("bookkeeping-search-filter-start")

                    DatePicker(
                        AccountLocalization.string(
                            "bookkeeping.search.filter.end",
                            locale: locale
                        ),
                        selection: $endDate,
                        displayedComponents: .date
                    )
                    .accessibilityIdentifier("bookkeeping-search-filter-end")

                    if let rangeError {
                        Text(rangeError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("bookkeeping-search-filter-error")
                    }
                }
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

    /// 当前草稿可提交时生成搜索条件，否则保持确认按钮禁用。
    private var filter: BookkeepingSearchTimeFilter? {
        switch selectionMode {
        case .all:
            return .all
        case .custom:
            guard let range = BookkeepingSearchDateRange(
                startDay: TransactionDay.encode(startDate, calendar: calendar),
                endDay: TransactionDay.encode(endDate, calendar: calendar)
            ) else {
                return nil
            }
            return .custom(range)
        }
    }

    /// 反向业务日范围的本地化错误说明。
    private var rangeError: String? {
        guard selectionMode == .custom, filter == nil else { return nil }
        return AccountLocalization.string(
            "bookkeeping.search.filter.invalid_range",
            locale: locale
        )
    }

    /// 取得当前时区下的当天零点，供首次进入自定义模式使用。
    private static func today(calendar: Calendar) -> Date {
        calendar.startOfDay(for: Date())
    }
}
