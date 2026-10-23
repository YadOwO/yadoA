import SwiftData
import SwiftUI

/// 在本地数据就绪后创建同步引擎和生命周期服务：启动时同步一次，回到前台时再同步，并把两者注入环境供设置页使用。
///
/// 引擎只在开启了同步、且本机绑定的账号就是当前登录账号时才真正请求服务端，未开启时这里没有任何网络活动。
/// 这里还负责两个全局提示：登录成功、登录页关闭后询问一次是否开启同步；云端被其他设备清空时让用户选择如何处理。
private struct SyncEngineHostModifier: ViewModifier {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.locale) private var locale
    @Environment(AuthStore.self) private var authStore
    @Environment(SignInPresentation.self) private var signInPresentation
    @Environment(\.scenePhase) private var scenePhase

    /// App 生命周期内唯一的同步引擎。
    @State private var engine: SyncEngine?

    /// 与引擎共用同步接口和状态的生命周期服务。
    @State private var lifecycle: SyncLifecycle?

    /// 刚登录成功，等登录页关闭后询问是否开启同步。
    @State private var isEnablePromptPending = false

    /// 是否正在询问开启同步。
    @State private var isEnablePromptPresented = false

    /// 是否正在提示云端已被其他设备清空。
    @State private var isEpochMismatchAlertPresented = false

    /// 生命周期操作失败时的文案键。
    @State private var errorKey: String?

    func body(content: Content) -> some View {
        content
            .environment(engine)
            .environment(lifecycle)
            .task {
                guard engine == nil else { return }
                let authStore = authStore
                let api = SyncAPI { try await authStore.accessTokenForSyncService() }
                let engine = SyncEngine(
                    container: modelContext.container,
                    api: api,
                    currentUserID: { authStore.userID }
                )
                self.engine = engine
                lifecycle = SyncLifecycle(container: modelContext.container, api: api, engine: engine)
                engine.start()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    engine?.syncNow()
                }
            }
            .onChange(of: authStore.isAuthenticated) { wasAuthenticated, isAuthenticated in
                if !wasAuthenticated, isAuthenticated {
                    isEnablePromptPending = true
                    presentEnablePromptIfReady()
                    // 之前绑定的就是这个账号（例如登录失效后重新登录）时直接恢复同步
                    engine?.syncNow()
                }
            }
            .onChange(of: signInPresentation.isPresented) { _, _ in
                presentEnablePromptIfReady()
            }
            .onChange(of: engine?.status) { _, status in
                if case .epochMismatch = status {
                    isEpochMismatchAlertPresented = true
                }
            }
            .alert(text("sync.enablePrompt.title"), isPresented: $isEnablePromptPresented) {
                Button(text("sync.enablePrompt.enable")) {
                    Task { await enableSync() }
                }
                .accessibilityIdentifier("sync-enable-prompt-enable")

                Button(text("sync.enablePrompt.later"), role: .cancel) {}
            } message: {
                Text(text("sync.enablePrompt.message"))
            }
            .alert(text("sync.epochMismatch.title"), isPresented: $isEpochMismatchAlertPresented) {
                Button(text("sync.epochMismatch.upload")) {
                    Task { await resolveEpochMismatch(.uploadLocalData) }
                }
                Button(text("sync.epochMismatch.stop")) {
                    Task { await resolveEpochMismatch(.stopSyncing) }
                }
                Button(text("sync.epochMismatch.later"), role: .cancel) {}
            } message: {
                Text(text("sync.epochMismatch.message"))
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

    /// 登录页关闭后，本机数据还没绑定任何账号时询问一次是否开启同步。
    ///
    /// 已绑定当前账号时同步会自动恢复；已绑定其他账号时开启会被拒绝，到同步设置页再说明原因。
    private func presentEnablePromptIfReady() {
        guard isEnablePromptPending, !signInPresentation.isPresented else { return }
        isEnablePromptPending = false
        guard authStore.isAuthenticated, let lifecycle else { return }
        lifecycle.refreshState()
        if !lifecycle.state.isBound {
            isEnablePromptPresented = true
        }
    }

    /// 用当前账号开启同步。
    private func enableSync() async {
        guard let lifecycle, let userID = authStore.userID else {
            errorKey = SyncMessages.localizationKey(for: .notSignedIn)
            return
        }
        do {
            try await lifecycle.enable(userID: userID)
        } catch {
            errorKey = SyncMessages.localizationKey(forLifecycleError: error)
        }
    }

    /// 处理云端被其他设备清空。
    private func resolveEpochMismatch(_ resolution: SyncEpochMismatchResolution) async {
        guard let lifecycle else { return }
        do {
            try await lifecycle.resolveEpochMismatch(resolution)
        } catch {
            errorKey = SyncMessages.localizationKey(forLifecycleError: error)
        }
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

extension View {
    /// 挂载云端同步引擎；需要放在已注入 `modelContainer`、`AuthStore` 和 `SignInPresentation` 的视图上。
    func syncEngineHost() -> some View {
        modifier(SyncEngineHostModifier())
    }
}
