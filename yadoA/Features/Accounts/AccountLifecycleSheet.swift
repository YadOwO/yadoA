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

            }

            // 后果说明写在方框外，紧跟在要处理的账户下面；余额未归零时用账本红说明为什么不能继续。
            Text(text(consequenceKey))
                .font(.footnote)
                .foregroundStyle(isBlocked ? AnyShapeStyle(Color(.ledgerRed)) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 4)
                .accessibilityIdentifier("account-lifecycle-consequence")

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

            LedgerSubmitButton(
                title: text(plan.canPermanentlyDelete ? "account.lifecycle.delete" : "account.lifecycle.deactivate"),
                isSaving: flow.isSaving,
                isDestructive: plan.canPermanentlyDelete
            ) {
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
        .navigationTitle(
            text(plan.canPermanentlyDelete ? "account.lifecycle.delete_account" : "account.lifecycle.deactivate")
        )
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

    /// 有流水且余额不为零时既不能删除也不能停用。
    private var isBlocked: Bool {
        !plan.canPermanentlyDelete && !plan.canDeactivate
    }

    /// 当前操作的后果或受阻原因对应的文案键。
    private var consequenceKey: String {
        if plan.canPermanentlyDelete {
            return "account.lifecycle.delete_warning"
        }
        return plan.canDeactivate
            ? "account.lifecycle.deactivate_warning"
            : "account.lifecycle.deactivate_blocked"
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
