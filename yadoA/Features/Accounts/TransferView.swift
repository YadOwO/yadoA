import SwiftData
import SwiftUI
import UIKit

/// 账户之间转账的表单：选转出、转入账户，填金额、日期和备注，一次保存同时更新两边余额。
struct TransferView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @FocusState private var focusedField: FocusedField?
    @AccessibilityFocusState private var isSaveErrorFocused: Bool
    @Query private var queriedAccounts: [Account]
    @StateObject private var flow: TransferFlow
    /// 正在选择账户的那一行（「转出」或「转入」的本地化键）；为空时不弹出账户列表。
    @State private var pickingTitleKey: String?

    /// 仅在转账保存成功后交由上层关闭表单并刷新。
    private let onSaved: @MainActor () -> Void

    /// 创建转账表单。
    ///
    /// - Parameters:
    ///   - draft: 预选好账户的草稿；从账户详情进入时当前账户是转出账户。
    ///   - save: 原子保存转账和两边余额的动作。
    ///   - onSaved: 保存成功后的关闭与刷新动作。
    init(
        draft: TransferDraft,
        save: @escaping TransferSaveAction,
        onSaved: @escaping @MainActor () -> Void
    ) {
        self.onSaved = onSaved
        _flow = StateObject(wrappedValue: TransferFlow(draft: draft, saveAction: save))
    }

    var body: some View {
        let accounts = Self.transferableAccounts(queriedAccounts)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                accountsCard(accounts)
                detailsCard
                inlineFeedback
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(text("account.transfer.title"))
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(flow.isSaving)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            LedgerSubmitButton(
                title: text(flow.hasSaveError ? "common.retry" : "common.save"),
                isSaving: flow.isSaving,
                action: submit
            )
            .disabled(!flow.canSubmit)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
            .background(Color(.paperBackground))
            .accessibilityIdentifier("transfer-save")
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(text("common.cancel")) {
                    dismiss()
                }
                .disabled(flow.isSaving)
                .accessibilityIdentifier("transfer-cancel")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(text("common.done")) {
                    focusedField = nil
                }
            }
        }
        .task {
            focusedField = .amount
        }
        .paperPage()
    }

    /// 只有启用中、可记账的账户能参与转账；顺序与账户列表一致。
    static func transferableAccounts(_ accounts: [Account]) -> [Account] {
        AccountListPresentation.sorted(accounts).filter(\.supportsBookkeeping)
    }

    // MARK: - 账户

    /// 转出、转入两行账户和中间的交换按钮。
    private func accountsCard(_ accounts: [Account]) -> some View {
        VStack(spacing: 0) {
            accountRow(
                titleKey: "account.transfer.from",
                selectedID: flow.draft.fromAccountID,
                accounts: accounts,
                identifier: "transfer-from",
                select: flow.selectFromAccount
            )

            ZStack {
                HandDrawnRule(seed: 141)
                    .stroke(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                    .frame(height: 3)
                    .padding(.horizontal, 20)
                    .accessibilityHidden(true)
                Button {
                    flow.swapAccounts()
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .background(Color(.paperBackground), in: Circle())
                        .overlay {
                            HandDrawnBlob(seed: 142)
                                .stroke(Color.primary.opacity(0.4), lineWidth: 1)
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(flow.isSaving)
                .accessibilityLabel(text("account.transfer.swap"))
                .accessibilityIdentifier("transfer-swap")
            }

            accountRow(
                titleKey: "account.transfer.to",
                selectedID: flow.draft.toAccountID,
                accounts: accounts,
                identifier: "transfer-to",
                select: flow.selectToAccount
            )
        }
        .ledgerFormBorder(seed: 140)
    }

    /// 一行账户选择：左边是「转出 / 转入」，右边是所选账户的图标、名称和余额，点开弹出账户列表换账户。
    private func accountRow(
        titleKey: String,
        selectedID: UUID?,
        accounts: [Account],
        identifier: String,
        select: @escaping @MainActor (UUID) -> Void
    ) -> some View {
        let selected = accounts.first { $0.id == selectedID }
        let presentation = selected.map { AccountListPresentation.row(for: $0, locale: locale) }

        return Button {
            focusedField = nil
            pickingTitleKey = titleKey
        } label: {
            HStack(spacing: 12) {
                Text(text(titleKey))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let presentation {
                    AccountIconView(presentation: presentation.icon)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(presentation.name)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(presentation.formattedAmount)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(text("account.transfer.select_account"))
                        .foregroundStyle(.tint)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .ledgerCardRow()
        }
        .buttonStyle(.plain)
        .disabled(flow.isSaving)
        .accessibilityIdentifier(identifier)
        // 系统菜单只能排一行文字，账户图标和右对齐的余额需要自绘；iPhone 上也保持贴着这一行弹出。
        .popover(
            isPresented: Binding(
                get: { pickingTitleKey == titleKey },
                set: { if !$0, pickingTitleKey == titleKey { pickingTitleKey = nil } }
            ),
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .top
        ) {
            TransferAccountPicker(accounts: accounts, selectedID: selectedID) { accountID in
                select(accountID)
                pickingTitleKey = nil
            }
            .presentationCompactAdaptation(.popover)
            .presentationBackground(Color(.paperBackground))
        }
    }

    // MARK: - 金额、日期与备注

    /// 金额写在横线上，下面是日期和备注。
    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(text("account.transfer.amount"))
                .font(.system(.headline, design: .serif))

            TextField(
                text("account.transfer.amount"),
                text: Binding(
                    get: { flow.draft.amountText },
                    set: {
                        isSaveErrorFocused = false
                        flow.updateAmountText($0, decimalSeparator: locale.decimalSeparator ?? ".")
                    }
                ),
                prompt: Text(verbatim: "0")
            )
            .font(.system(.largeTitle, design: .serif, weight: .medium))
            .monospacedDigit()
            .keyboardType(.decimalPad)
            .focused($focusedField, equals: .amount)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.55)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 56)
            .accessibilityIdentifier("transfer-amount")

            HandDrawnRule(seed: 143)
                .stroke(Color.primary.opacity(0.6), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                .frame(height: 3)
                .accessibilityHidden(true)

            DatePicker(
                selection: Binding(
                    get: { transactionDate },
                    set: { flow.updateTransactionDay(TransactionDay.encode($0, calendar: calendar)) }
                ),
                displayedComponents: .date
            ) {
                Text(text("expense.entry.date"))
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
            .disabled(flow.isSaving)
            .accessibilityIdentifier("transfer-date")

            TextField(
                text("account.transfer.note.placeholder"),
                text: Binding(
                    get: { flow.draft.note },
                    set: {
                        isSaveErrorFocused = false
                        flow.updateNote($0)
                    }
                ),
                axis: .vertical
            )
            .focused($focusedField, equals: .note)
            .lineLimit(1...4)
            .frame(minHeight: 44)
            .accessibilityIdentifier("transfer-note")
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ledgerFormBorder(seed: 144)
    }

    /// 草稿记账日对应的日期；无法解析时退回今天。
    private var transactionDate: Date {
        TransactionDay.date(from: flow.draft.transactionDay, calendar: calendar, locale: locale) ?? .now
    }

    /// 保存失败后保留草稿，并把 VoiceOver 焦点移到错误提示。
    @ViewBuilder
    private var inlineFeedback: some View {
        if flow.hasSaveError {
            Label(text("account.transfer.save_failed"), systemImage: "exclamationmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(Color(.ledgerRed))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityFocused($isSaveErrorFocused)
                .accessibilityIdentifier("transfer-save-error")
        }
    }

    // MARK: - 提交

    /// 提交草稿；成功后给触感和播报，失败后把焦点移到错误提示。
    private func submit() {
        focusedField = nil
        Task {
            await flow.submit {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                UIAccessibility.post(notification: .announcement, argument: text("account.transfer.save_succeeded"))
                onSaved()
            }
            if flow.hasSaveError {
                await Task.yield()
                isSaveErrorFocused = true
                UIAccessibility.post(notification: .announcement, argument: text("account.transfer.save_failed"))
            }
        }
    }

    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }

    /// 表单内可唤起系统键盘的输入区域。
    private enum FocusedField: Hashable {
        case amount
        case note
    }
}

/// 转账表单里弹出的账户列表：每行是账户图标、名称和右对齐的余额，当前选中的打勾。
private struct TransferAccountPicker: View {
    @Environment(\.locale) private var locale

    /// 可参与转账的账户，顺序与账户列表一致。
    let accounts: [Account]

    /// 这一行当前选中的账户。
    let selectedID: UUID?

    /// 选中某个账户。
    let onSelect: (UUID) -> Void

    var body: some View {
        // 账户不多时按内容高度弹出；放不下时才在弹层里滚动。
        ViewThatFits(in: .vertical) {
            list
            ScrollView {
                list
            }
        }
        .frame(minWidth: 300, idealWidth: 320)
    }

    /// 全部账户行。
    private var list: some View {
        VStack(spacing: 0) {
            ForEach(accounts) { account in
                option(for: account)
            }
        }
        .padding(.vertical, 6)
    }

    /// 一个账户选项。
    private func option(for account: Account) -> some View {
        let row = AccountListPresentation.row(for: account, locale: locale)
        let isSelected = account.id == selectedID
        return Button {
            onSelect(account.id)
        } label: {
            HStack(spacing: 12) {
                AccountIconView(presentation: row.icon)
                Text(row.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 16)
                Text(row.formattedAmount)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // 不论是否选中都占住勾的位置，余额才能上下对齐。
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tint)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("transfer-account-option-\(account.id.uuidString)")
    }
}
