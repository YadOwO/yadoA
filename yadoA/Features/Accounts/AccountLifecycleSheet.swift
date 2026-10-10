import SwiftUI

/// 账户删除/停用的最终确认界面。
struct AccountLifecycleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var replacementAccountID: UUID?
    @State private var allowsNoDefault = false
    @StateObject private var flow: AccountLifecycleFlow

    /// 当前预检快照；提交时仓库会重新读取并验证。
    let plan: AccountDisposalPlan

    /// 提交成功后的上层刷新动作。
    let onSaved: @MainActor () -> Void

    /// 最终状态漂移后的上层清理动作。
    let onNeedsRefresh: @MainActor () -> Void

    /// 创建生命周期确认页。
    init(
        plan: AccountDisposalPlan,
        save: @escaping AccountLifecycleSaveAction,
        onSaved: @escaping @MainActor () -> Void,
        onNeedsRefresh: @escaping @MainActor () -> Void = {}
    ) {
        self.plan = plan
        self.onSaved = onSaved
        self.onNeedsRefresh = onNeedsRefresh
        let action: AccountDisposalAction = plan.canPermanentlyDelete ? .delete : .deactivate
        _flow = StateObject(
            wrappedValue: AccountLifecycleFlow(
                expectation: AccountDisposalExpectation(
                    accountID: plan.accountID,
                    action: action,
                    expectedDefaultAccountID: plan.defaultAccountID,
                    replacementAccountID: nil,
                    allowsNoDefault: false
                ),
                saveAction: save
            )
        )
    }

    var body: some View {
        LedgerFormPage {
            LedgerCard(seed: 115) {
                LedgerFormRow(title: text("account.lifecycle.account")) {
                    Text(plan.accountName)
                }

                if plan.balance != .zero {
                    LedgerFormRow(title: text("account.lifecycle.current_balance")) {
                        Text(plan.balance.formatted(.currency(code: "CNY").locale(locale)))
                            .font(.system(.body, design: .serif))
                            .monospacedDigit()
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        text(plan.canPermanentlyDelete ? "account.lifecycle.delete" : "account.lifecycle.deactivate"),
                        systemImage: plan.canPermanentlyDelete ? "trash" : "pause.circle"
                    )
                    .font(.system(.headline, design: .serif))

                    Text(
                        plan.canPermanentlyDelete
                            ? text("account.lifecycle.delete_warning")
                            : plan.canDeactivate
                                ? text("account.lifecycle.deactivate_warning")
                                : text("account.lifecycle.deactivate_blocked")
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .ledgerCardRow()
            }

            if plan.isCurrentDefault {
                LedgerCard(seed: 116) {
                    if plan.replacementCandidates.isEmpty {
                        Toggle(text("account.lifecycle.confirm_no_default"), isOn: $allowsNoDefault)
                            .ledgerCardRow()
                            .accessibilityIdentifier("account-lifecycle-no-default")
                            .onChange(of: allowsNoDefault) { _, value in
                                flow.update(
                                    replacementAccountID: replacementAccountID,
                                    allowsNoDefault: value
                                )
                            }
                    } else {
                        Text(text("account.lifecycle.choose_replacement"))
                            .font(.system(.subheadline, design: .serif, weight: .semibold))
                            .ledgerCardRow()

                        ForEach(plan.replacementCandidates) { candidate in
                            Button {
                                replacementAccountID = candidate.id
                                flow.update(
                                    replacementAccountID: candidate.id,
                                    allowsNoDefault: false
                                )
                            } label: {
                                HStack {
                                    Text(candidate.name)
                                    Spacer()
                                    if replacementAccountID == candidate.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                                .ledgerCardRow()
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(replacementAccountID == candidate.id ? .isSelected : [])
                            .accessibilityIdentifier("account-lifecycle-replacement-\(candidate.id.uuidString)")
                        }
                    }
                }
            }

            if let error = flow.lastError {
                Label(
                    text(error.isStateChanged ? "account.lifecycle.state_changed" : "account.lifecycle.save_error"),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(Color(.ledgerRed))
                .accessibilityIdentifier("account-lifecycle-error")
            }

            LedgerSubmitButton(title: text("common.confirm"), isSaving: flow.isSaving) {
                flow.update(
                    replacementAccountID: replacementAccountID,
                    allowsNoDefault: allowsNoDefault
                )
                flow.submit(
                    onSaved: {
                        onSaved()
                        dismiss()
                    },
                    onNeedsRefresh: {
                        onNeedsRefresh()
                        dismiss()
                    }
                )
            }
            .disabled(!canSubmit)
            .accessibilityIdentifier("account-lifecycle-submit")
        }
        .navigationTitle(AccountLocalization.string("account.management.title", locale: locale))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(AccountLocalization.string("common.cancel", locale: locale)) {
                    dismiss()
                }
                .disabled(flow.isSaving)
            }
        }
        .interactiveDismissDisabled(flow.isSaving)
    }

    /// 按当前应用语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }

    /// 只有预检允许且默认处置条件已满足时开放提交。
    private var canSubmit: Bool {
        guard !flow.isSaving else { return false }
        guard plan.canPermanentlyDelete || plan.canDeactivate else { return false }
        guard !plan.isCurrentDefault else {
            return plan.replacementCandidates.isEmpty ? allowsNoDefault : replacementAccountID != nil
        }
        return true
    }
}
