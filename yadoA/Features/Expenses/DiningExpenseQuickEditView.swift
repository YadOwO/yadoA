import SwiftData
import SwiftUI
import UIKit

/// 共用的完整收支编辑表单，沿用系统 Picker、日期选择与金额输入。
struct DiningExpenseQuickEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Query private var accounts: [Account]
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
        let availableAccounts = AccountListPresentation.sorted(accounts).filter {
            $0.supportsBookkeeping && $0.currencyCode == "CNY"
        }
        let hasAvailableAccount = availableAccounts.contains { $0.id == flow.draft.accountID }

        Form {
            Section {
                Picker(text("bookkeeping.entry.type"), selection: binding(\.entryType)) {
                    ForEach(BookkeepingEntryType.allCases) { type in
                        Text(type.localizedTitle(locale: locale)).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("expense-edit-type")

                categoryPicker

                LabeledContent(text("expense.edit.title.field")) {
                    TextField(text("expense.edit.title.field"), text: binding(\.title))
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("expense-edit-title")
                }

                LabeledContent(text("expense.edit.amount")) {
                    TextField(text("expense.edit.amount"), text: Binding(
                        get: { flow.draft.amountText },
                        set: { flow.updateAmountText($0, decimalSeparator: locale.decimalSeparator ?? ".") }
                    ))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("expense-edit-amount")
                }
            }

            Section {
                Picker(text("bookkeeping.search.detail.account"), selection: binding(\.accountID)) {
                    ForEach(availableAccounts) { account in
                        Text(account.name).tag(account.id)
                    }
                }
                .pickerStyle(.navigationLink)
                .accessibilityIdentifier("expense-edit-account")

                DatePicker(text("expense.entry.date"), selection: transactionDate, displayedComponents: .date)
                    .accessibilityIdentifier("expense-edit-date")

                TextField(text("expense.entry.note"), text: binding(\.note), axis: .vertical)
                    .lineLimit(2...5)
                    .accessibilityIdentifier("expense-edit-note")
            } footer: {
                Text(text("bookkeeping.edit.balance_hint"))
            }

            if !hasAvailableAccount {
                Section {
                    Label(text("bookkeeping.edit.account_unavailable"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }

            if flow.hasSaveError {
                Section {
                    Label(text("expense.edit.save_failed"), systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("expense-edit-save-error")
                }
            }
        }
        .disabled(flow.isSaving)
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
            ToolbarItem(placement: .confirmationAction) {
                Button(text(flow.hasSaveError ? "common.retry" : "common.save")) {
                    Task {
                        await flow.submit {
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            UIAccessibility.post(
                                notification: .announcement,
                                argument: text("expense.edit.save_succeeded")
                            )
                            dismiss()
                        }
                    }
                }
                .disabled(!flow.canSubmit || !hasAvailableAccount)
                .accessibilityIdentifier("expense-edit-save")
            }
        }
        .interactiveDismissDisabled(flow.isSaving || flow.draft != originalDraft)
        .confirmationDialog(text("bookkeeping.edit.discard.title"), isPresented: $isDiscardConfirmationPresented) {
            Button(text("bookkeeping.edit.discard.action"), role: .destructive) { dismiss() }
            Button(text("common.cancel"), role: .cancel) {}
        }
    }

    /// 按方向展示对应分类，保留另一方向的上次草稿选择。
    @ViewBuilder
    private var categoryPicker: some View {
        if flow.draft.entryType == .expense {
            Picker(text("bookkeeping.search.detail.category"), selection: binding(\.category)) {
                ForEach(ExpenseCategory.allCases) { category in
                    Text(category.localizedTitle(locale: locale)).tag(category)
                }
            }
            .accessibilityIdentifier("expense-edit-category")
        } else {
            Picker(text("bookkeeping.search.detail.category"), selection: binding(\.incomeCategory)) {
                ForEach(IncomeCategory.allCases) { category in
                    Text(category.localizedTitle(locale: locale)).tag(category)
                }
            }
            .accessibilityIdentifier("expense-edit-category")
        }
    }

    /// 表单字段统一通过流程写入，提交期间不能修改已复制的草稿。
    private func binding<Value>(_ keyPath: WritableKeyPath<DiningExpenseEditDraft, Value>) -> Binding<Value> {
        Binding(
            get: { flow.draft[keyPath: keyPath] },
            set: { value in flow.update { $0[keyPath: keyPath] = value } }
        )
    }

    /// 业务日与系统日期选择器互转，保持当前时区下的公历日期。
    private var transactionDate: Binding<Date> {
        Binding(
            get: { TransactionDay.date(from: flow.draft.transactionDay, calendar: calendar, locale: locale) ?? .now },
            set: { date in flow.update { $0.transactionDay = TransactionDay.encode(date, calendar: calendar) } }
        )
    }

    /// 按当前应用语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}
