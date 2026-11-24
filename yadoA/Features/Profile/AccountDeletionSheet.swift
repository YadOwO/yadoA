import SwiftData
import SwiftUI

/// 注销芽豆账号的弹层：同一页里讲清影响、选本机账本怎么处理、确认注销，进度和结果也在这一页里切换显示。
///
/// 以前是「警告 alert → 选择 confirmationDialog → 全屏阻断层 → 结果 alert」四层系统弹窗接力，
/// 每一层都在上一层的按钮里弹出，上一层还没关完 iOS 就会丢掉或推迟下一层：点了继续没反应、
/// 再点注销才冒出选择框、选择框不选直接关掉后注销按钮再也点不开。现在整个流程只有这一个弹层，不再叠弹窗。
///
/// 本机账本的处理方式没有默认值，必须选一项才能注销，避免误清本机数据。
/// 注销进行中没有取消按钮、不能下滑关闭；弹层盖住整个界面（含 Tab Bar），设置页的退出登录点不到。
/// 服务端没删完时留在这一页，写明原因，可以直接重试（yado_hub 的注销接口可重复调用）；
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

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    switch phase {
                    case let .confirming(lastFailure):
                        confirmingContent(lastFailure: lastFailure)
                    case .deleting:
                        deletingContent
                    case let .finished(outcome):
                        finishedContent(outcome)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 32)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .paperPage()
            .navigationTitle(text("account.delete.action"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isConfirming {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(text("common.cancel"), systemImage: "xmark") {
                            dismiss()
                        }
                        .accessibilityIdentifier("account-deletion-cancel")
                    }
                }
            }
        }
        .interactiveDismissDisabled(phase == .deleting)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("account-deletion")
    }

    // MARK: - 阶段

    /// 是否在确认阶段：只有这时显示取消按钮。
    private var isConfirming: Bool {
        if case .confirming = phase { return true }
        return false
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
            Task { await deleteAccount() }
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

    /// 注销账号：先让 yado_hub 删除各服务里这个账号的数据和 Logto 账号，成功后处理本机数据并退出登录。
    ///
    /// 删除的是芽豆系列所有 App 共用的芽豆账号（Logto 用户），注销后其他芽豆 App 也无法再用它登录，
    /// 所以确认页必须讲明影响全部 App。服务端没删完时回到确认阶段并写明原因；服务端已删除后进入结果阶段。
    private func deleteAccount() async {
        guard let choice, let syncLifecycle, phase != .deleting else { return }
        // 标记在 AuthStore 上：设置页据此禁止退出登录
        authStore.setAccountDeletionInProgress(true)
        phase = .deleting

        let outcome = await performAccountDeletion(choice, syncLifecycle: syncLifecycle)

        authStore.setAccountDeletionInProgress(false)
        phase = AccountDeletionPhase(outcome: outcome)
    }

    /// 注销的实际步骤：服务端删除 → 关闭“帮助改进 AI”授权、清掉联动缓存 → 清除时顺带删撤销快照和搜索词 → 退出登录。
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
        let authStore = authStore
        let api = AccountDeletionAPI(hubAccessToken: { try await authStore.accessTokenForHubService() })
        var remoteError: Error?
        do {
            try await syncLifecycle.deleteAccount(choice) {
                try await api.deleteAccount()
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

// MARK: - 阶段与结果

/// 注销弹层显示的阶段。
enum AccountDeletionPhase: Equatable {
    /// 确认：说明影响、选本机账本处理方式；上次没注销完时带上原因，按钮变成重试。
    case confirming(lastFailure: AccountDeletionFailure?)

    /// 正在调服务端删除和处理本机数据，不能关闭。
    case deleting

    /// 服务端已删除、已退出登录：`.completed` 或 `.localCleanupFailed`。
    case finished(AccountDeletionOutcome)

    /// 注销结束后要显示的阶段：没删完回到确认并带上原因，删完了显示结果。
    ///
    /// - Parameter outcome: 注销结果。
    init(outcome: AccountDeletionOutcome) {
        if case let .failed(failure) = outcome {
            self = .confirming(lastFailure: failure)
        } else {
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
