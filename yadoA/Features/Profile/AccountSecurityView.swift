import SwiftData
import SwiftUI

/// “我的 › 设置 › 账号与安全”：芽豆账号的用户名、登录方式（Apple、邮箱、密码），以及注销芽豆账号。
///
/// 账号信息来自 Logto Account API（`GET /api/my-account`），进入页面时读取，改邮箱、改密码、关联 Apple 的弹层关闭后再读一次。
/// 邮箱行在 `AuthConfig.isEmailAccountAvailable` 打开时可点、密码行在 `AuthConfig.isPasswordChangeAvailable` 打开时可点、
/// Apple 行在未关联且 `AuthConfig.isAppleLinkAvailable` 时可点，都进入 `AccountCredentialChangeView`；否则只读显示。
/// 新增 `email` / `identities` scope 之前登录的会话读不到邮箱，页面顶部提示重新登录一次（同一账号回来后刷新）。
/// 注销在页面底部，点开 `AccountDeletionSheet` 一个弹层走完确认、选本机账本处理方式、进度和结果；退出登录仍在设置页。
/// 退出登录后（注销完成、重新登录时换了账号、凭证失效）自动返回设置页；弹层和要先给用户看的提示关掉后再返回。
/// 入口只在已登录且允许联网时显示，与设置页「账号」分组的条件一致；走路径导航（`ProfileRoute.accountSecurity`），
/// 入口随退出登录消失时页面仍留在栈里。注销进行中弹层盖住整个界面且不能关闭，Tab Bar 和返回都点不到，页面不会被移出栈。
struct AccountSecurityView: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
        /// 全局登录状态。
    @Environment(AuthStore.self) private var authStore

    /// 账号信息的加载状态。
    @State private var loadState: LoadState = .loading
    /// 正在进行的改邮箱 / 改密码 / 关联 Apple 流程；非 nil 时弹出弹层。
    @State private var credentialFlow: AccountCredentialChangeFlow?
    /// 正在重新登录（补 scope）。
    @State private var isReauthenticating = false
    /// 重新登录失败的提示，显示在重新登录卡片里。
    @State private var reauthFailureMessage: String?
    /// 重新登录时在托管页里登了另一个账号、已退出登录的提示。
    @State private var isAccountSwitchedAlertPresented = false
    /// 已经请求返回设置页，避免重复调用 `dismiss()`。
    @State private var hasRequestedDismiss = false
    /// 注销芽豆账号的弹层（`AccountDeletionSheet`）是否打开；确认、进度和结果都在弹层里，不再叠系统弹窗。
    @State private var isDeletionSheetPresented = false
    /// 顶部的轻提示：重新登录成功时弹出。
    @State private var toast: AppToast?

    /// 账号信息的加载状态。
    private enum LoadState {
        /// 首次加载中。
        case loading
        /// 已读到账号信息。
        case loaded(AccountSecurityInfo)
        /// 加载失败，可重试。
        case failed(AccountProfileError)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                switch loadState {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .accessibilityIdentifier("account-security-loading")
                case let .failed(error):
                    if error == .reauthenticationRequired {
                        reauthenticationCard
                    } else {
                        failureCard(error)
                    }
                case let .loaded(info):
                    if info.needsReauthentication(isEmailAccountAvailable: AuthConfig.isEmailAccountAvailable) {
                        reauthenticationCard
                    }
                    accountSection(info)
                    signInMethodsSection(info)
                }

                Text(text("account.security.shared_note"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .accessibilityIdentifier("account-security-shared-note")

                deleteAccountSection
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .paperPage()
        .appToast($toast)
        .navigationTitle(text("account.security.title"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .sheet(item: $credentialFlow, onDismiss: credentialFlowDidDismiss) { flow in
            AccountCredentialChangeView(flow: flow)
        }
        .alert(text("account.reauth.switched.title"), isPresented: $isAccountSwitchedAlertPresented) {
            Button(text("common.close"), role: .cancel) {}
        } message: {
            Text(text("account.reauth.switched.message"))
        }
        // 注销整个流程在这一个弹层里，关掉后已退出登录就返回设置页
        .sheet(isPresented: $isDeletionSheetPresented, onDismiss: dismissIfSignedOut) {
            AccountDeletionSheet()
        }
        // 退出登录后返回设置页；正在进行的操作或要先给用户看的提示结束后再返回
        .onChange(of: authStore.isAuthenticated) { dismissIfSignedOut() }
        .onChange(of: authStore.isDeletingAccount) { dismissIfSignedOut() }
        .onChange(of: isReauthenticating) { dismissIfSignedOut() }
        .onChange(of: isAccountSwitchedAlertPresented) { dismissIfSignedOut() }
    }

    // MARK: - 分组

    /// 账号信息：只读的用户名，长按可复制。
    private func accountSection(_ info: AccountSecurityInfo) -> some View {
        ProfileSettingsSection("account.security.section.account") {
            HStack(spacing: 12) {
                Label(text("profile.edit.username.title"), systemImage: "at")
                    .labelStyle(ProfileSettingsLabelStyle())
                Spacer(minLength: 8)
                if let username = info.username?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty {
                    Text(verbatim: username)
                        .textSelection(.enabled)
                } else {
                    Text(text("profile.edit.username.unset"))
                }
            }
            .font(.body)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(minHeight: 60)
            .accessibilityElement(children: .combine)
            .accessibilityHint(text("profile.edit.username.readonly_hint"))
            .accessibilityIdentifier("account-security-username")
        }
    }

    /// 登录方式：Apple（未关联时可关联）、邮箱（可绑定 / 更换）、密码（可设置 / 修改）。
    ///
    /// Apple 和密码读不到（账户中心没开放对应字段）时不显示，避免把「读不到」显示成「未关联」「未设置」。
    private func signInMethodsSection(_ info: AccountSecurityInfo) -> some View {
        ProfileSettingsSection("account.security.section.sign_in") {
            if let isAppleLinked = info.isSocialLinked(AuthSocialProvider.apple.connectorTarget) {
                appleRow(info, isLinked: isAppleLinked)

                ProfileSettingsRowDivider()
            }

            emailRow(info)

            if let hasPassword = info.hasPassword {
                ProfileSettingsRowDivider()

                passwordRow(info, hasPassword: hasPassword)
            }
        }
    }

    /// 邮箱行：可修改时整行可点，行尾是「更换」或「绑定」；不可修改时只读显示。
    @ViewBuilder
    private func emailRow(_ info: AccountSecurityInfo) -> some View {
        let value = emailValue(info)
        if canChangeEmail(info) {
            actionRow(
                titleKey: "account.security.email",
                symbol: "envelope",
                value: value,
                actionKey: info.isEmailBound == true ? "account.security.email.change" : "account.security.email.bind"
            ) {
                openCredentialChange(.email, info)
            }
            .accessibilityIdentifier("account-security-email")
        } else {
            statusRow(titleKey: "account.security.email", symbol: "envelope", value: value)
                .accessibilityIdentifier("account-security-email")
        }
    }

    /// Apple 行：未关联、且当前环境开放 App 内关联时整行可点，行尾是「关联」；已关联或不开放时只读。
    ///
    /// 已关联的不提供解除或更换，避免误操作让账号失去登录方式。
    ///
    /// - Parameters:
    ///   - info: 账号信息。
    ///   - isLinked: 是否已关联 Apple（读得到时才显示这一行）。
    @ViewBuilder
    private func appleRow(_ info: AccountSecurityInfo, isLinked: Bool) -> some View {
        let value = text(isLinked ? "account.security.apple.linked" : "account.security.apple.unlinked")
        if !isLinked, AuthConfig.isAppleLinkAvailable {
            actionRow(
                titleKey: "account.security.apple",
                symbol: AuthSocialProvider.apple.systemImage,
                value: value,
                actionKey: "account.security.apple.link"
            ) {
                openCredentialChange(.apple, info)
            }
            .accessibilityIdentifier("account-security-apple")
        } else {
            statusRow(titleKey: "account.security.apple", symbol: AuthSocialProvider.apple.systemImage, value: value)
                .accessibilityIdentifier("account-security-apple")
        }
    }

    /// 密码行：可修改时整行可点，行尾是「修改」或「设置」；不可修改时只读显示「已设置」「未设置」。
    ///
    /// - Parameters:
    ///   - info: 账号信息。
    ///   - hasPassword: 是否已设置密码（读得到时才显示这一行）。
    @ViewBuilder
    private func passwordRow(_ info: AccountSecurityInfo, hasPassword: Bool) -> some View {
        let value = text(hasPassword ? "account.security.password.set" : "account.security.password.unset")
        if AuthConfig.isPasswordChangeAvailable {
            actionRow(
                titleKey: "account.security.password",
                symbol: "key",
                value: value,
                actionKey: hasPassword ? "account.security.password.change" : "account.security.password.set_action"
            ) {
                openCredentialChange(.password, info)
            }
            .accessibilityIdentifier("account-security-password")
        } else {
            statusRow(titleKey: "account.security.password", symbol: "key", value: value)
                .accessibilityIdentifier("account-security-password")
        }
    }

    /// 需要重新登录一次的卡片：说明原因，带重新登录按钮。
    private var reauthenticationCard: some View {
        ProfileSettingsSection(nil, seed: "account.security.reauth") {
            VStack(alignment: .leading, spacing: 12) {
                Text(text("account.security.reauth.message"))
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)

                if let reauthFailureMessage {
                    Text(reauthFailureMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    Task { await reauthenticate() }
                } label: {
                    if isReauthenticating {
                        ProgressView()
                    } else {
                        Text(text("account.security.reauth.action"))
                    }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .disabled(authStore.isBusy || authStore.isDeletingAccount)
                .accessibilityIdentifier("account-security-reauth-action")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("account-security-reauth")
    }

    /// 加载失败的卡片，带重试按钮。
    private func failureCard(_ error: AccountProfileError) -> some View {
        ProfileSettingsSection(nil, seed: "account.security.failure") {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(text("account.security.load_failed"))
                        .font(.subheadline)
                    Text(text(Self.loadFailureDetailKey(for: error)))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(text("common.retry")) {
                    Task { await load() }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .accessibilityIdentifier("account-security-retry")
            }
            .padding(20)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("account-security-failure")
    }

    /// 页面底部的注销芽豆账号，单独成卡；不依赖账号信息，加载失败时也可以注销。
    private var deleteAccountSection: some View {
        ProfileSettingsSection(nil, seed: "account.security.delete") {
            Button {
                isDeletionSheetPresented = true
            } label: {
                Label(text("account.delete.action"), systemImage: "person.crop.circle.badge.xmark")
            }
            .labelStyle(ProfileExportLabelStyle(color: .red))
            .disabled(authStore.isBusy || authStore.isDeletingAccount)
            .accessibilityIdentifier("settings-delete-account")
        }
    }

    /// 可点的一行：图标、标题、当前状态，行尾是强调色的动作文字（如「更换」「设置」）和箭头。
    ///
    /// 账号正在登录 / 注销时不可点。
    ///
    /// - Parameters:
    ///   - titleKey: 标题文案键。
    ///   - symbol: 左侧的系统图标。
    ///   - value: 当前状态（已本地化）。
    ///   - actionKey: 行尾动作的文案键。
    ///   - action: 点击后执行的动作。
    private func actionRow(
        titleKey: String,
        symbol: String,
        value: String,
        actionKey: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Label(text(titleKey), systemImage: symbol)
                    .labelStyle(ProfileSettingsLabelStyle())
                Spacer(minLength: 4)
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(text(actionKey))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .font(.body)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .disabled(authStore.isBusy || authStore.isDeletingAccount)
    }

    /// 只读的一行：图标、标题和行尾的状态，没有箭头。
    private func statusRow(titleKey: String, symbol: String, value: String) -> some View {
        HStack(spacing: 12) {
            Label(text(titleKey), systemImage: symbol)
                .labelStyle(ProfileSettingsLabelStyle())
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
        }
        .font(.body)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(minHeight: 60)
        .accessibilityElement(children: .combine)
    }

    // MARK: - 状态

    /// 邮箱行的值：有地址时显示打码地址，只知道已绑定时显示「已绑定」，读不到时显示「暂时读不到」。
    private func emailValue(_ info: AccountSecurityInfo) -> String {
        if let email = info.trimmedPrimaryEmail {
            return AccountEmail.masked(email)
        }
        switch info.isEmailBound {
        case true?: return text("account.security.email.bound")
        case false?: return text("account.security.email.unbound")
        case nil: return text("account.security.value.unknown")
        }
    }

    /// 读取账号信息失败时卡片里的说明文案键。
    ///
    /// 网络问题沿用通用的网络提示；其余（如账户中心没开 `account_center.not_enabled`）用读取场景的说明，
    /// 不用 `AccountProfileError.localizationKey`，那是修改场景的文案（「暂时无法修改…」）。
    ///
    /// - Parameter error: 读取失败的原因。
    static func loadFailureDetailKey(for error: AccountProfileError) -> String {
        error == .network ? error.localizationKey : "account.security.load_failed.detail"
    }

    /// 邮箱行是否可点：环境开放邮箱账号、会话已有 `email` scope，且有办法验证身份（暂时无法验证时仍可点进去看说明）。
    private func canChangeEmail(_ info: AccountSecurityInfo) -> Bool {
        AuthConfig.isEmailAccountAvailable
            && !info.needsReauthentication(isEmailAccountAvailable: AuthConfig.isEmailAccountAvailable)
            && info.isEmailBound != nil
    }

    // MARK: - 操作

    /// 读取账号信息；已有内容时刷新期间保留原内容。
    private func load() async {
        guard authStore.isAuthenticated else { return }
        if case .loaded = loadState {} else {
            loadState = .loading
        }
        do {
            let info = try await authStore.makeAccountSecurityClient().fetchAccount()
            loadState = .loaded(info)
        } catch {
            loadState = .failed((error as? AccountProfileError) ?? .unknown(nil))
        }
    }

    /// 打开改邮箱、改密码或关联 Apple 的弹层，每次新建流程。
    ///
    /// - Parameters:
    ///   - target: 要修改的登录方式。
    ///   - info: 当前的账号信息。
    private func openCredentialChange(_ target: AccountCredentialChangeFlow.Target, _ info: AccountSecurityInfo) {
        let authStore = authStore
        credentialFlow = AccountCredentialChangeFlow(
            target: target,
            account: info,
            service: authStore.makeAccountSecurityClient(),
            reauthenticate: { await authStore.reauthenticate(requiringStepUp: true) }
        )
    }

    /// 改邮箱、改密码、关联 Apple 的弹层关闭：已退出登录（step-up 时换了账号）时返回设置页，否则重新读取账号信息。
    private func credentialFlowDidDismiss() {
        dismissIfSignedOut()
        guard authStore.isAuthenticated else { return }
        Task { await load() }
    }

    /// 重新登录一次，让会话拿到新增的 `email` / `identities` scope；回来的是同一账号时刷新账号信息，并提示已重新登录。
    private func reauthenticate() async {
        reauthFailureMessage = nil
        isReauthenticating = true
        defer { isReauthenticating = false }
        switch await authStore.reauthenticate(requiringStepUp: false) {
        case .succeeded:
            // 重新登录卡片随刷新消失，补一条提示，免得看起来像什么都没发生
            toast = .success(text("account.security.reauth.succeeded"), accessibilityIdentifier: "account-security-toast")
            await load()
        case .cancelled:
            break
        case .switchedAccount:
            isAccountSwitchedAlertPresented = true
        case let .failed(detail):
            reauthFailureMessage = "\(text("account.security.reauth.failed"))\n\(detail)"
        }
    }

    /// 已退出登录、且没有进行中的操作和待看的提示时返回设置页，只返回一次。
    private func dismissIfSignedOut() {
        guard !authStore.isAuthenticated,
              !hasRequestedDismiss,
              !authStore.isDeletingAccount,
              !isDeletionSheetPresented,
              !isReauthenticating,
              credentialFlow == nil,
              !isAccountSwitchedAlertPresented
        else { return }
        hasRequestedDismiss = true
        dismiss()
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

#Preview {
    NavigationStack { AccountSecurityView() }
        .environment(AuthStore())
        .modelContainer(for: [Account.self, AccountTransaction.self, BookkeepingPreference.self], inMemory: true)
}
