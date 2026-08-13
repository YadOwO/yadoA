import SwiftData
import SwiftUI
import UIKit

/// 金额优先的固定餐饮支出录入页。
struct DiningExpenseEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Query private var accounts: [Account]
    @FocusState private var focusedField: FocusedField?
    @StateObject private var flow: DiningExpenseEntryFlow
    @State private var isPresentingAccountSelection = false
    @State private var hasAccountCreationError = false

    /// 创建餐饮支出录入页。
    ///
    /// - Parameters:
    ///   - draft: 可选的既有草稿，默认创建以今天为日期的新草稿。
    ///   - save: 上层注入的本地餐饮支出保存动作。
    init(
        draft: DiningExpenseDraft? = nil,
        save: @escaping DiningExpenseSaveAction
    ) {
        _flow = StateObject(
            wrappedValue: DiningExpenseEntryFlow(
                draft: draft,
                saveAction: save
            )
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                categoryAndAmount
                accountSection
                detailSection
                inlineFeedback
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(AccountLocalization.string("expense.entry.title", locale: locale))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isPresentingAccountSelection) {
            NavigationStack {
                ExpenseAccountSelectionView(
                    onSelectAccount: { accountID in
                        hasAccountCreationError = false
                        flow.selectAccount(id: accountID)
                    },
                    onCreationFailed: {
                        hasAccountCreationError = true
                    }
                )
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .interactiveDismissDisabled(flow.isSaving)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if focusedField != .note {
                SimplifiedAmountKeypad(
                    isDoneEnabled: canSubmit,
                    isSaving: flow.isSaving,
                    onDigit: flow.appendDigit,
                    onDecimalPoint: flow.appendDecimalPoint,
                    onDelete: flow.deleteBackward
                ) {
                    Task {
                        await flow.submit {
                            provideSuccessFeedback()
                            dismiss()
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(AccountLocalization.string("common.done", locale: locale)) {
                    focusedField = nil
                }
            }
        }
    }

    /// 固定分类和主视觉金额。
    private var categoryAndAmount: some View {
        VStack(spacing: 14) {
            Label(
                AccountLocalization.string("expense.category.dining", locale: locale),
                systemImage: "fork.knife"
            )
            .font(.headline)
            .foregroundStyle(.tint)

            Text(flow.displayedAmount)
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.55)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 72)
                .contentShape(Rectangle())
                .onTapGesture {
                    focusedField = nil
                }
                .accessibilityLabel(
                    Text(AccountLocalization.string("expense.entry.amount", locale: locale))
                )
                .accessibilityValue(Text(verbatim: flow.displayedAmount))
        }
    }

    /// 当前账户摘要；点击后直接弹出账户选择框。
    private var accountSection: some View {
        Button {
            focusedField = nil
            hasAccountCreationError = false
            isPresentingAccountSelection = true
        } label: {
            HStack(spacing: 12) {
                if let account = selectedAccount {
                    let row = AccountListPresentation.row(for: account, locale: locale)
                    AccountIconView(presentation: row.icon)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                        Text(row.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 3) {
                        Text(row.formattedAmount)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.primary)
                        Text(row.amountLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(row.amountAccessibilityLabel)
                } else {
                    Label(
                        AccountLocalization.string(accountPlaceholderKey, locale: locale),
                        systemImage: "creditcard"
                    )
                    .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                }

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                Color.primary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("expense-entry-account")
    }

    /// 记账日期与可选备注输入。
    private var detailSection: some View {
        VStack(spacing: 0) {
            DatePicker(
                AccountLocalization.string("expense.entry.date", locale: locale),
                selection: Binding(
                    get: { flow.transactionDate },
                    set: flow.updateTransactionDate
                ),
                displayedComponents: .date
            )
            .frame(minHeight: 44)
            .accessibilityIdentifier("expense-entry-date")

            Divider()

            TextField(
                AccountLocalization.string("expense.entry.note.placeholder", locale: locale),
                text: Binding(
                    get: { flow.draft.note },
                    set: flow.updateNote
                ),
                axis: .vertical
            )
            .focused($focusedField, equals: .note)
            .lineLimit(1...4)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .accessibilityLabel(
                Text(AccountLocalization.string("expense.entry.note", locale: locale))
            )
            .accessibilityIdentifier("expense-entry-note")
        }
        .padding(.horizontal, 14)
        .background(
            Color.primary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    /// 不阻断保存的余额提醒，以及保留草稿后的失败反馈。
    @ViewBuilder
    private var inlineFeedback: some View {
        if showsInsufficientBalanceWarning {
            Label(
                AccountLocalization.string("expense.entry.insufficient_balance", locale: locale),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.footnote)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        if flow.hasSaveError {
            Label(
                AccountLocalization.string("expense.entry.save_failed", locale: locale),
                systemImage: "exclamationmark.circle.fill"
            )
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("expense-entry-save-error")
        }

        if hasAccountCreationError {
            Label(
                AccountLocalization.string(
                    "expense.entry.account_creation_failed",
                    locale: locale
                ),
                systemImage: "exclamationmark.circle.fill"
            )
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("expense-entry-account-creation-error")
        }
    }

    /// 草稿账户 UUID 当前解析出的持久账户。
    private var selectedAccount: Account? {
        guard let accountID = flow.draft.accountID else { return nil }
        return accounts.first { $0.id == accountID }
    }

    /// 未选择和已失效选择使用不同的本地化提示。
    private var accountPlaceholderKey: String {
        flow.draft.accountID == nil
            ? "expense.entry.account.select"
            : "expense.entry.account.unavailable"
    }

    /// 页面需同时确认所选账户仍然存在，仓库保存时还会再次校验。
    private var canSubmit: Bool {
        flow.canSubmit && selectedAccount != nil
    }

    /// 资产类账户预计扣减后为负时展示轻提醒，但不影响 `canSubmit`。
    private var showsInsufficientBalanceWarning: Bool {
        guard let account = selectedAccount,
              account.accountType?.expenseBalanceEffect == .decreaseValue,
              let amount = flow.draft.amount
        else { return false }

        return account.balance - amount < 0
    }

    /// 保存成功后提供系统触觉和 VoiceOver 可播报反馈，再返回首页。
    private func provideSuccessFeedback() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        UIAccessibility.post(
            notification: .announcement,
            argument: AccountLocalization.string(
                "expense.entry.save_succeeded",
                locale: locale
            )
        )
    }

    /// 当前仅备注输入使用系统键盘。
    private enum FocusedField: Hashable {
        case note
    }
}
