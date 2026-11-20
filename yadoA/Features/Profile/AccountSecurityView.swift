import SwiftData
import SwiftUI

/// “我的 › 设置 › 账号与安全”：芽豆账号的用户名、登录方式（Apple、邮箱、密码），以及注销芽豆账号。
///
/// 账号信息来自 Logto Account API（`GET /api/my-account`），进入页面时读取，改邮箱、改密码、关联 Apple 的弹层关闭后再读一次。
/// 邮箱行在 `AuthConfig.isEmailAccountAvailable` 打开时可点、密码行在 `AuthConfig.isPasswordChangeAvailable` 打开时可点、
/// Apple 行在未关联且 `AuthConfig.isAppleLinkAvailable` 时可点，都进入 `AccountCredentialChangeView`；否则只读显示。
/// 新增 `email` / `identities` scope 之前登录的会话读不到邮箱，页面顶部提示重新登录一次（同一账号回来后刷新）。
/// 注销流程从设置页原样搬来：两步确认、保留 / 清除本机数据、失败提示和进度都不变；退出登录仍在设置页。
/// 退出登录后（注销完成、重新登录时换了账号、凭证失效）自动返回设置页；要先给用户看的提示关掉后再返回。
/// 入口只在已登录且允许联网时显示，与设置页「账号」分组的条件一致；走路径导航（`ProfileRoute.accountSecurity`），
/// 入口随退出登录消失时页面仍留在栈里。注销进行中盖一层全屏阻断层（`AccountDeletionProgressView`），
/// Tab Bar 和返回都点不到，页面不会被移出栈；结果提示等阻断层完全关掉后再弹。
struct AccountSecurityView: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    /// 全局登录状态。
    @Environment(AuthStore.self) private var authStore
    /// 云端同步的绑定状态，注销时据此处理本机数据；预览中没有注入时为 nil，此时注销不执行。
    @Environment(SyncLifecycle.self) private var syncLifecycle: SyncLifecycle?
    /// AI 点数状态，注销时关闭当前账号的“帮助改进 AI”授权；预览中没有注入时为 nil。
    @Environment(AIPointsStore.self) private var aiPoints: AIPointsStore?

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
    /// 注销账号第一步：提醒芽豆系列所有 App 共用这一个芽豆账号、注销会影响全部 App，并说明会发生什么。
    @State private var isDeleteAccountWarningPresented = false
    /// 注销账号第二步：选择本机账本保留还是清除。
    @State private var isDeleteAccountChoicePresented = false
    /// 注销没有完成（服务端调用失败），本机数据和登录状态不变；AI 数据、意见反馈数据可能已删除，三个注销接口都可重复调用，重试即可完成。
    @State private var isDeleteAccountFailurePresented = false
    /// 服务端已注销，但本机数据没清掉。
    @State private var isDeleteAccountLocalCleanupFailurePresented = false
    /// 注销进行中的全屏阻断层是否要显示。
    @State private var isDeletionCoverPresented = false
    /// 阻断层是否已经真正出现；没出现过就不会有 onDismiss，结果要直接给。
    @State private var isDeletionCoverShown = false
    /// 注销已结束、等阻断层关掉后再处理的结果（弹哪个提示、是否返回设置页）。
    @State private var pendingDeletionOutcome: AccountDeletionOutcome?

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
        .alert(text("account.delete.warning.title"), isPresented: $isDeleteAccountWarningPresented) {
            Button(text("account.delete.warning.continue"), role: .destructive) {
                isDeleteAccountChoicePresented = true
            }
            .accessibilityIdentifier("settings-delete-account-continue")

            Button(text("common.cancel"), role: .cancel) {}
        } message: {
            Text(text("account.delete.warning.message"))
        }
        .confirmationDialog(
            text("account.delete.choice.title"),
            isPresented: $isDeleteAccountChoicePresented,
            titleVisibility: .visible
        ) {
            Button(text("account.delete.choice.keep"), role: .destructive) {
                Task { await deleteAccount(.keepOnDevice) }
            }
            .accessibilityIdentifier("settings-delete-account-keep")

            Button(text("account.delete.choice.erase"), role: .destructive) {
                Task { await deleteAccount(.eraseFromDevice) }
            }
            .accessibilityIdentifier("settings-delete-account-erase")

            Button(text("common.cancel"), role: .cancel) {}
        } message: {
            Text(text("account.delete.choice.message"))
        }
        // 注销进行中盖住整个界面（含 Tab Bar），不能手势关闭；关掉后在 onDismiss 里再弹结果提示，避免提示被正在关闭的弹层吞掉
        .fullScreenCover(isPresented: $isDeletionCoverPresented, onDismiss: deletionCoverDidDismiss) {
            AccountDeletionProgressView()
                .onAppear { isDeletionCoverShown = true }
        }
        .alert(text("account.delete.failed"), isPresented: $isDeleteAccountFailurePresented) {
            Button(text("common.close"), role: .cancel) {}
        }
        .alert(text("account.delete.local_cleanup_failed"), isPresented: $isDeleteAccountLocalCleanupFailurePresented) {
            Button(text("common.close"), role: .cancel) {}
        }
        // 退出登录后返回设置页；正在进行的操作或要先给用户看的提示结束后再返回
        .onChange(of: authStore.isAuthenticated) { dismissIfSignedOut() }
        .onChange(of: authStore.isDeletingAccount) { dismissIfSignedOut() }
        .onChange(of: isReauthenticating) { dismissIfSignedOut() }
        .onChange(of: isAccountSwitchedAlertPresented) { dismissIfSignedOut() }
        .onChange(of: isDeleteAccountLocalCleanupFailurePresented) { dismissIfSignedOut() }
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
            HStack {
                Button {
                    isDeleteAccountWarningPresented = true
                } label: {
                    Label(text("account.delete.action"), systemImage: "person.crop.circle.badge.xmark")
                }
                .labelStyle(ProfileExportLabelStyle(color: .red))
                .disabled(authStore.isBusy || authStore.isDeletingAccount)
                .accessibilityIdentifier("settings-delete-account")

                if authStore.isDeletingAccount {
                    ProgressView()
                        .padding(.trailing, 20)
                }
            }
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

    /// 重新登录一次，让会话拿到新增的 `email` / `identities` scope；回来的是同一账号时刷新账号信息。
    private func reauthenticate() async {
        reauthFailureMessage = nil
        isReauthenticating = true
        defer { isReauthenticating = false }
        switch await authStore.reauthenticate(requiringStepUp: false) {
        case .succeeded:
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
              !isDeletionCoverPresented,
              pendingDeletionOutcome == nil,
              !isReauthenticating,
              credentialFlow == nil,
              !isAccountSwitchedAlertPresented,
              !isDeleteAccountLocalCleanupFailurePresented
        else { return }
        hasRequestedDismiss = true
        dismiss()
    }

    /// 注销账号：先让 yado_ai、yado_hub、yadoA_be 三个服务端删除账号和云端数据，成功后处理本机数据并退出登录。
    ///
    /// 删除的是芽豆系列所有 App 共用的芽豆账号（Logto 用户），注销后其他芽豆 App 也无法再用它登录，
    /// 所以第一步警告必须讲明影响全部 App。
    ///
    /// 整个过程盖着全屏阻断层，结果先存进 `pendingDeletionOutcome`，阻断层关掉后由 `deletionCoverDidDismiss()` 处理：
    /// 服务端失败时提示重试（本机数据和登录状态不变）；服务端已注销、本机清理失败时提示可以在设置里重置数据；
    /// 退出登录了的，提示看完（或没有提示）后返回设置页。
    ///
    /// - Parameter choice: 本机账本保留，或一并清除。
    private func deleteAccount(_ choice: SyncSignOutChoice) async {
        guard let syncLifecycle else { return }
        // 标记在 AuthStore 上：设置页据此禁止退出登录
        authStore.setAccountDeletionInProgress(true)
        isDeletionCoverPresented = true
        let startedAt = ContinuousClock.now

        let outcome = await performAccountDeletion(choice, syncLifecycle: syncLifecycle)

        // 阻断层至少显示一小会儿，等出现动画走完再关，避免一出现就关、结果提示被吞掉
        let remaining = Self.minimumDeletionCoverDuration - (ContinuousClock.now - startedAt)
        if remaining > .zero {
            try? await Task.sleep(for: remaining)
        }
        authStore.setAccountDeletionInProgress(false)
        finishDeletion(outcome)
    }

    /// 注销的实际步骤，与原来在设置页时相同：服务端删除 → 关闭“帮助改进 AI”授权 → 清除时顺带删撤销快照和搜索词 → 退出登录。
    ///
    /// 服务端失败时什么都不改、不退出登录；只有“服务端已注销、本机清理失败”仍退出登录，因为账号已经不存在。
    ///
    /// - Parameters:
    ///   - choice: 本机账本保留，或一并清除。
    ///   - syncLifecycle: 同步绑定生命周期。
    /// - Returns: 注销结果。
    private func performAccountDeletion(
        _ choice: SyncSignOutChoice,
        syncLifecycle: SyncLifecycle
    ) async -> AccountDeletionOutcome {
        let api = AccountDeletionAPI(
            aiAccessToken: { try await authStore.accessTokenForAIService() },
            syncAccessToken: { try await authStore.accessTokenForSyncService() },
            hubAccessToken: { try await authStore.accessTokenForHubService() }
        )
        var remoteError: Error?
        do {
            try await syncLifecycle.deleteAccount(choice) {
                try await api.deleteRemoteData()
            }
        } catch {
            remoteError = error
        }
        let outcome = AccountDeletionOutcome(remoteDeletionError: remoteError)
        guard outcome.signsOut else { return outcome }
        // 必须在 signOut 之前、userID 还在时关闭授权
        aiPoints?.setTraceConsented(false)
        if choice == .eraseFromDevice, outcome == .completed {
            DataUndoService(container: modelContext.container).discardSnapshot()
            UserDefaults.standard.removeObject(forKey: BookkeepingSearchHistory.storageKey)
        }
        await authStore.signOut()
        return outcome
    }

    /// 注销结束：记下结果并关掉阻断层；阻断层没出现过（不会有 onDismiss）时直接处理结果。
    private func finishDeletion(_ outcome: AccountDeletionOutcome) {
        pendingDeletionOutcome = outcome
        let needsDirectDelivery = !isDeletionCoverShown
        isDeletionCoverPresented = false
        if needsDirectDelivery {
            deliverPendingDeletionOutcome()
        }
    }

    /// 阻断层完全关掉后处理注销结果。
    private func deletionCoverDidDismiss() {
        isDeletionCoverShown = false
        deliverPendingDeletionOutcome()
    }

    /// 弹出注销结果对应的提示；已退出登录且没有提示要看时返回设置页。只处理一次。
    private func deliverPendingDeletionOutcome() {
        guard let outcome = pendingDeletionOutcome else { return }
        pendingDeletionOutcome = nil
        switch outcome {
        case .failed:
            isDeleteAccountFailurePresented = true
        case .localCleanupFailed:
            isDeleteAccountLocalCleanupFailurePresented = true
        case .completed:
            break
        }
        dismissIfSignedOut()
    }

    /// 注销阻断层至少显示的时长。
    private static let minimumDeletionCoverDuration: Duration = .milliseconds(800)

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

// MARK: - 注销结果与阻断层

/// 注销芽豆账号的结果，决定阻断层关掉后弹哪个提示、是否退出登录。
enum AccountDeletionOutcome: Equatable {
    /// 全部完成：服务端已删除，本机数据已按选择处理，退出登录。
    case completed

    /// 服务端已删除，但本机数据没清掉；账号已经不存在，仍退出登录，提示可以在设置里重置数据。
    case localCleanupFailed

    /// 服务端没删完：本机数据和登录状态不变，提示重试（三个注销接口都可重复调用）。
    case failed

    /// 按 `SyncLifecycle.deleteAccount` 抛出的错误归类。
    ///
    /// - Parameter error: 没有错误时为 nil；`SyncLifecycleError.storage` 表示远端已删、本机处理失败，其余都是服务端没删完。
    init(remoteDeletionError error: Error?) {
        guard let error else {
            self = .completed
            return
        }
        if let lifecycleError = error as? SyncLifecycleError, lifecycleError == .storage {
            self = .localCleanupFailed
        } else {
            self = .failed
        }
    }

    /// 是否要退出登录：服务端已删除（账号已不存在）时都要退出。
    var signsOut: Bool {
        self != .failed
    }
}

/// 注销进行中的全屏阻断层：进度圈、「正在注销芽豆账号…」和「请不要关闭 App」，纸张底色，不能手势关闭。
///
/// VoiceOver 把整块读成一句：标题加说明。
private struct AccountDeletionProgressView: View {
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)

            Text(AccountLocalization.string("account.delete.progress.title", locale: locale))
                .font(.system(.title3, design: .serif, weight: .semibold))

            Text(AccountLocalization.string("account.delete.progress.message", locale: locale))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .paperPage()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("account-deletion-progress")
        .interactiveDismissDisabled()
    }
}

#Preview {
    NavigationStack { AccountSecurityView() }
        .environment(AuthStore())
        .modelContainer(for: [Account.self, AccountTransaction.self, BookkeepingPreference.self], inMemory: true)
}
