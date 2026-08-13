import SwiftUI

/// 仅支持金额字符输入的简化键盘，不提供加减计算。
struct SimplifiedAmountKeypad: View {
    @Environment(\.locale) private var locale

    /// 当前是否允许完成记账。
    let isDoneEnabled: Bool

    /// 保存进行中时仅让完成键展示轻量进度并阻止重复提交。
    let isSaving: Bool

    /// 数字键回调。
    let onDigit: (Int) -> Void

    /// 小数点回调。
    let onDecimalPoint: () -> Void

    /// 删除键回调。
    let onDelete: () -> Void

    /// 完成键回调。
    let onDone: () -> Void

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 10),
        count: 3
    )

    var body: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach([7, 8, 9, 4, 5, 6, 1, 2, 3], id: \.self) { digit in
                    keypadButton {
                        Text(verbatim: String(digit))
                            .font(.title2.monospacedDigit())
                    } action: {
                        onDigit(digit)
                    }
                    .accessibilityLabel(Text(verbatim: String(digit)))
                    .accessibilityIdentifier("expense-keypad-\(digit)")
                }

                keypadButton {
                    Text(verbatim: ".")
                        .font(.title2)
                } action: {
                    onDecimalPoint()
                }
                .accessibilityLabel(
                    Text(AccountLocalization.string("expense.keypad.decimal", locale: locale))
                )
                .accessibilityIdentifier("expense-keypad-decimal")

                keypadButton {
                    Text(verbatim: "0")
                        .font(.title2.monospacedDigit())
                } action: {
                    onDigit(0)
                }
                .accessibilityLabel(Text(verbatim: "0"))
                .accessibilityIdentifier("expense-keypad-0")

                keypadButton {
                    Image(systemName: "delete.left")
                        .font(.title3)
                } action: {
                    onDelete()
                }
                .accessibilityLabel(
                    Text(AccountLocalization.string("expense.keypad.delete", locale: locale))
                )
                .accessibilityIdentifier("expense-keypad-delete")
            }

            Button(action: onDone) {
                HStack(spacing: 8) {
                    if isSaving {
                        ProgressView()
                    }
                    Text(AccountLocalization.string("common.done", locale: locale))
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isDoneEnabled || isSaving)
            .accessibilityIdentifier("expense-keypad-done")
        }
        .padding(12)
        .background(.regularMaterial)
    }

    /// 统一数字、小数点和删除键的尺寸与动态外观。
    private func keypadButton<Label: View>(
        @ViewBuilder label: () -> Label,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity, minHeight: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            Color.primary.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}
