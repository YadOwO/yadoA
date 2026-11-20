import AuthenticationServices
import SwiftUI

/// 修改登录方式的弹层：绑定 / 更换邮箱、设置 / 修改密码，或关联 Apple。先验证身份，再输入新邮箱（收验证码）、新密码，
/// 或打开 Apple 授权页，保存。
///
/// 从「账号与安全」页的邮箱行、密码行、Apple 行打开，流程状态全在 `AccountCredentialChangeFlow`；关闭后由「账号与安全」页重新读取账号信息。
/// 验证身份按账号情况三选一：给当前邮箱发验证码、输密码、只有 Apple 时重新走一遍 Logto 托管页（step-up）；
/// 只有 Apple 的账号设置密码时不用验证身份，直接输入新密码。
/// 关联 Apple 时用系统的 `WebAuthenticationSession` 打开 Apple 授权页，回程由云服务器跳回登录回调的 scheme。
/// 重发验证码有 60 秒倒计时，验证码输入框用 `.oneTimeCode`，可以直接填入短信 / 邮件里的验证码建议。
/// 身份验证通过、验证码发出（含重发）时在顶部弹出轻提示（`AppToast`）；验证通过后焦点直接落到下一步的输入框。
struct AccountCredentialChangeView: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    /// 关联 Apple 时打开 Apple 授权页的系统浏览器会话。
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    /// 流程状态。
    @State private var flow: AccountCredentialChangeFlow

    /// 当前聚焦的输入框。
    @FocusState private var focusedField: Field?

    /// 顶部的轻提示：身份验证通过、验证码已发出时弹出，由 `flow.notice` 驱动。
    @State private var toast: AppToast?

    /// 弹层里的输入框。
    private enum Field: Hashable {
        case password
        case identityCode
        case newEmail
        case newEmailCode
        case newPassword
        case confirmPassword
    }

    /// - Parameter flow: 本次打开弹层新建的流程。
    init(flow: AccountCredentialChangeFlow) {
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
                            .accessibilityIdentifier(controlID("message"))
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
            .appToast($toast)
            .navigationTitle(text(navigationTitleKey))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isFinished {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(text("common.cancel")) {
                            dismiss()
                        }
                        .disabled(flow.isWorking)
                        .accessibilityIdentifier(controlID("cancel"))
                    }
                }
            }
        }
        .interactiveDismissDisabled(flow.isWorking)
        .onChange(of: flow.newEmail) {
            flow.newEmailDidChange()
        }
        .onChange(of: flow.notice) { _, notice in
            guard let notice else { return }
            toast = .success(
                text(notice.localizationKey),
                systemImage: notice.kind == .codeSent ? "paperplane.fill" : "checkmark.circle.fill",
                accessibilityIdentifier: controlID("toast")
            )
        }
        .onChange(of: flow.step) { _, step in
            focusFirstField(of: step)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(idPrefix)
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
        case .newPassword:
            newPasswordContent
        case .linkApple:
            linkAppleContent
        case let .finished(email):
            switch flow.target {
            case .email:
                resultContent(
                    symbol: "checkmark.circle",
                    titleKey: flow.isChanging ? "account.email.finished.changed" : "account.email.finished.bound",
                    detail: email,
                    messageKey: "account.email.finished.message"
                )
            case .password:
                resultContent(
                    symbol: "checkmark.circle",
                    titleKey: flow.isChanging ? "account.password.finished.changed" : "account.password.finished.set",
                    detail: nil,
                    messageKey: "account.password.finished.message"
                )
            case .apple:
                resultContent(
                    symbol: "checkmark.circle",
                    titleKey: "account.apple.finished.title",
                    detail: nil,
                    messageKey: "account.apple.finished.message"
                )
            }
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
                    .accessibilityIdentifier(controlID("password"))
            }

            primaryButton("account.email.next", isEnabled: !flow.password.isEmpty) {
                await flow.submitPassword()
            }
            .accessibilityIdentifier(controlID("password-submit"))

        case let .currentEmailCode(email):
            explanation(format("account.email.identity.code.message", AccountEmail.masked(email)))

            if flow.isIdentityCodeSent {
                codeField($flow.identityCode, focus: .identityCode, identifier: controlID("identity-code")) {
                    Task { await flow.submitIdentityCode() }
                }

                codeNotReceivedHint

                resendButton(sentAt: flow.identityCodeSentAt) {
                    await flow.sendIdentityCode()
                }

                primaryButton("account.email.next", isEnabled: flow.isIdentityCodeComplete) {
                    await flow.submitIdentityCode()
                }
                .accessibilityIdentifier(controlID("identity-code-submit"))
            } else {
                primaryButton("account.email.code.send", isEnabled: true) {
                    await flow.sendIdentityCode()
                    if flow.isIdentityCodeSent {
                        focusedField = .identityCode
                    }
                }
                .accessibilityIdentifier(controlID("identity-code-send"))
            }

        case .stepUp:
            explanation(text("account.email.step_up.message"))

            primaryButton("account.email.step_up.action", isEnabled: true) {
                await flow.startStepUp()
            }
            .accessibilityIdentifier(controlID("step-up"))

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
                .accessibilityIdentifier(controlID("new-email"))
        }

        if flow.isNewEmailCodeSent {
            explanation(format("account.email.code.sent", flow.normalizedNewEmail))

            codeField($flow.newEmailCode, focus: .newEmailCode, identifier: controlID("new-email-code")) {
                Task { await flow.saveNewEmail() }
            }

            codeNotReceivedHint

            resendButton(sentAt: flow.newEmailCodeSentAt) {
                await flow.sendNewEmailCode()
            }

            primaryButton("account.email.save", isEnabled: flow.isNewEmailCodeComplete) {
                await flow.saveNewEmail()
            }
            .accessibilityIdentifier(controlID("save"))
        } else {
            primaryButton("account.email.code.send", isEnabled: !flow.normalizedNewEmail.isEmpty) {
                await sendNewEmailCode()
            }
            .accessibilityIdentifier(controlID("new-email-send"))
        }
    }

    /// 输入并确认新密码这一步：两个密码框，确认不一致时在下方提示，一致后才能保存。
    @ViewBuilder
    private var newPasswordContent: some View {
        heading(flow.isChanging ? "account.password.new.title.change" : "account.password.new.title.set")
        explanation(text("account.password.new.message"))

        field("account.password.new.field") {
            SecureField(text("account.password.new.placeholder"), text: $flow.newPassword)
                .textContentType(.newPassword)
                .submitLabel(.next)
                .focused($focusedField, equals: .newPassword)
                .onSubmit { focusedField = .confirmPassword }
                .accessibilityIdentifier(controlID("new-password"))
        }

        field("account.password.confirm.field") {
            SecureField(text("account.password.confirm.placeholder"), text: $flow.confirmPassword)
                .textContentType(.newPassword)
                .submitLabel(.done)
                .focused($focusedField, equals: .confirmPassword)
                .onSubmit { Task { await flow.saveNewPassword() } }
                .accessibilityIdentifier(controlID("confirm-password"))
        }

        if flow.isConfirmPasswordMismatched {
            Text(text("account.password.error.mismatch"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
                .accessibilityIdentifier(controlID("mismatch"))
        }

        primaryButton("account.email.save", isEnabled: flow.isNewPasswordReady) {
            await flow.saveNewPassword()
        }
        .accessibilityIdentifier(controlID("save"))
    }

    /// 关联 Apple 这一步：说明会打开 Apple 授权页，点继续后打开，授权完自动关联。
    @ViewBuilder
    private var linkAppleContent: some View {
        heading("account.apple.link.title")
        explanation(text("account.apple.link.message"))

        primaryButton("account.apple.link.action", isEnabled: true) {
            await flow.linkApple(authorize: authorizeInBrowser)
        }
        .accessibilityIdentifier(controlID("authorize"))
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
            .accessibilityIdentifier(controlID("done"))
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
    /// 只能输入 6 位数字：每次变化都经 `AccountCredentialChangeFlow.sanitizedCode` 过滤，多出的位数和非数字字符直接丢掉；
    /// 数字等宽、拉开字距，方便和邮件里的验证码逐位对照。
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
                .autocorrectionDisabled()
                .monospacedDigit()
                // 占位文字保持正常字距，只给输入的数字拉开
                .kerning(code.wrappedValue.isEmpty ? 0 : 4)
                .onChange(of: code.wrappedValue) { _, newValue in
                    let sanitized = AccountCredentialChangeFlow.sanitizedCode(newValue)
                    if sanitized != newValue {
                        code.wrappedValue = sanitized
                    }
                }
                .focused($focusedField, equals: focus)
                .onSubmit(onSubmit)
                .accessibilityIdentifier(identifier)
        }
    }

    /// 发出验证码后的提示：没收到先看垃圾邮件箱。Gmail 等邮箱可能把验证码邮件归进垃圾箱，
    /// Apple 隐藏邮箱的转发也可能晚几分钟。
    private var codeNotReceivedHint: some View {
        Text(text("account.email.code.spam_hint"))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(controlID("spam-hint"))
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
            .accessibilityIdentifier(controlID("resend"))
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

    /// 验证完身份进入下一步时，把焦点放到这一步的第一个输入框，不用再点一下才能输入。
    ///
    /// - Parameter step: 刚进入的步骤；只处理输入新邮箱、新密码，其余步骤不动焦点。
    private func focusFirstField(of step: AccountCredentialChangeFlow.Step) {
        switch step {
        case .newEmail: focusedField = .newEmail
        case .newPassword: focusedField = .newPassword
        case .identity, .linkApple, .finished, .accountSwitched: break
        }
    }

    /// 是否已到结束页（不再显示取消按钮）。
    private var isFinished: Bool {
        switch flow.step {
        case .finished, .accountSwitched: true
        case .identity, .newEmail, .newPassword, .linkApple: false
        }
    }

    /// 导航栏标题：按改邮箱 / 改密码 / 关联 Apple、第一次设置还是更换区分。
    private var navigationTitleKey: String {
        switch flow.target {
        case .email: flow.isChanging ? "account.email.change.title" : "account.email.bind.title"
        case .password: flow.isChanging ? "account.password.change.title" : "account.password.set.title"
        case .apple: "account.apple.link.title"
        }
    }

    /// 无障碍标识的前缀，供 UI 测试区分几种弹层：改邮箱沿用 `email-change`，改密码为 `password-change`，关联 Apple 为 `apple-link`。
    private var idPrefix: String {
        switch flow.target {
        case .email: "email-change"
        case .password: "password-change"
        case .apple: "apple-link"
        }
    }

    /// 在系统浏览器会话里打开 Apple 授权页，等云服务器把回程跳回登录回调的 scheme。
    ///
    /// - Parameter url: Logto 返回的授权页地址。
    /// - Returns: 跳回 App 的地址；用户关掉浏览器时返回 nil。
    /// - Throws: 浏览器会话打不开等其他错误。
    private func authorizeInBrowser(_ url: URL) async throws -> URL? {
        do {
            return try await webAuthenticationSession.authenticate(using: url, callbackURLScheme: AuthConfig.callbackScheme)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return nil
        }
    }

    /// 弹层里某个控件的无障碍标识：`<前缀>-<名字>`。
    ///
    /// - Parameter name: 控件名，如 `save`、`identity-code`。
    private func controlID(_ name: String) -> String {
        "\(idPrefix)-\(name)"
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

#Preview("用密码验证后绑定邮箱") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            AccountCredentialChangeView(flow: AccountCredentialChangeFlow(
                target: .email,
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

#Preview("只有 Apple 时直接设置密码") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            AccountCredentialChangeView(flow: AccountCredentialChangeFlow(
                target: .password,
                account: AccountSecurityInfo(
                    userID: "preview",
                    hasPrimaryEmail: false,
                    hasPassword: false,
                    hasSecurityVerificationMethod: false,
                    socialTargets: ["apple"]
                ),
                service: AuthStore().makeAccountSecurityClient(),
                reauthenticate: { .cancelled }
            ))
        }
}
