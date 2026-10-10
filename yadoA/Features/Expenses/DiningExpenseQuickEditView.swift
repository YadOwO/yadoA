import SwiftUI

/// 编辑记账入口：持有已有流水的草稿，页面本身与新增记账共用 `BookkeepingEntryForm`。
struct DiningExpenseQuickEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @StateObject private var flow: DiningExpenseEditFlow
    @State private var isDiscardConfirmationPresented = false

    /// 打开时的草稿，仅用于判断是否存在未保存修改。
    private let originalDraft: DiningExpenseEditDraft

    /// 创建独立的编辑草稿和可测试保存动作。
    init(draft: DiningExpenseEditDraft, save: @escaping DiningExpenseEditSaveAction) {
        originalDraft = draft
        _flow = StateObject(wrappedValue: DiningExpenseEditFlow(draft: draft, saveAction: save))
    }

    var body: some View {
        BookkeepingEntryForm(flow: flow, configuration: .edit) {
            dismiss()
        }
        .navigationTitle(text("expense.edit.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(text("common.cancel")) {
                    if flow.draft != originalDraft {
                        isDiscardConfirmationPresented = true
                    } else {
                        dismiss()
                    }
                }
                .disabled(flow.isSaving)
                .accessibilityIdentifier("expense-edit-cancel")
            }
        }
        .interactiveDismissDisabled(flow.isSaving || flow.draft != originalDraft)
        .confirmationDialog(text("bookkeeping.edit.discard.title"), isPresented: $isDiscardConfirmationPresented) {
            Button(text("bookkeeping.edit.discard.action"), role: .destructive) { dismiss() }
            Button(text("common.cancel"), role: .cancel) {}
        }
    }

    /// 按当前应用语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}
