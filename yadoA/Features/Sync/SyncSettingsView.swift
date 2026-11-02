import SwiftUI

/// 「我的 → 云端同步」：同步开关、同步状态、立即同步和删除云端数据。
///
/// 开关、绑定等状态来自 `SyncLifecycle`，同步进度和失败原因来自 `SyncEngine`；两者都由 `syncEngineHost()` 注入。
struct SyncSettingsView: View {
    @Environment(\.locale) private var locale
    @Environment(AuthStore.self) private var authStore
    @Environment(SignInPresentation.self) private var signInPresentation
    @Environment(SyncEngine.self) private var engine: SyncEngine?
    @Environment(SyncLifecycle.self) private var lifecycle: SyncLifecycle?

    /// 开启、关闭或删除云端数据进行中，期间禁用操作。
    @State private var isWorking = false

    /// 删除云端数据前的二次确认。
    @State private var isDeleteConfirmationPresented = false

    /// 操作失败时的文案键。
    @State private var errorKey: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                statusCard

                if canManageSync {
                    section("sync.section.sync") {
                        Toggle(isOn: enabledBinding) {
                            Label(text("sync.toggle.title"), systemImage: "arrow.triangle.2.circlepath.icloud")
                                .labelStyle(SyncSettingsLabelStyle())
                        }
                        .disabled(isWorking)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .accessibilityIdentifier("sync-toggle")

                        if isSyncEnabled {
                            rowDivider

                            Button {
                                Task { await synchronizeNow() }
                            } label: {
                                Label(text("sync.now.action"), systemImage: "arrow.clockwise")
                                    .labelStyle(SyncSettingsRowLabelStyle())
                            }
                            .disabled(isWorking || engine?.status == .syncing)
                            .accessibilityIdentifier("sync-now")
                        }
                    }

                    section("sync.section.cloudData", footerKey: "sync.delete.footer") {
                        Button {
                            isDeleteConfirmationPresented = true
                        } label: {
                            Label(text("sync.delete.action"), systemImage: "trash")
                                .labelStyle(SyncSettingsRowLabelStyle(color: .red))
                        }
                        .disabled(isWorking)
                        .accessibilityIdentifier("sync-delete-cloud-data")
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .paperPage()
        .navigationTitle(text("sync.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { lifecycle?.refreshState() }
        .appHaptic(.error, trigger: errorKey != nil) { _, isShown in isShown }
        .alert(text("sync.delete.confirm.title"), isPresented: $isDeleteConfirmationPresented) {
            Button(text("sync.delete.confirm.action"), role: .destructive) {
                Task { await deleteCloudData() }
            }
            .accessibilityIdentifier("sync-delete-confirm")

            Button(text("common.cancel"), role: .cancel) {}
        } message: {
            Text(text("sync.delete.confirm.message"))
        }
        .alert(
            text("sync.error.title"),
            isPresented: Binding(get: { errorKey != nil }, set: { if !$0 { errorKey = nil } })
        ) {
            Button(text("common.close"), role: .cancel) {}
        } message: {
            Text(text(errorKey ?? ""))
        }
    }

    // MARK: - 状态卡片

    /// 页顶的状态卡片：说明当前能否同步、同步到了哪里、失败原因或需要用户处理的事。
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                statusIcon
                    .font(.system(size: 26))
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(text(status.titleKey))
                        .font(.headline)
                    if let detail = statusDetail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("sync-status")

            statusActions
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .syncStatusSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// 状态图标；同步中显示转圈。
    @ViewBuilder
    private var statusIcon: some View {
        if status == .syncing {
            ProgressView()
        } else {
            Image(systemName: status.symbol)
                .foregroundStyle(status.isProblem ? Color(.ledgerRed) : Color.accentColor)
        }
    }

    /// 状态卡片下方的操作：未登录时登录，云端被清空时二选一。
    @ViewBuilder
    private var statusActions: some View {
        switch status {
        case .signedOut:
            Button {
                signInPresentation.present()
            } label: {
                Text(text("auth.sign_in.action"))
                    .font(.body.weight(.medium))
                    .padding(.horizontal, 8)
                    .onAccentForeground()
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .disabled(authStore.isBusy)
            .accessibilityIdentifier("sync-sign-in")
        case .epochMismatch:
            HStack(spacing: 12) {
                Button(text("sync.epochMismatch.upload")) {
                    Task { await resolveEpochMismatch(.uploadLocalData) }
                }
                .buttonStyle(.borderedProminent)
                .onAccentForeground()
                .accessibilityIdentifier("sync-epoch-upload")

                Button(text("sync.epochMismatch.stop")) {
                    Task { await resolveEpochMismatch(.stopSyncing) }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("sync-epoch-stop")
            }
            .buttonBorderShape(.capsule)
            .disabled(isWorking)
        default:
            EmptyView()
        }
    }

    /// 状态卡片的说明文字。
    private var statusDetail: String? {
        switch status {
        case let .failed(failure):
            return text(SyncMessages.localizationKey(for: failure))
        case .synced:
            guard let lastSyncedAt = engine?.lastSyncedAt else { return nil }
            let style = Date.RelativeFormatStyle(presentation: .named, locale: locale)
            var detail = AccountLocalization.formatted(
                "sync.status.lastSynced",
                value: lastSyncedAt.formatted(style),
                locale: locale
            )
            if let oversizedRecordCount = engine?.oversizedRecordCount, oversizedRecordCount > 0 {
                detail += "\n" + String(format: text("sync.status.oversized"), locale: locale, oversizedRecordCount)
            }
            return detail
        default:
            return status.detailKey.map(text)
        }
    }

    /// 页面展示的同步状态。
    private var status: SyncDisplayStatus {
        guard authStore.isAuthenticated else { return .signedOut }
        guard let lifecycle else { return .disabled }
        if lifecycle.isBoundToAnotherAccount(than: authStore.userID) { return .boundToAnotherAccount }
        guard isSyncEnabled else { return .disabled }
        switch engine?.status ?? .idle {
        case .syncing:
            return .syncing
        case let .failed(failure):
            return .failed(failure)
        case .epochMismatch:
            return .epochMismatch
        case .idle:
            return engine?.lastSyncedAt == nil ? .waiting : .synced
        }
    }

    // MARK: - 开关与操作

    /// 已登录且本机数据没有绑定到其他账号时才能管理同步。
    private var canManageSync: Bool {
        guard authStore.isAuthenticated, let lifecycle else { return false }
        return !lifecycle.isBoundToAnotherAccount(than: authStore.userID)
    }

    /// 当前账号的同步是否开启。
    private var isSyncEnabled: Bool {
        guard let lifecycle, let userID = authStore.userID else { return false }
        return lifecycle.state.isEnabled && lifecycle.state.boundUserID == userID
    }

    /// 同步开关：打开时用当前账号开启，关闭时只停止同步、保留绑定。
    private var enabledBinding: Binding<Bool> {
        Binding {
            isSyncEnabled
        } set: { isOn in
            Task { await setSyncEnabled(isOn) }
        }
    }

    /// 打开或关闭同步。
    private func setSyncEnabled(_ isOn: Bool) async {
        guard let lifecycle else { return }
        isWorking = true
        defer { isWorking = false }
        if isOn {
            guard let userID = authStore.userID else {
                errorKey = SyncMessages.localizationKey(for: .notSignedIn)
                return
            }
            do {
                try await lifecycle.enable(userID: userID)
            } catch {
                errorKey = SyncMessages.localizationKey(forLifecycleError: error)
            }
        } else {
            await lifecycle.disable()
        }
    }

    /// 用户点「立即同步」：等这一轮结束，成功或失败各震一下；后台自动同步不走这里，不会震。
    private func synchronizeNow() async {
        guard let engine else { return }
        await engine.synchronize()
        switch engine.status {
        case .idle: AppHaptics.play(.success)
        case .failed, .epochMismatch: AppHaptics.play(.error)
        case .syncing: break
        }
    }

    /// 删除云端数据并解除绑定，本机数据保留。
    private func deleteCloudData() async {
        guard let lifecycle else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await lifecycle.deleteCloudData()
            AppHaptics.play(.destructive)
        } catch {
            errorKey = SyncMessages.localizationKey(forLifecycleError: error)
        }
    }

    /// 处理云端被其他设备清空。
    private func resolveEpochMismatch(_ resolution: SyncEpochMismatchResolution) async {
        guard let lifecycle else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await lifecycle.resolveEpochMismatch(resolution)
        } catch {
            errorKey = SyncMessages.localizationKey(forLifecycleError: error)
        }
    }

    // MARK: - 布局

    /// 分组标题、手绘边框卡片和可选的底部说明，与「我的」页保持一致。
    private func section<Content: View>(
        _ titleKey: String,
        footerKey: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text(titleKey))
                .font(.system(.subheadline, design: .serif, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0, content: content)
                .ledgerFormBorder(seed: titleKey.handDrawnSeed)

            if let footerKey {
                Text(text(footerKey))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 两行之间的手绘细线。
    private var rowDivider: some View {
        HandDrawnRule(seed: 99)
            .stroke(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            .frame(height: 3)
            .padding(.leading, 62)
            .padding(.trailing, 20)
            .accessibilityHidden(true)
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 同步设置页展示的状态，由登录态、绑定、开关和同步引擎状态合成。
private enum SyncDisplayStatus: Equatable {
    /// 未登录。
    case signedOut

    /// 本机数据已绑定到另一个账号。
    case boundToAnotherAccount

    /// 同步已关闭。
    case disabled

    /// 已开启，还没有完成过一次同步。
    case waiting

    /// 正在同步。
    case syncing

    /// 最近一次同步成功。
    case synced

    /// 最近一次同步失败。
    case failed(SyncFailure)

    /// 云端数据已被其他设备清空，等待用户处理。
    case epochMismatch

    /// 标题文案键。
    var titleKey: String {
        switch self {
        case .signedOut: "sync.status.signedOut.title"
        case .boundToAnotherAccount: "sync.status.otherAccount.title"
        case .disabled: "sync.status.disabled.title"
        case .waiting: "sync.status.waiting.title"
        case .syncing: "sync.status.syncing.title"
        case .synced: "sync.status.synced.title"
        case .failed: "sync.status.failed.title"
        case .epochMismatch: "sync.epochMismatch.title"
        }
    }

    /// 固定说明的文案键；失败原因和上次同步时间由页面单独生成。
    var detailKey: String? {
        switch self {
        case .signedOut: "sync.status.signedOut.message"
        case .boundToAnotherAccount: "sync.status.otherAccount.message"
        case .disabled: "sync.status.disabled.message"
        case .epochMismatch: "sync.epochMismatch.message"
        case .waiting, .syncing, .synced, .failed: nil
        }
    }

    /// 状态图标。
    var symbol: String {
        switch self {
        case .signedOut, .disabled: "icloud.slash"
        case .boundToAnotherAccount, .failed, .epochMismatch: "exclamationmark.icloud"
        case .waiting, .syncing: "icloud"
        case .synced: "checkmark.icloud"
        }
    }

    /// 是否需要用户留意，图标用红色。
    var isProblem: Bool {
        switch self {
        case .boundToAnotherAccount, .failed, .epochMismatch: true
        default: false
        }
    }
}

/// 设置行的图标与标题，图标宽度与「我的」页一致。
private struct SyncSettingsLabelStyle: LabelStyle {
    /// 图标与标题的颜色；破坏性操作使用红色。
    var color: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 14) {
            configuration.icon
                .font(.system(size: 21, weight: .regular))
                .frame(width: 28)
                .accessibilityHidden(true)
            configuration.title
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color)
    }
}

/// 按钮行：在设置行样式外加上内边距，整行可点。
private struct SyncSettingsRowLabelStyle: LabelStyle {
    /// 图标与标题的颜色；破坏性操作使用红色。
    var color: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        Label(configuration)
            .labelStyle(SyncSettingsLabelStyle(color: color))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .contentShape(Rectangle())
    }
}

/// 状态卡片底色：iOS 26 用 Liquid Glass，iOS 18 用常规材质。
private struct SyncStatusSurface<SurfaceShape: Shape>: ViewModifier {
    /// 底色形状。
    let shape: SurfaceShape

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

private extension View {
    /// 给同步状态卡片加上玻璃或材质底色。
    func syncStatusSurface<SurfaceShape: Shape>(in shape: SurfaceShape) -> some View {
        modifier(SyncStatusSurface(shape: shape))
    }
}

#Preview {
    NavigationStack { SyncSettingsView() }
        .environment(AuthStore())
        .environment(SignInPresentation())
}
