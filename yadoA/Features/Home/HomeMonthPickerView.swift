import SwiftUI

/// 首页月份选择 Sheet，允许选择任意可表达的自然月。
struct HomeMonthPickerView: View {
    @Environment(\.locale) private var locale

    /// 月份选择器覆盖的公历年份范围，避免一次加载过大的滚轮数据集。
    private static let yearRange = 1900...2100

    /// 当前 Sheet 内临时选择的年份。
    @State private var selectedYear: Int

    /// 当前 Sheet 内临时选择的月份。
    @State private var selectedMonth: Int

    /// 取消按钮行为；不提交临时月份。
    let onCancel: () -> Void

    /// 确定按钮行为；只提交选中的年月。
    let onConfirm: (HomeMonth) -> Void

    init(
        initialMonth: HomeMonth,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (HomeMonth) -> Void
    ) {
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _selectedYear = State(initialValue: initialMonth.year)
        _selectedMonth = State(initialValue: initialMonth.month)
    }

    var body: some View {
        HStack(spacing: 0) {
            Picker("", selection: $selectedYear) {
                ForEach(Self.yearRange, id: \.self) { year in
                    Text(year.formatted(.number.locale(locale)))
                        .tag(year)
                }
            }

            Picker("", selection: $selectedMonth) {
                ForEach(1...12, id: \.self) { month in
                    Text(month.formatted(.number.locale(locale)))
                        .tag(month)
                }
            }
        }
        .pickerStyle(.wheel)
        .labelsHidden()
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
                    guard let month = HomeMonth(year: selectedYear, month: selectedMonth) else {
                        return
                    }
                    onConfirm(month)
                }
                .accessibilityIdentifier("home-month-picker-confirm")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
