import SwiftData
import SwiftUI

/// 在本地数据就绪后创建同步引擎：启动时同步一次，回到前台时再同步，并把引擎注入环境供设置页使用。
///
/// 引擎只在开启了同步、且本机绑定的账号就是当前登录账号时才真正请求服务端，未开启时这里没有任何网络活动。
private struct SyncEngineHostModifier: ViewModifier {
    @Environment(\.modelContext) private var modelContext
    @Environment(AuthStore.self) private var authStore
    @Environment(\.scenePhase) private var scenePhase

    /// App 生命周期内唯一的同步引擎。
    @State private var engine: SyncEngine?

    func body(content: Content) -> some View {
        content
            .environment(engine)
            .task {
                guard engine == nil else { return }
                let authStore = authStore
                let engine = SyncEngine(
                    container: modelContext.container,
                    api: SyncAPI { try await authStore.accessTokenForSyncService() },
                    currentUserID: { authStore.userID }
                )
                self.engine = engine
                engine.start()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    engine?.syncNow()
                }
            }
    }
}

extension View {
    /// 挂载云端同步引擎；需要放在已注入 `modelContainer` 和 `AuthStore` 的视图上。
    func syncEngineHost() -> some View {
        modifier(SyncEngineHostModifier())
    }
}
