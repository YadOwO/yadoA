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
        Form {
            Section {
                LabeledContent(
                    AccountLocalization.string("account.lifecycle.account", locale: locale),
                    value: plan.accountName
                )

                if plan.balance != .zero {
                    LabeledContent(
                        AccountLocalization.string("account.lifecycle.current_balance", locale: locale),
                        value: plan.balance.formatted(
                            .currency(code: "CNY")
                                .locale(locale)
                        )
                    )
                }

                Label(
                    plan.canPermanentlyDelete
                        ? AccountLocalization.string("account.lifecycle.delete", locale: locale)
                        : AccountLocalization.string("account.lifecycle.deactivate", locale: locale),
                    systemImage: plan.canPermanentlyDelete ? "trash" : "pause.circle"
                )
                .font(.headline)

                Text(
                    plan.canPermanentlyDelete
                        ? AccountLocalization.string("account.lifecycle.delete_warning", locale: locale)
                        : plan.canDeactivate
                            ? AccountLocalization.string("account.lifecycle.deactivate_warning", locale: locale)
                            : AccountLocalization.string("account.lifecycle.deactivate_blocked", locale: locale)
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            if plan.isCurrentDefault {
                Section {
                    if plan.replacementCandidates.isEmpty {
                        Toggle(
                            AccountLocalization.string("account.lifecycle.confirm_no_default", locale: locale),
                            isOn: $allowsNoDefault
                        )
                        .accessibilityIdentifier("account-lifecycle-no-default")
                        .onChange(of: allowsNoDefault) { _, value in
                            flow.update(
                                replacementAccountID: replacementAccountID,
                                allowsNoDefault: value
                            )
                        }
                    } else {
                        Text(AccountLocalization.string("account.lifecycle.choose_replacement", locale: locale))
                            .font(.subheadline.weight(.semibold))

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
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("account-lifecycle-replacement-\(candidate.id.uuidString)")
                        }
                    }
                }
            }

            if let error = flow.lastError {
                Section {
                    Label(
                        error == .expectedStateChanged
                            ? AccountLocalization.string("account.lifecycle.state_changed", locale: locale)
                            : AccountLocalization.string("account.lifecycle.save_error", locale: locale),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("account-lifecycle-error")
                }
            }

            Section {
                Button {
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
                } label: {
                    HStack {
                        if flow.isSaving {
                            ProgressView()
                                .accessibilityHidden(true)
                        }
                        Text(AccountLocalization.string("common.confirm", locale: locale))
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(!canSubmit)
                .accessibilityIdentifier("account-lifecycle-submit")
            }
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
