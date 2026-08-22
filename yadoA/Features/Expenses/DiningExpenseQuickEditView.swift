import SwiftUI
import UIKit

/// 首页单笔餐饮流水的快速修改页，只开放标题和金额两个字段。
struct DiningExpenseQuickEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @FocusState private var focusedField: FocusedField?
    @StateObject private var flow: DiningExpenseEditFlow

    /// 创建快速修改页面。
    ///
    /// - Parameters:
    ///   - draft: 首页点击时生成的流水编辑草稿。
    ///   - save: 上层注入的本地更新动作。
    init(
        draft: DiningExpenseEditDraft,
        save: @escaping DiningExpenseEditSaveAction
    ) {
        _flow = StateObject(
            wrappedValue: DiningExpenseEditFlow(
                draft: draft,
                saveAction: save
            )
        )
    }

    var body: some View {
        Form {
            Section {
                TextField(
                    AccountLocalization.string("expense.edit.title.placeholder", locale: locale),
                    text: Binding(
                        get: { flow.draft.title },
                        set: flow.updateTitle
                    )
                )
                .focused($focusedField, equals: .title)
                .textInputAutocapitalization(.sentences)
                .accessibilityLabel(
                    Text(AccountLocalization.string("expense.edit.title.field", locale: locale))
                )
                .accessibilityIdentifier("expense-edit-title")

                TextField(
                    AccountLocalization.string("expense.edit.amount", locale: locale),
                    text: Binding(
                        get: { flow.draft.amountText },
                        set: {
                            flow.updateAmountText(
                                $0,
                                decimalSeparator: locale.decimalSeparator ?? "."
                            )
                        }
                    )
                )
                .focused($focusedField, equals: .amount)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel(
                    Text(AccountLocalization.string("expense.edit.amount", locale: locale))
                )
                .accessibilityIdentifier("expense-edit-amount")
            }

            if flow.hasSaveError {
                Section {
                    Label(
                        AccountLocalization.string("expense.edit.save_failed", locale: locale),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("expense-edit-save-error")
                }
            }

            Section {
                Button {
                    focusedField = nil
                    Task {
                        await flow.submit {
                            provideSuccessFeedback()
                            dismiss()
                        }
                    }
                } label: {
                    HStack {
                        if flow.isSaving {
                            ProgressView()
                                .accessibilityHidden(true)
                        }
                        Text(
                            AccountLocalization.string(
                                flow.hasSaveError ? "common.retry" : "common.save",
                                locale: locale
                            )
                        )
                        .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(!flow.canSubmit)
                .accessibilityIdentifier("expense-edit-save")
            }
        }
        .navigationTitle(AccountLocalization.string("expense.edit.title", locale: locale))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(AccountLocalization.string("common.cancel", locale: locale)) {
                    dismiss()
                }
                .disabled(flow.isSaving)
            }

            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(AccountLocalization.string("common.done", locale: locale)) {
                    focusedField = nil
                }
            }
        }
        .interactiveDismissDisabled(flow.isSaving)
        .task {
            focusedField = .title
        }
    }

    /// 保存成功后提供系统触觉和 VoiceOver 播报反馈。
    private func provideSuccessFeedback() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        UIAccessibility.post(
            notification: .announcement,
            argument: AccountLocalization.string(
                "expense.edit.save_succeeded",
                locale: locale
            )
        )
    }

    /// 快速编辑页面内可唤起系统键盘的字段。
    private enum FocusedField: Hashable {
        case title
        case amount
    }
}
