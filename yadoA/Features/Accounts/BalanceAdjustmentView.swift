import SwiftUI
import UIKit

/// 从账户详情拉起的目标总余额调整 Sheet。
struct BalanceAdjustmentView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var focusedField: FocusedField?
    @AccessibilityFocusState private var isSaveErrorFocused: Bool
    @StateObject private var flow: BalanceAdjustmentFlow

    /// 仅在余额与流水均保存成功后交由账户详情关闭 Sheet。
    private let onSaved: @MainActor () -> Void

    /// 创建一份直接设置目标总余额的调整表单。
    ///
    /// - Parameters:
    ///   - accountID: 被调整账户的稳定 UUID。
    ///   - currentBalance: 打开 Sheet 时的账户总余额。
    ///   - save: 原子保存目标余额和调整流水的动作。
    ///   - onSaved: 保存成功后的关闭与刷新动作。
    init(
        accountID: UUID,
        currentBalance: Decimal,
        save: @escaping BalanceAdjustmentSaveAction,
        onSaved: @escaping @MainActor () -> Void
    ) {
        self.onSaved = onSaved
        _flow = StateObject(
            wrappedValue: BalanceAdjustmentFlow(
                draft: BalanceAdjustmentDraft(
                    accountID: accountID,
                    currentBalance: currentBalance
                ),
                currentBalance: currentBalance,
                saveAction: save
            )
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                currentBalanceSummary
                targetBalanceSection
                noteSection
                inlineFeedback
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(
            AccountLocalization.string("account.balance_adjustment.title", locale: locale)
        )
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(flow.isSaving)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            submitButton
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(AccountLocalization.string("common.cancel", locale: locale)) {
                    dismiss()
                }
                .disabled(flow.isSaving)
                .accessibilityIdentifier("balance-adjustment-cancel")
            }

            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(AccountLocalization.string("common.done", locale: locale)) {
                    focusedField = nil
                }
            }
        }
        .task {
            focusedField = .amount
        }
    }

    /// 清晰说明页面正在设置总余额，而不是输入增减差额。
    private var currentBalanceSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                AccountLocalization.string(
                    "account.balance_adjustment.current",
                    locale: locale
                )
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Text(formattedCurrency(flow.currentBalance))
                .font(.title2.monospacedDigit().weight(.semibold))

            Text(
                AccountLocalization.string(
                    "account.balance_adjustment.target_explanation",
                    locale: locale
                )
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("balance-adjustment-current")
    }

    /// 正负选择与系统小数键盘共同编辑目标总余额。
    private var targetBalanceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                AccountLocalization.string(
                    "account.balance_adjustment.target",
                    locale: locale
                )
            )
            .font(.headline)

            signPicker

            TextField(
                AccountLocalization.string(
                    "account.balance_adjustment.target",
                    locale: locale
                ),
                text: Binding(
                    get: { flow.draft.amountText },
                    set: {
                        isSaveErrorFocused = false
                        flow.updateAmountText(
                            $0,
                            decimalSeparator: locale.decimalSeparator ?? "."
                        )
                    }
                ),
                prompt: Text(verbatim: "0")
            )
            .font(.system(.largeTitle, design: .rounded, weight: .semibold))
            .monospacedDigit()
            .keyboardType(.decimalPad)
            .focused($focusedField, equals: .amount)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.55)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 72)
            .accessibilityIdentifier("balance-adjustment-target")
        }
        .padding(16)
        .background(
            Color.primary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    /// 普通字号使用紧凑分段选择；辅助功能字号回退为可换行的纵向按钮。
    @ViewBuilder
    private var signPicker: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                signButton(.positive)
                signButton(.negative)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(
                AccountLocalization.string(
                    "account.balance_adjustment.sign",
                    locale: locale
                )
            )
            .accessibilityIdentifier("balance-adjustment-sign")
        } else {
            Picker(
                AccountLocalization.string(
                    "account.balance_adjustment.sign",
                    locale: locale
                ),
                selection: signBinding
            ) {
                Text(signTitle(.positive))
                    .tag(BalanceAdjustmentSign.positive)
                Text(signTitle(.negative))
                    .tag(BalanceAdjustmentSign.negative)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("balance-adjustment-sign")
        }
    }

    /// 辅助功能字号下可完整显示并明确当前选择的正负按钮。
    private func signButton(_ sign: BalanceAdjustmentSign) -> some View {
        Button {
            signBinding.wrappedValue = sign
        } label: {
            HStack(spacing: 12) {
                Text(signTitle(sign))
                Spacer(minLength: 8)
                if flow.draft.sign == sign {
                    Image(systemName: "checkmark")
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .accessibilityAddTraits(flow.draft.sign == sign ? .isSelected : [])
    }

    /// 正负选择统一写回 Flow，并清除旧错误焦点。
    private var signBinding: Binding<BalanceAdjustmentSign> {
        Binding(
            get: { flow.draft.sign },
            set: {
                isSaveErrorFocused = false
                flow.updateSign($0)
            }
        )
    }

    /// 返回正负状态对应的本地化可见文本。
    private func signTitle(_ sign: BalanceAdjustmentSign) -> String {
        AccountLocalization.string(
            sign == .positive
                ? "account.balance_adjustment.sign.positive"
                : "account.balance_adjustment.sign.negative",
            locale: locale
        )
    }

    /// 可选调整原因；空白内容会在模型边界清理为 `nil`。
    private var noteSection: some View {
        TextField(
            AccountLocalization.string(
                "account.balance_adjustment.note.placeholder",
                locale: locale
            ),
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
        .padding(14)
        .frame(minHeight: 52)
        .background(
            Color.primary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .accessibilityLabel(
            Text(
                AccountLocalization.string(
                    "account.balance_adjustment.note",
                    locale: locale
                )
            )
        )
        .accessibilityIdentifier("balance-adjustment-note")
    }

    /// 失败后保留草稿，并把 VoiceOver 焦点移动到轻量错误提示。
    @ViewBuilder
    private var inlineFeedback: some View {
        if flow.hasSaveError {
            Label(
                AccountLocalization.string(
                    "account.balance_adjustment.save_failed",
                    locale: locale
                ),
                systemImage: "exclamationmark.circle.fill"
            )
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityFocused($isSaveErrorFocused)
            .accessibilityIdentifier("balance-adjustment-save-error")
        }
    }

    /// 页面底部保存动作；同值和无效目标不会产生流水。
    private var submitButton: some View {
        Button {
            focusedField = nil
            Task {
                await flow.submit {
                    provideSuccessFeedback()
                    onSaved()
                }

                if flow.hasSaveError {
                    await Task.yield()
                    isSaveErrorFocused = true
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: AccountLocalization.string(
                            "account.balance_adjustment.save_failed",
                            locale: locale
                        )
                    )
                }
            }
        } label: {
            HStack(spacing: 8) {
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
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!flow.canSubmit)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .accessibilityIdentifier("balance-adjustment-save")
    }

    /// 使用当前语言环境展示精确 CNY 总余额。
    private func formattedCurrency(_ amount: Decimal) -> String {
        amount.formatted(.currency(code: "CNY").locale(locale))
    }

    /// 保存成功后提供系统触觉和 VoiceOver 公告。
    private func provideSuccessFeedback() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        UIAccessibility.post(
            notification: .announcement,
            argument: AccountLocalization.string(
                "account.balance_adjustment.save_succeeded",
                locale: locale
            )
        )
    }

    /// Sheet 内可唤起系统键盘的输入区域。
    private enum FocusedField: Hashable {
        case amount
        case note
    }
}
