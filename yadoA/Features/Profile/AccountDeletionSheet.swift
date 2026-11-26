import SwiftData
import SwiftUI

/// 注销芽豆账号的弹层：同一页里讲清影响、选本机账本怎么处理、确认注销，进度和结果也在这一页里切换显示。
///
/// 以前是「警告 alert → 选择 confirmationDialog → 全屏阻断层 → 结果 alert」四层系统弹窗接力，
/// 每一层都在上一层的按钮里弹出，上一层还没关完 iOS 就会丢掉或推迟下一层：点了继续没反应、
/// 再点注销才冒出选择框、选择框不选直接关掉后注销按钮再也点不开。现在整个流程只有这一个弹层，不再叠弹窗。
///
/// 本机账本的处理方式没有默认值，必须选一项才能注销，避免误清本机数据。
/// 确认页还会列出 yado_hub 汇总的各产品云端数据量（芽豆资产的记录数、芽豆有物的物品数、剩余 AI 点数），让用户知道会删掉什么；
/// 查不到时只提示一句，不影响注销。
/// 点注销后要先验证身份（当前邮箱验证码、密码或重新登录，都由 hub 校验），换到 10 分钟有效的注销票据才能调注销接口；
/// 验证身份和数据清单也在这个弹层里切换，不叠系统弹窗。
/// 票据过期或 hub 说票据无效时回到验证身份这一步，已选的本机账本处理方式保留。
/// 注销进行中没有取消按钮、不能下滑关闭；弹层盖住整个界面（含 Tab Bar），设置页的退出登录点不到。
/// 服务端没删完时留在这一页，写明原因，可以直接重试（票据有效期内 yado_hub 的注销接口可重复调用）；
/// 服务端已删除后显示结果，点完成关闭，由「账号与安全」页返回设置页。
struct AccountDeletionSheet: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    /// 全局登录状态。
    @Environment(AuthStore.self) private var authStore
    /// 云端同步的绑定状态，注销时据此处理本机数据；预览中没有注入时为 nil，此时不能注销。
    @Environment(SyncLifecycle.self) private var syncLifecycle: SyncLifecycle?
    /// AI 点数状态，注销时关闭当前账号的“帮助改进 AI”授权；预览中没有注入时为 nil。
    @Environment(AIPointsStore.self) private var aiPoints: AIPointsStore?
    /// 数据联动状态，注销时清掉当前账号的物品估值缓存和设置；预览中没有注入时为 nil。
    @Environment(DataLinkStore.self) private var dataLinks: DataLinkStore?

    /// 用户选的本机账本处理方式；没选时不能注销。
    @State private var choice: SyncSignOutChoice?
    /// 弹层当前显示的阶段。
    @State private var phase: AccountDeletionPhase = .confirming(lastFailure: nil)
    /// 验证身份的流程；第一次需要验证时才创建，之后一直保留（本机账本的选择、已选的验证方式都不丢）。
    @State private var verificationFlow: AccountDeletionVerificationFlow?
    /// 各产品云端数据量的查询状态；只在弹层打开时查一次。
    @State private var summaryState: SummaryState = .loading
    /// 是否已经发起过数据清单查询，保证只查一次。
    @State private var hasRequestedSummary = false
    /// 顶部的轻提示：验证码已发出、身份验证通过时弹出，由 `verificationFlow.notice` 驱动。
    @State private var toast: AppToast?

    /// 各产品云端数据量的查询状态。
    private enum SummaryState: Equatable {
        /// 正在查询。
        case loading

        /// 查到了。
        case loaded(AccountDataSummary)

        /// 整个汇总请求失败，只提示一句，不影响注销。
        case failed
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    switch phase {
                    case let .confirming(lastFailure):
                        confirmingContent(lastFailure: lastFailure)
                    case .verifying:
                        verifyingContent
                    case .deleting:
                        deletingContent
                    case let .finished(outcome):
                        finishedContent(outcome)
                    case .accountSwitched:
                        accountSwitchedContent
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 32)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .paperPage()
            .appToast($toast)
            .navigationTitle(text("account.delete.action"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsCancelButton {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(text("common.cancel"), systemImage: "xmark") {
                            dismiss()
                        }
                        .disabled(verificationFlow?.isWorking == true)
                        .accessibilityIdentifier("account-deletion-cancel")
                    }
                }
            }
        }
        .task {
            await loadSummary()
        }
        .onChange(of: verificationFlow?.verification) { _, verification in
            // 验证身份通过、拿到有效票据后自动开始注销，不用再点一次
            guard phase == .verifying, verification != nil, let ticket = verificationFlow?.validTicket() else { return }
            Task { await deleteAccount(ticket: ticket) }
        }
        .onChange(of: verificationFlow?.isAccountSwitched) { _, isSwitched in
            if isSwitched == true {
                phase = .accountSwitched
            }
        }
        .onChange(of: verificationFlow?.notice) { _, notice in
            guard let notice else { return }
            toast = .success(
                text(notice.localizationKey),
                systemImage: notice.kind == .codeSent ? "paperplane.fill" : "checkmark.circle.fill",
                accessibilityIdentifier: "account-deletion-verify-toast"
            )
        }
        .interactiveDismissDisabled(phase == .deleting || verificationFlow?.isWorking == true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("account-deletion")
    }

    // MARK: - 阶段

    /// 是否显示取消按钮：确认和验证身份两个阶段可以取消；注销进行中和结果页不能。
    private var showsCancelButton: Bool {
        switch phase {
        case .confirming, .verifying: true
        case .deleting, .finished, .accountSwitched: false
        }
    }

    /// 确认阶段：影响说明、本机账本二选一、上次失败的原因和注销按钮。
    ///
    /// - Parameter lastFailure: 上一次注销没完成的原因；第一次进入时为 nil。
    private func confirmingContent(lastFailure: AccountDeletionFailure?) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(spacing: 14) {
                Image(systemName: "person.crop.circle.badge.xmark")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)

                Text(text("account.delete.warning.title"))
                    .font(.system(.title3, design: .serif, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
            }
            .frame(maxWidth: .infinity)

            Text(text("account.delete.warning.message"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("account-deletion-warning")

            // 汇总只是告诉用户会删掉什么，查不到也不影响下面的注销按钮
            if authStore.isAuthenticated {
                summarySection
            }

            ProfileSettingsSection("account.delete.choice.title") {
                choiceRow(.keepOnDevice, titleKey: "account.delete.choice.keep.option", detailKey: "account.delete.choice.keep.detail")
                    .accessibilityIdentifier("account-deletion-keep")

                ProfileSettingsRowDivider()

                choiceRow(.eraseFromDevice, titleKey: "account.delete.choice.erase.option", detailKey: "account.delete.choice.erase.detail")
                    .accessibilityIdentifier("account-deletion-erase")
            }

            if let lastFailure {
                failureNotice(lastFailure)
            }

            VStack(spacing: 10) {
                if authStore.isAuthenticated {
                    deleteButton(isRetry: lastFailure != nil)
                } else {
                    // 登录已失效（凭证已清除）时没法重试，只能关掉后重新登录
                    Button {
                        dismiss()
                    } label: {
                        ProfilePrimaryButtonLabel(title: text("common.close"))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("account-deletion-close")
                }

                if choice == nil, authStore.isAuthenticated {
                    Text(text("account.delete.choice.required"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }
    }

    /// 数据清单：各产品里这个账号的云端数据量，查询中显示转圈，查不到时提示一句。
    private var summarySection: some View {
        ProfileSettingsSection("account.delete.summary.title") {
            switch summaryState {
            case .loading:
                HStack(spacing: 12) {
                    ProgressView()
                    summaryText(text("account.delete.summary.loading"), isSecondary: true)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            case let .loaded(summary):
                let rows = summary.rows
                if rows.isEmpty {
                    summaryRowView(text("account.delete.summary.empty"), isSecondary: true)
                } else {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            ProfileSettingsRowDivider()
                        }
                        summaryRowView(summaryRowText(row), isSecondary: row.isUnavailable)
                    }
                }
            case .failed:
                summaryRowView(text("account.delete.summary.failed"), isSecondary: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("account-deletion-summary")
    }

    /// 数据清单里的一行文字。
    ///
    /// - Parameters:
    ///   - message: 已本地化的文字。
    ///   - isSecondary: 是否用次要色（说明性文字、查不到的产品）。
    private func summaryRowView(_ message: String, isSecondary: Bool) -> some View {
        summaryText(message, isSecondary: isSecondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 数据清单的文字样式。
    private func summaryText(_ message: String, isSecondary: Bool) -> some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(isSecondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 把一行数据清单变成要显示的整句文字。
    ///
    /// - Parameter row: 一行数据清单。
    private func summaryRowText(_ row: AccountDataSummaryRow) -> String {
        switch row {
        case let .count(titleKey, count):
            String(format: text(titleKey), locale: locale, count)
        case let .unavailable(productNameKey):
            String(format: text("account.delete.summary.unavailable"), locale: locale, text(productNameKey))
        }
    }

    /// 验证身份阶段：邮箱验证码、密码或重新登录，通过后自动接着注销。
    @ViewBuilder
    private var verifyingContent: some View {
        if let verificationFlow {
            AccountDeletionVerifyContent(flow: verificationFlow) {
                phase = .confirming(lastFailure: nil)
            }
        }
    }

    /// 注销进行中：进度圈、「正在注销芽豆账号…」和「请不要关闭 App」。VoiceOver 把整块读成一句。
    private var deletingContent: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)

            Text(text("account.delete.progress.title"))
                .font(.system(.title3, design: .serif, weight: .semibold))

            Text(text("account.delete.progress.message"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("account-deletion-progress")
    }

    /// 服务端已删除：账号已注销、已退出登录；本机账本没清掉时说明可以在设置里重置。
    ///
    /// - Parameter outcome: `.completed` 或 `.localCleanupFailed`。
    private func finishedContent(_ outcome: AccountDeletionOutcome) -> some View {
        VStack(spacing: 16) {
            Image(systemName: outcome == .completed ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(outcome == .completed ? Color.accentColor : Color.orange)
                .accessibilityHidden(true)
                .padding(.top, 12)

            Text(text("account.delete.finished.title"))
                .font(.system(.title3, design: .serif, weight: .semibold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text(text(outcome == .completed ? "account.delete.finished.message" : "account.delete.local_cleanup_failed"))
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
            .accessibilityIdentifier("account-deletion-done")
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(outcome == .completed ? "account-deletion-completed" : "account-deletion-local-cleanup-failed")
    }

    /// 重新登录时登录了另一个账号：已退出登录，没有注销任何账号，点完成关闭。
    private var accountSwitchedContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Color.orange)
                .accessibilityHidden(true)
                .padding(.top, 12)

            Text(text("account.reauth.switched.title"))
                .font(.system(.title3, design: .serif, weight: .semibold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text(text("account.reauth.switched.message"))
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
            .accessibilityIdentifier("account-deletion-switched-done")
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("account-deletion-account-switched")
    }

    // MARK: - 组件

    /// 本机账本处理方式的一行：标题、说明和行尾的选中圈，整行可点。
    ///
    /// - Parameters:
    ///   - option: 这一行代表的处理方式。
    ///   - titleKey: 标题文案键。
    ///   - detailKey: 说明文案键。
    private func choiceRow(_ option: SyncSignOutChoice, titleKey: String, detailKey: String) -> some View {
        let isSelected = choice == option
        return Button {
            choice = option
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(text(titleKey))
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(text(detailKey))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// 上次注销没完成：写明原因，并提醒部分数据可能已删、重试即可完成。
    ///
    /// - Parameter failure: 没完成的原因。
    private func failureNotice(_ failure: AccountDeletionFailure) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(text("account.delete.failed.title"), systemImage: "exclamationmark.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)

            Text(text(failure.messageKey))
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)

            Text(text("account.delete.failed"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.red.opacity(0.08))
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("account-deletion-failure")
    }

    /// 红色胶囊的注销按钮；没选本机账本处理方式、或正在登录 / 退出时不可点。
    ///
    /// - Parameter isRetry: 上次没注销完，按钮写「重试注销」。
    private func deleteButton(isRetry: Bool) -> some View {
        let canDelete = choice != nil && syncLifecycle != nil && !authStore.isBusy
        return Button {
            Task { await startDeletion() }
        } label: {
            Text(text(isRetry ? "account.delete.retry" : "account.delete.confirm"))
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 36)
                .padding(.vertical, 16)
                .background(Capsule().fill(Color.red))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(canDelete ? 1 : 0.35)
        .disabled(!canDelete)
        .accessibilityIdentifier("account-deletion-confirm")
    }

    // MARK: - 操作

    /// 点注销按钮：已经验证过身份、票据还有效时直接注销；否则进入验证身份阶段。
    ///
    /// 能不能注销只看有没有选本机账本处理方式和登录状态，和数据清单查没查到无关。
    private func startDeletion() async {
        guard choice != nil, syncLifecycle != nil, phase != .deleting else { return }
        if let ticket = verificationFlow?.validTicket() {
            await deleteAccount(ticket: ticket)
            return
        }
        let flow = verificationFlow ?? makeVerificationFlow()
        verificationFlow = flow
        phase = .verifying
        // 上次读账号信息失败时，再点注销就重新读一次
        if flow.method == nil {
            await flow.prepare()
        }
    }

    /// 创建验证身份的流程：用当前登录状态读账号信息、调 hub、发起重新登录（托管页 `max_age=0`）。
    private func makeVerificationFlow() -> AccountDeletionVerificationFlow {
        let authStore = authStore
        return AccountDeletionVerificationFlow(
            account: authStore.makeAccountSecurityClient(),
            hub: makeVerificationAPI(),
            reauthenticate: { await authStore.reauthenticate(requiringStepUp: false, requiringFreshLogin: true) },
            currentIDToken: { authStore.currentIDToken }
        )
    }

    /// 调 hub 注销前验证接口的客户端，用当前登录状态取 hub 的 token。
    private func makeVerificationAPI() -> AccountDeletionVerificationAPI {
        let authStore = authStore
        return AccountDeletionVerificationAPI(hubAccessToken: { try await authStore.accessTokenForHubService() })
    }

    /// 查询各产品的云端数据量，只在弹层打开时查一次；整个请求失败时只记下失败，不影响注销。
    private func loadSummary() async {
        guard authStore.isAuthenticated, !hasRequestedSummary else { return }
        hasRequestedSummary = true
        do {
            let summary = try await makeVerificationAPI().fetchSummary()
            summaryState = .loaded(summary)
        } catch {
            summaryState = .failed
        }
    }

    /// 注销账号：先让 yado_hub 删除各服务里这个账号的数据和 Logto 账号，成功后处理本机数据并退出登录。
    ///
    /// 删除的是芽豆系列所有 App 共用的芽豆账号（Logto 用户），注销后其他芽豆 App 也无法再用它登录，
    /// 所以确认页必须讲明影响全部 App。服务端没删完时回到确认阶段并写明原因；服务端已删除后进入结果阶段；
    /// hub 说票据无效或已过期时回到验证身份阶段，已选的本机账本处理方式不变。
    ///
    /// - Parameter ticket: 验证身份后换到的注销票据。
    private func deleteAccount(ticket: String) async {
        guard let choice, let syncLifecycle, phase != .deleting else { return }
        // 标记在 AuthStore 上：设置页据此禁止退出登录
        authStore.setAccountDeletionInProgress(true)
        phase = .deleting

        let outcome = await performAccountDeletion(choice, ticket: ticket, syncLifecycle: syncLifecycle)

        authStore.setAccountDeletionInProgress(false)
        if case .failed(.verificationRequired) = outcome {
            verificationFlow?.invalidate()
        }
        phase = AccountDeletionPhase(outcome: outcome)
    }

    /// 注销的实际步骤：服务端删除 → 关闭“帮助改进 AI”授权、清掉联动缓存 → 清除时顺带删撤销快照和搜索词 → 退出登录。
    ///
    /// 服务端失败时什么都不改、不退出登录；只有“服务端已注销、本机清理失败”仍退出登录，因为账号已经不存在。
    ///
    /// - Parameters:
    ///   - choice: 本机账本保留，或一并清除。
    ///   - ticket: 注销票据，放进注销请求的请求头。
    ///   - syncLifecycle: 同步绑定生命周期。
    /// - Returns: 注销结果。
    private func performAccountDeletion(
        _ choice: SyncSignOutChoice,
        ticket: String,
        syncLifecycle: SyncLifecycle
    ) async -> AccountDeletionOutcome {
        let authStore = authStore
        let api = AccountDeletionAPI(hubAccessToken: { try await authStore.accessTokenForHubService() })
        var remoteError: Error?
        do {
            try await syncLifecycle.deleteAccount(choice) {
                try await api.deleteAccount(ticket: ticket)
            }
        } catch {
            remoteError = error
        }
        let outcome = AccountDeletionOutcome(remoteDeletionError: remoteError)
        guard outcome.signsOut else { return outcome }
        // 必须在 signOut 之前、userID 还在时关闭授权
        aiPoints?.setTraceConsented(false)
        // 同样要在 signOut 之前：清掉这个账号的物品估值缓存和设置；服务端的授权记录已由 hub 在注销时删除
        dataLinks?.forgetCurrentUser()
        if choice == .eraseFromDevice, outcome == .completed {
            DataUndoService(container: modelContext.container).discardSnapshot()
            UserDefaults.standard.removeObject(forKey: BookkeepingSearchHistory.storageKey)
        }
        await authStore.signOut()
        return outcome
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

// MARK: - 验证身份

/// 注销弹层里「验证身份」这一阶段的内容：按验证方式显示邮箱验证码、密码或重新登录的入口，错误提示在下方，可以返回确认页。
///
/// 流程状态全在 `AccountDeletionVerificationFlow`，通过后由弹层接着注销；这里只负责画界面。
/// 重发验证码有 60 秒倒计时，验证码输入框用 `.oneTimeCode`，可以直接填入邮件里的验证码建议。
private struct AccountDeletionVerifyContent: View {
    @Environment(\.locale) private var locale

    /// 验证身份的流程。
    @Bindable var flow: AccountDeletionVerificationFlow

    /// 点「返回」：回到确认页。
    let onBack: () -> Void

    /// 当前聚焦的输入框。
    @FocusState private var focusedField: Field?

    /// 阶段里的输入框。
    private enum Field: Hashable {
        case password
        case code
    }

    /// - Parameters:
    ///   - flow: 验证身份的流程。
    ///   - onBack: 点「返回」时回到确认页的动作。
    init(flow: AccountDeletionVerificationFlow, onBack: @escaping () -> Void) {
        _flow = Bindable(flow)
        self.onBack = onBack
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(text("account.email.identity.title"))
                .font(.system(.title3, design: .serif, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            explanation(text("account.delete.verify.message"))

            methodContent

            if let messageKey = flow.messageKey {
                Text(text(messageKey))
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("account-deletion-verify-message")
            }

            Button(action: onBack) {
                Text(text("account.delete.verify.back"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(flow.isWorking ? Color.secondary : Color.primary)
                    .underline()
                    .padding(.vertical, 6)
                    .padding(.horizontal, 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(flow.isWorking)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("account-deletion-verify-back")
        }
        .onChange(of: flow.method) { _, method in
            if method == .password {
                focusedField = .password
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("account-deletion-verify")
    }

    // MARK: - 验证方式

    /// 按验证方式显示的内容；还没读到账号信息时转圈，读取失败时给一个重新加载按钮。
    @ViewBuilder
    private var methodContent: some View {
        switch flow.method {
        case nil:
            if flow.messageKey == nil {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .accessibilityIdentifier("account-deletion-verify-loading")
            } else {
                primaryButton("account.delete.verify.reload", isEnabled: true) {
                    await flow.prepare()
                }
                .accessibilityIdentifier("account-deletion-verify-reload")
            }

        case .password?:
            field("account.email.identity.password.field") {
                SecureField(text("account.email.identity.password.placeholder"), text: $flow.password)
                    .textContentType(.password)
                    .submitLabel(.continue)
                    .focused($focusedField, equals: .password)
                    .onSubmit { Task { await flow.submitPassword() } }
                    .accessibilityIdentifier("account-deletion-verify-password")
            }

            primaryButton("account.email.next", isEnabled: !flow.password.isEmpty) {
                await flow.submitPassword()
            }
            .accessibilityIdentifier("account-deletion-verify-submit")

        case let .currentEmailCode(email)?:
            explanation(format("account.email.identity.code.message", AccountEmail.masked(email)))

            if flow.isIdentityCodeSent {
                field("account.email.code.field") {
                    TextField(text("account.email.code.placeholder"), text: $flow.identityCode)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .autocorrectionDisabled()
                        .monospacedDigit()
                        // 占位文字保持正常字距，只给输入的数字拉开
                        .kerning(flow.identityCode.isEmpty ? 0 : 4)
                        .onChange(of: flow.identityCode) { _, newValue in
                            let sanitized = AccountCredentialChangeFlow.sanitizedCode(newValue)
                            if sanitized != newValue {
                                flow.identityCode = sanitized
                            }
                        }
                        .focused($focusedField, equals: .code)
                        .onSubmit { Task { await flow.submitIdentityCode() } }
                        .accessibilityIdentifier("account-deletion-verify-code")
                }

                Text(text("account.email.code.spam_hint"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("account-deletion-verify-spam-hint")

                resendButton

                primaryButton("account.email.next", isEnabled: flow.isIdentityCodeComplete) {
                    await flow.submitIdentityCode()
                }
                .accessibilityIdentifier("account-deletion-verify-submit")
            } else {
                primaryButton("account.email.code.send", isEnabled: true) {
                    await flow.sendIdentityCode()
                    if flow.isIdentityCodeSent {
                        focusedField = .code
                    }
                }
                .accessibilityIdentifier("account-deletion-verify-send")
            }

        case .stepUp?:
            explanation(text("account.delete.verify.step_up.message"))

            primaryButton("account.email.step_up.action", isEnabled: true) {
                await flow.startStepUp()
            }
            .accessibilityIdentifier("account-deletion-verify-step-up")

        case .unavailable?:
            // 注销时 unavailable 已改走 step-up，走不到这里；兜底给一句说明
            explanation(text("account.email.identity.unavailable"))
        }
    }

    // MARK: - 组件

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

    /// 重发验证码的按钮，冷却中显示剩余秒数并禁用；每秒刷新一次。
    private var resendButton: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = EmailCodeCooldown.remainingSeconds(sentAt: flow.identityCodeSentAt, now: context.date)
            Button {
                Task { await flow.sendIdentityCode() }
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
            .accessibilityIdentifier("account-deletion-verify-resend")
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

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }

    /// 按应用当前语言解析带一个参数的文案。
    private func format(_ key: String, _ argument: CVarArg) -> String {
        String(format: text(key), locale: locale, argument)
    }
}

// MARK: - 阶段与结果

/// 注销弹层显示的阶段。
enum AccountDeletionPhase: Equatable {
    /// 确认：说明影响、选本机账本处理方式；上次没注销完时带上原因，按钮变成重试。
    case confirming(lastFailure: AccountDeletionFailure?)

    /// 验证身份：邮箱验证码、密码或重新登录，通过后拿到注销票据再自动开始注销；上次的本机账本选择保留。
    case verifying

    /// 正在调服务端删除和处理本机数据，不能关闭。
    case deleting

    /// 服务端已删除、已退出登录：`.completed` 或 `.localCleanupFailed`。
    case finished(AccountDeletionOutcome)

    /// 重新登录时登录了另一个账号，已退出登录，没有注销任何账号。
    case accountSwitched

    /// 注销结束后要显示的阶段：票据失效回到验证身份，没删完回到确认并带上原因，删完了显示结果。
    ///
    /// - Parameter outcome: 注销结果。
    init(outcome: AccountDeletionOutcome) {
        switch outcome {
        case .failed(.verificationRequired):
            self = .verifying
        case let .failed(failure):
            self = .confirming(lastFailure: failure)
        case .completed, .localCleanupFailed:
            self = .finished(outcome)
        }
    }
}

/// 注销芽豆账号的结果，决定弹层显示哪个阶段、是否退出登录。
enum AccountDeletionOutcome: Equatable {
    /// 全部完成：服务端已删除，本机数据已按选择处理，退出登录。
    case completed

    /// 服务端已删除，但本机数据没清掉；账号已经不存在，仍退出登录，提示可以在设置里重置数据。
    case localCleanupFailed

    /// 服务端没删完：本机数据和登录状态不变（登录已失效的除外），提示原因并可重试。
    case failed(AccountDeletionFailure)

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
            self = .failed(AccountDeletionFailure(error))
        }
    }

    /// 是否要退出登录：服务端已删除（账号已不存在）时都要退出。
    var signsOut: Bool {
        if case .failed = self { return false }
        return true
    }
}

/// 服务端没删完的原因，给用户看的提示据此区分。
enum AccountDeletionFailure: Equatable {
    /// 网络不可用或请求超时。
    case network

    /// 服务暂时不可用，或返回了不符合契约的响应（例如接口还没部署返回 404）。
    case serviceUnavailable

    /// 登录已失效或凭证被拒绝，需要重新登录后再注销。
    case sessionExpired

    /// App 版本过低，需要先升级。
    case upgradeRequired

    /// 注销票据无效或已过期，需要回到验证身份这一步重新验证；不会作为失败原因显示，只用来切换阶段。
    case verificationRequired

    /// 按注销接口或同步层抛出的错误归类；认不出的错误按服务暂时不可用处理。
    ///
    /// - Parameter error: `AccountDeletionAPIError`、`ServiceAuthError` 或 `SyncLifecycleError`。
    init(_ error: Error) {
        switch error {
        case let apiError as AccountDeletionAPIError:
            switch apiError {
            case .network, .timeout: self = .network
            case .notSignedIn, .sessionExpired, .unauthorized: self = .sessionExpired
            case .upgradeRequired: self = .upgradeRequired
            case .verificationRequired: self = .verificationRequired
            case .serviceUnavailable, .invalidContract: self = .serviceUnavailable
            }
        case let authError as ServiceAuthError:
            self = authError == .unavailable ? .network : .sessionExpired
        case let lifecycleError as SyncLifecycleError:
            self = lifecycleError == .api(.network) ? .network : .serviceUnavailable
        default:
            self = .serviceUnavailable
        }
    }

    /// 原因说明的文案键。
    var messageKey: String {
        switch self {
        case .network: "account.delete.failed.network"
        case .serviceUnavailable: "account.delete.failed.service"
        case .sessionExpired: "account.delete.failed.session"
        case .upgradeRequired: "account.delete.failed.upgrade"
        case .verificationRequired: "account.email.error.verification_required"
        }
    }
}

#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            AccountDeletionSheet()
        }
        .environment(AuthStore())
        .modelContainer(for: [Account.self, AccountTransaction.self, BookkeepingPreference.self], inMemory: true)
}
