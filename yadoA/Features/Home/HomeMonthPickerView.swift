import SwiftUI

/// 首页月份选择 Sheet，允许选择任意可表达的自然月。
struct HomeMonthPickerView: View {
    @Environment(\.locale) private var locale

    /// 用于把年月转换为日期的日历。
    private let calendar: Calendar

    /// 打开 Sheet 时已提交的月份。
    private let initialMonth: HomeMonth

    /// 当前 Sheet 内的临时日期值。
    @State private var selectedDate: Date

    /// 取消按钮行为；不提交临时月份。
    let onCancel: () -> Void

    /// 确定按钮行为；只提交选中的年月。
    let onConfirm: (HomeMonth) -> Void

    init(
        initialMonth: HomeMonth,
        calendar sourceCalendar: Calendar = .current,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (HomeMonth) -> Void
    ) {
        self.initialMonth = initialMonth
        self.calendar = TransactionDay.gregorianCalendar(basedOn: sourceCalendar)
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _selectedDate = State(
            initialValue: initialMonth.firstDate(calendar: sourceCalendar) ?? .now
        )
    }

    var body: some View {
        DatePicker(
            AccountLocalization.string("home.month.picker.title", locale: locale),
            selection: $selectedDate,
            displayedComponents: .date
        )
        .datePickerStyle(.wheel)
        .labelsHidden()
        .environment(\.calendar, calendar)
        .environment(\.locale, locale)
        .accessibilityIdentifier("home-month-picker")
        .navigationTitle(AccountLocalization.string("home.month.picker.title", locale: locale))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(AccountLocalization.string("common.cancel", locale: locale)) {
                    onCancel()
                }
                .accessibilityIdentifier("home-month-picker-cancel")
            }

            ToolbarItem(placement: .confirmationAction) {
                Button(AccountLocalization.string("common.done", locale: locale)) {
                    guard let month = HomeMonth.from(
                        date: selectedDate,
                        calendar: calendar,
                        locale: locale
                    ) else {
                        onCancel()
                        return
                    }
                    onConfirm(month)
                }
                .accessibilityIdentifier("home-month-picker-confirm")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            // 让系统辅助功能始终能读到当前 draft 的月份，而不是读取旧的日期列。
            selectedDate = initialMonth.firstDate(calendar: calendar) ?? selectedDate
        }
    }
}
