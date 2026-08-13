import SwiftUI
import UIKit

/// 首页月份选择 Sheet，允许选择任意可表达的自然月。
struct HomeMonthPickerView: View {
    @Environment(\.locale) private var locale

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
        HomeMonthWheelPicker(
            year: $selectedYear,
            month: $selectedMonth,
            locale: locale
        )
        .frame(maxWidth: .infinity)
        .frame(height: 216)
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

/// 只显示年、月两列的原生滚轮选择器；年份按需渲染，支持全部有效公历年份。
private struct HomeMonthWheelPicker: UIViewRepresentable {
    /// 当前选中的年份。
    @Binding var year: Int

    /// 当前选中的月份。
    @Binding var month: Int

    /// 滚轮文本使用的语言环境。
    let locale: Locale

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UIPickerView {
        let picker = UIPickerView()
        picker.dataSource = context.coordinator
        picker.delegate = context.coordinator
        picker.selectRow(year - 1, inComponent: 0, animated: false)
        picker.selectRow(month - 1, inComponent: 1, animated: false)
        return picker
    }

    func updateUIView(_ picker: UIPickerView, context: Context) {
        context.coordinator.parent = self

        if picker.selectedRow(inComponent: 0) != year - 1 {
            picker.selectRow(year - 1, inComponent: 0, animated: false)
        }
        if picker.selectedRow(inComponent: 1) != month - 1 {
            picker.selectRow(month - 1, inComponent: 1, animated: false)
        }
    }

    /// 将 UIKit 滚轮事件同步回 SwiftUI 状态。
    final class Coordinator: NSObject, UIPickerViewDataSource, UIPickerViewDelegate {
        /// 当前 representable 的最新值。
        var parent: HomeMonthWheelPicker

        init(_ parent: HomeMonthWheelPicker) {
            self.parent = parent
        }

        func numberOfComponents(in _: UIPickerView) -> Int { 2 }

        func pickerView(_: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
            component == 0 ? 9_999 : 12
        }

        func pickerView(
            _: UIPickerView,
            titleForRow row: Int,
            forComponent _: Int
        ) -> String? {
            (row + 1).formatted(.number.locale(parent.locale))
        }

        func pickerView(
            _: UIPickerView,
            didSelectRow row: Int,
            inComponent component: Int
        ) {
            if component == 0 {
                parent.year = row + 1
            } else {
                parent.month = row + 1
            }
        }
    }
}
