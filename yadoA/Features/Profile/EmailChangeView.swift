import SwiftUI

/// 绑定 / 更换邮箱的弹层：先验证身份，再输入新邮箱、收验证码并保存。
///
/// 从「账号与安全」页的邮箱行打开，流程状态全在 `EmailChangeFlow`；关闭后由「账号与安全」页重新读取账号信息。
/// 验证身份按账号情况三选一：输密码、给当前邮箱发验证码、只有 Apple 时重新走一遍 Logto 托管页（step-up）。
/// 重发验证码有 60 秒倒计时，验证码输入框用 `.oneTimeCode`，可以直接填入短信 / 邮件里的验证码建议。
struct EmailChangeView: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss

    /// 流程状态。
    @State private var flow: EmailChangeFlow

    /// 当前聚焦的输入框。
    @FocusState private var focusedField: Field?

    /// 弹层里的输入框。
    private enum Field: Hashable {
        case password
        case identityCode
        case newEmail
        case newEmailCode
    }

    /// - Parameter flow: 本次打开弹层新建的流程。
    init(flow: EmailChangeFlow) {
        _flow = State(initialValue: flow)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    stepContent

                    if let messageKey = flow.messageKey {
                        Text(text(messageKey))
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("email-change-message")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 32)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .paperPage()
            .navigationTitle(text(flow.isChanging ? "account.email.change.title" : "account.email.bind.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isFinished {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(text("common.cancel")) {
                            dismiss()
                        }
                        .disabled(flow.isWorking)
                        .accessibilityIdentifier("email-change-cancel")
                    }
                }
            }
        }
        .interactiveDismissDisabled(flow.isWorking)
        .onChange(of: flow.newEmail) {
            flow.newEmailDidChange()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("email-change")
    }

    // MARK: - 步骤

    /// 当前步骤的内容。
    @ViewBuilder
    private var stepContent: some View {
        switch flow.step {
        case let .identity(method):
            identityContent(method)
        case .newEmail:
            newEmailContent
        case let .finished(email):
            resultContent(
                symbol: "checkmark.circle",
                titleKey: flow.isChanging ? "account.email.finished.changed" : "account.email.finished.bound",
                detail: email,
                messageKey: "account.email.finished.message"
            )
        case .accountSwitched:
            resultContent(
                symbol: "person.crop.circle.badge.exclamationmark",
                titleKey: "account.reauth.switched.title",
                detail: nil,
                messageKey: "account.reauth.switched.message"
            )
        }
    }

    /// 验证身份这一步。
    @ViewBuilder
    private func identityContent(_ method: AccountIdentityVerificationMethod) -> some View {
        heading("account.email.identity.title")

        switch method {
        case .password:
            explanation(text("account.email.identity.password.message"))

            field("account.email.identity.password.field") {
                SecureField(text("account.email.identity.password.placeholder"), text: $flow.password)
                    .textContentType(.password)
                    .submitLabel(.continue)
                    .focused($focusedField, equals: .password)
                    .onSubmit { Task { await flow.submitPassword() } }
                    .accessibilityIdentifier("email-change-password")
            }

            primaryButton("account.email.next", isEnabled: !flow.password.isEmpty) {
                await flow.submitPassword()
            }
            .accessibilityIdentifier("email-change-password-submit")

        case let .currentEmailCode(email):
            explanation(format("account.email.identity.code.message", AccountEmail.masked(email)))

            if flow.isIdentityCodeSent {
                codeField($flow.identityCode, focus: .identityCode, identifier: "email-change-identity-code") {
                    Task { await flow.submitIdentityCode() }
                }

                resendButton(sentAt: flow.identityCodeSentAt) {
                    await flow.sendIdentityCode()
                }

                primaryButton("account.email.next", isEnabled: !flow.identityCode.isEmpty) {
                    await flow.submitIdentityCode()
                }
                .accessibilityIdentifier("email-change-identity-code-submit")
            } else {
                primaryButton("account.email.code.send", isEnabled: true) {
                    await flow.sendIdentityCode()
                    if flow.isIdentityCodeSent {
                        focusedField = .identityCode
                    }
                }
                .accessibilityIdentifier("email-change-identity-code-send")
            }

        case .stepUp:
            explanation(text("account.email.step_up.message"))

            primaryButton("account.email.step_up.action", isEnabled: true) {
                await flow.startStepUp()
            }
            .accessibilityIdentifier("email-change-step-up")

        case .unavailable:
            explanation(text("account.email.identity.unavailable"))
        }
    }

    /// 输入新邮箱、收验证码并保存这一步。
    @ViewBuilder
    private var newEmailContent: some View {
        heading(flow.isChanging ? "account.email.new.title.change" : "account.email.new.title.bind")
        explanation(text("account.email.new.message"))

        field("account.email.new.field") {
            TextField(text("account.email.new.placeholder"), text: $flow.newEmail)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .focused($focusedField, equals: .newEmail)
                .onSubmit { Task { await sendNewEmailCode() } }
                .accessibilityIdentifier("email-change-new-email")
        }

        if flow.isNewEmailCodeSent {
            explanation(format("account.email.code.sent", flow.normalizedNewEmail))

            codeField($flow.newEmailCode, focus: .newEmailCode, identifier: "email-change-new-email-code") {
                Task { await flow.saveNewEmail() }
            }

            resendButton(sentAt: flow.newEmailCodeSentAt) {
                await flow.sendNewEmailCode()
            }

            primaryButton("account.email.save", isEnabled: !flow.newEmailCode.isEmpty) {
                await flow.saveNewEmail()
            }
            .accessibilityIdentifier("email-change-save")
        } else {
            primaryButton("account.email.code.send", isEnabled: !flow.normalizedNewEmail.isEmpty) {
                await sendNewEmailCode()
            }
            .accessibilityIdentifier("email-change-new-email-send")
        }
    }

    /// 结束页：图标、标题、可选的邮箱地址和说明，底部一个关闭弹层的按钮。
    private func resultContent(symbol: String, titleKey: String, detail: String?, messageKey: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
                .padding(.top, 12)

            Text(text(titleKey))
                .font(.system(.title3, design: .serif, weight: .semibold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            if let detail {
                Text(verbatim: detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text(text(messageKey))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                dismiss()
            } label: {
                ProfilePrimaryButtonLabel(title: text("common.done"))
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
            .accessibilityIdentifier("email-change-done")
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 组件

    /// 步骤标题。
    private func heading(_ key: String) -> some View {
        Text(text(key))
            .font(.system(.title3, design: .serif, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
    }

    /// 步骤说明。
    private func explanation(_ message: String) -> some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 标题加胶囊输入框的一组字段。
    private func field<Content: View>(_ titleKey: String, @ViewBuilder input: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text(titleKey))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)

            input()
                .profileCapsuleField()
                .disabled(flow.isWorking)
        }
    }

    /// 验证码输入框：数字键盘，`.oneTimeCode` 让系统建议邮件里的验证码。
    ///
    /// - Parameters:
    ///   - code: 绑定的输入。
    ///   - focus: 对应的聚焦标识。
    ///   - identifier: 输入框的无障碍标识，供 UI 测试定位。
    ///   - onSubmit: 键盘上点完成时的动作。
    private func codeField(
        _ code: Binding<String>,
        focus: Field,
        identifier: String,
        onSubmit: @escaping () -> Void
    ) -> some View {
        field("account.email.code.field") {
            TextField(text("account.email.code.placeholder"), text: code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focusedField, equals: focus)
                .onSubmit(onSubmit)
                .accessibilityIdentifier(identifier)
        }
    }

    /// 重发验证码的按钮，冷却中显示剩余秒数并禁用；每秒刷新一次。
    ///
    /// - Parameters:
    ///   - sentAt: 上次发送的时刻。
    ///   - action: 重发动作。
    private func resendButton(sentAt: Date?, action: @escaping () async -> Void) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = EmailCodeCooldown.remainingSeconds(sentAt: sentAt, now: context.date)
            Button {
                Task { await action() }
            } label: {
                Text(remaining > 0 ? format("account.email.code.resend_countdown", remaining) : text("account.email.code.resend"))
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(remaining > 0 ? Color.secondary : Color.primary)
                    .underline(remaining == 0)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(remaining > 0 || flow.isWorking)
            .accessibilityIdentifier("email-change-resend")
        }
    }

    /// 黑色胶囊主按钮，进行中转圈；不可用时变淡。
    ///
    /// - Parameters:
    ///   - titleKey: 按钮文案键。
    ///   - isEnabled: 输入是否已满足提交条件。
    ///   - action: 点击后执行的动作。
    private func primaryButton(_ titleKey: String, isEnabled: Bool, action: @escaping () async -> Void) -> some View {
        let canTap = isEnabled && !flow.isWorking
        return Button {
            focusedField = nil
            Task { await action() }
        } label: {
            ProfilePrimaryButtonLabel(title: text(titleKey), isLoading: flow.isWorking)
        }
        .buttonStyle(.plain)
        .opacity(canTap || flow.isWorking ? 1 : 0.35)
        .disabled(!canTap)
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    // MARK: - 操作与工具

    /// 给新邮箱发验证码，发出后把焦点移到验证码输入框。
    private func sendNewEmailCode() async {
        await flow.sendNewEmailCode()
        if flow.isNewEmailCodeSent {
            focusedField = .newEmailCode
        }
    }

    /// 是否已到结束页（不再显示取消按钮）。
    private var isFinished: Bool {
        switch flow.step {
        case .finished, .accountSwitched: true
        case .identity, .newEmail: false
        }
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }

    /// 按应用当前语言解析带一个参数的文案。
    private func format(_ key: String, _ argument: CVarArg) -> String {
        String(format: text(key), locale: locale, argument)
    }
}

#Preview("用密码验证后绑定") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            EmailChangeView(flow: EmailChangeFlow(
                account: AccountSecurityInfo(
                    userID: "preview",
                    username: "yado",
                    hasPrimaryEmail: false,
                    hasPassword: true,
                    hasSecurityVerificationMethod: true
                ),
                service: AuthStore().makeAccountSecurityClient(),
                reauthenticate: { .cancelled }
            ))
        }
}
