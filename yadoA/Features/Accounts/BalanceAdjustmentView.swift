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

    /// 余额是否表示欠款（信用卡、负债）：这时文案改说「欠款」，正负改成「欠款 / 多还的钱」，
    /// 避免用户把欠款填成负数、被当成多还的钱算进资产。
    private let isDebt: Bool

    /// 创建一份直接设置目标总余额的调整表单。
    ///
    /// - Parameters:
    ///   - accountID: 被调整账户的稳定 UUID。
    ///   - currentBalance: 打开 Sheet 时的账户总余额。
    ///   - accountType: 账户类型，决定按余额还是按欠款来说；未知类型按余额。
    ///   - initialTargetBalance: 预填的目标余额；为 `nil` 时预填当前余额。欠款填成负数、一键改成正数时传入。
    ///   - save: 原子保存目标余额和调整流水的动作。
    ///   - onSaved: 保存成功后的关闭与刷新动作。
    init(
        accountID: UUID,
        currentBalance: Decimal,
        accountType: AccountType? = nil,
        initialTargetBalance: Decimal? = nil,
        save: @escaping BalanceAdjustmentSaveAction,
        onSaved: @escaping @MainActor () -> Void
    ) {
        self.onSaved = onSaved
        isDebt = accountType?.expenseBalanceEffect == .increaseDebt
        _flow = StateObject(
            wrappedValue: BalanceAdjustmentFlow(
                // 草稿只用这个金额预填输入框和正负，不影响「当前余额」的展示和同值判断
                draft: BalanceAdjustmentDraft(
                    accountID: accountID,
                    currentBalance: initialTargetBalance ?? currentBalance
                ),
                currentBalance: currentBalance,
                saveAction: save
            )
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                slip
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
        .paperPage()
    }

    /// 一张手绘方框里的调整单：当前余额、目标余额和原因从上到下写在同一张纸上。
    private var slip: some View {
        VStack(alignment: .leading, spacing: 18) {
            currentBalanceSummary

            HandDrawnRule(seed: 104)
                .stroke(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                .frame(height: 3)
                .accessibilityHidden(true)

            targetBalanceSection
            noteSection
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ledgerFormBorder(seed: 103)
    }

    /// 清晰说明页面正在设置总余额，而不是输入增减差额。
    private var currentBalanceSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text(debtAware("account.balance_adjustment.current")))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(formattedCurrency(flow.currentBalance))
                .font(.system(.title2, design: .serif, weight: .medium))
                .monospacedDigit()

            Text(text(debtAware("account.balance_adjustment.target_explanation")))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("balance-adjustment-current")
    }

    /// 正负选择与系统小数键盘共同编辑目标总余额。
    private var targetBalanceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(text(debtAware("account.balance_adjustment.target")))
                .font(.system(.headline, design: .serif))

            signPicker

            TextField(
                text(debtAware("account.balance_adjustment.target")),
                text: targetAmountTextBinding,
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
            .accessibilityIdentifier("balance-adjustment-target")

            // 目标金额写在一条手绘的横线上，与记账页的金额一致。
            HandDrawnRule(seed: 105)
                .stroke(Color.primary.opacity(0.6), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                .frame(height: 3)
                .accessibilityHidden(true)
        }
    }

    /// 负数目标在输入框中固定显示负号，输入内容只允许编辑绝对值。
    private var targetAmountTextBinding: Binding<String> {
        Binding(
            get: {
                flow.draft.sign == .negative
                    ? "-" + flow.draft.amountText
                    : flow.draft.amountText
            },
            set: { amountText in
                guard let magnitudeText = editableMagnitudeText(from: amountText) else {
                    return
                }

                isSaveErrorFocused = false
                flow.updateAmountText(
                    magnitudeText,
                    decimalSeparator: locale.decimalSeparator ?? "."
                )
            }
        )
    }

    /// 只从负数显示值中移除固定负号，阻止正数输入通过文本注入负号。
    private func editableMagnitudeText(from amountText: String) -> String? {
        if flow.draft.sign == .negative {
            return amountText.hasPrefix("-")
                ? String(amountText.dropFirst())
                : amountText
        }

        return amountText.contains("-") ? nil : amountText
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
            LedgerSwitch(
                label: AccountLocalization.string("account.balance_adjustment.sign", locale: locale),
                selection: signBinding,
                options: [
                    .init(
                        value: BalanceAdjustmentSign.positive,
                        title: signTitle(.positive),
                        identifier: "balance-adjustment-sign-positive"
                    ),
                    .init(
                        value: BalanceAdjustmentSign.negative,
                        title: signTitle(.negative),
                        identifier: "balance-adjustment-sign-negative"
                    )
                ]
            )
            .frame(maxWidth: .infinity)
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

    /// 返回正负状态对应的本地化可见文本；欠款账户写「欠款 / 多还的钱」，不出现「负数」。
    private func signTitle(_ sign: BalanceAdjustmentSign) -> String {
        let key = switch (sign, isDebt) {
        case (.positive, false): "account.balance_adjustment.sign.positive"
        case (.negative, false): "account.balance_adjustment.sign.negative"
        case (.positive, true): "account.balance_adjustment.sign.debt.positive"
        case (.negative, true): "account.balance_adjustment.sign.debt.negative"
        }
        return text(key)
    }

    /// 欠款账户换用同一处文案的欠款版本，键名在原键后加 `.debt`。
    ///
    /// - Parameter key: 按余额说的文案键。
    /// - Returns: 欠款账户返回 `<key>.debt`，其他账户原样返回。
    private func debtAware(_ key: String) -> String {
        isDebt ? key + ".debt" : key
    }

    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
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
        .frame(minHeight: 44)
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
            .foregroundStyle(Color(.ledgerRed))
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
                    AppHaptics.play(.error)
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
            .onAccentForeground()
        }
        .buttonStyle(.borderedProminent)
        .disabled(!flow.canSubmit)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .background(Color(.paperBackground))
        .accessibilityIdentifier("balance-adjustment-save")
    }

    /// 使用当前语言环境展示精确 CNY 总余额。
    private func formattedCurrency(_ amount: Decimal) -> String {
        amount.formattedCurrency(locale: locale)
    }

    /// 保存成功后提供系统触觉和 VoiceOver 公告。
    private func provideSuccessFeedback() {
        AppHaptics.play(.success)
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
