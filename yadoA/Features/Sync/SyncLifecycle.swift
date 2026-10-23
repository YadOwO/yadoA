import Foundation
import SwiftData

/// 绑定生命周期操作失败的原因。
enum SyncLifecycleError: Error, Equatable {
    /// 本机数据已绑定到另一个账号；需要先清空本机数据才能用当前账号开启同步（需求 R5）。
    case boundToAnotherAccount

    /// 本机还没有绑定账号，无法执行需要云端的操作。
    case notBound

    /// 调用同步接口失败。
    case api(SyncAPIError)

    /// 读写本地数据失败。
    case storage
}

/// 退出登录时如何处理本机数据。
enum SyncSignOutChoice: Equatable {
    /// 保留在本机：解除绑定、清空台账，数据留在本机继续使用。
    case keepOnDevice

    /// 从本机清除：清空本机数据和台账；云端数据不受影响。
    case eraseFromDevice
}

/// 清空数据的范围（已开启同步时让用户二选一）。
enum SyncResetScope: Equatable {
    /// 仅本机：先关闭同步并解除绑定，再清空本机；云端数据保留。
    case deviceOnly

    /// 本机和云端：先删除云端数据，再清空本机；同步保持开启，从新的数据代次开始。
    case deviceAndCloud
}

/// 云端数据被其他设备删除（代次不一致）后，本机如何处理。
enum SyncEpochMismatchResolution: Equatable {
    /// 把本机数据作为新的云端数据重新上传。
    case uploadLocalData

    /// 停止同步：解除绑定，本机数据保留。
    case stopSyncing
}

/// 账号绑定生命周期（U6）：开启、关闭、退出登录、清空数据、处理云端重置和注销账号前删除云端数据。
///
/// 只负责数据与同步状态，界面入口和确认弹窗在 U7。每个会改动数据或同步状态的操作都会先暂停同步引擎、
/// 等正在进行的一轮结束，操作完成后恢复并立即同步一次，避免两边同时改数据。
@MainActor
final class SyncLifecycle {
    /// 本地财务容器。
    private let container: ModelContainer

    /// 同步接口。
    private let api: any SyncServing

    /// 保存同步状态的 UserDefaults。
    private let defaults: UserDefaults

    /// 同步引擎；为空时（如测试）只改数据和状态。
    private let engine: SyncEngine?

    /// 本地读写边界。
    private let store: SyncStore

    /// 创建生命周期服务。
    ///
    /// - Parameters:
    ///   - container: 本地财务容器。
    ///   - api: 同步接口。
    ///   - defaults: 保存同步状态的 UserDefaults。
    ///   - engine: App 内唯一的同步引擎。
    init(
        container: ModelContainer,
        api: any SyncServing,
        defaults: UserDefaults = .standard,
        engine: SyncEngine?
    ) {
        self.container = container
        self.api = api
        self.defaults = defaults
        self.engine = engine
        store = SyncStore(container: container)
    }

    /// 本机当前的同步状态。
    var currentState: SyncState {
        SyncState.load(from: defaults)
    }

    /// 用当前登录账号开启同步。
    ///
    /// - 本机未绑定：读取云端代次，把本机全部记录标记为待上传（没有台账的补登记），绑定后做一轮全量同步，
    ///   云端与本机的数据合并；
    /// - 已绑定到当前账号（之前只是关闭了同步）：重新打开，继续增量同步；
    /// - 已绑定到其他账号：拒绝，需要先清空本机数据。
    ///
    /// - Parameter userID: 当前登录用户的 ID（`AuthStore.userID`）。
    /// - Throws: `SyncLifecycleError`。
    func enable(userID: String) async throws {
        try await withEngineSuspended {
            var state = currentState
            if let boundUserID = state.boundUserID {
                guard boundUserID == userID else { throw SyncLifecycleError.boundToAnotherAccount }
                state.isEnabled = true
                state.save(to: defaults)
                return
            }
            let serverState = try await callAPI { try await api.fetchState() }
            try storage { try store.markAllRecordsForUpload() }
            state.boundUserID = userID
            state.isEnabled = true
            state.epoch = serverState.epoch
            state.since = 0
            state.syncSchemaVersion = 0
            state.save(to: defaults)
        }
    }

    /// 关闭同步：台账照常记录本地修改，下次开启时再上传；绑定保持不变。
    func disable() async {
        await engine?.suspend()
        var state = currentState
        state.isEnabled = false
        state.save(to: defaults)
        engine?.resume()
    }

    /// 退出登录时处理本机数据；调用方随后执行 `AuthStore.signOut()`。
    ///
    /// 已开启同步时先尽量同步一次，把还没上传的修改送到云端；失败不阻止退出。
    ///
    /// - Parameter choice: 保留在本机，或从本机清除。
    /// - Throws: 清除本机数据或台账失败时抛出 `SyncLifecycleError.storage`，此时绑定状态不变。
    func prepareForSignOut(_ choice: SyncSignOutChoice) async throws {
        if currentState.isEnabled {
            await engine?.synchronize()
        }
        try await withEngineSuspended {
            switch choice {
            case .keepOnDevice:
                try storage { try store.clearLedger() }
            case .eraseFromDevice:
                // 清空本机数据会同时清空台账
                try storage { try LocalDataResetService(container: container).eraseAll() }
            }
            var state = currentState
            state.unbind()
            state.save(to: defaults)
        }
    }

    /// 已开启同步时清空数据。
    ///
    /// - Parameters:
    ///   - scope: 仅本机，或本机和云端。
    ///   - eraseLocalData: 清空本机数据的动作；界面传入带撤销快照的清空，默认直接清空。
    /// - Throws: `SyncLifecycleError`；删除云端数据失败时本机数据保持原样。
    func resetData(
        _ scope: SyncResetScope,
        eraseLocalData: (() throws -> Void)? = nil
    ) async throws {
        let container = container
        let erase: () throws -> Void = eraseLocalData ?? { try LocalDataResetService(container: container).eraseAll() }
        try await withEngineSuspended {
            var state = currentState
            switch scope {
            case .deviceOnly:
                // 先解除绑定再清空，清空不会被当成要上传的删除
                state.unbind()
                state.save(to: defaults)
                try storage(erase)
            case .deviceAndCloud:
                guard state.isBound else { throw SyncLifecycleError.notBound }
                let serverState = try await callAPI { try await api.deleteAllData(epoch: state.epoch) }
                // 云端已经删除：无论本机清空是否成功，都要换到新的代次，否则之后的请求都会代次不一致
                state.epoch = serverState.epoch
                state.since = 0
                state.syncSchemaVersion = 0
                state.save(to: defaults)
                try storage(erase)
            }
        }
    }

    /// 处理云端被其他设备重置（代次不一致）。
    ///
    /// - Parameter resolution: 重新上传本机数据，或停止同步。
    /// - Throws: `SyncLifecycleError`。
    func resolveEpochMismatch(_ resolution: SyncEpochMismatchResolution) async throws {
        try await withEngineSuspended {
            var state = currentState
            switch resolution {
            case .uploadLocalData:
                guard state.isBound else { throw SyncLifecycleError.notBound }
                let serverState = try await callAPI { try await api.fetchState() }
                try storage { try store.markAllRecordsForUpload() }
                state.epoch = serverState.epoch
                state.since = 0
                state.syncSchemaVersion = 0
                state.save(to: defaults)
            case .stopSyncing:
                try storage { try store.clearLedger() }
                state.unbind()
                state.save(to: defaults)
            }
        }
    }

    /// 注销账号前删除云端数据并解除绑定；本机数据保留，是否清除由注销流程决定。
    ///
    /// 本机从未绑定时没有本机记录的代次，先读取云端代次再删除，保证该账号的云端数据一定被删掉。
    ///
    /// - Throws: `SyncLifecycleError`；删除失败时不应继续注销。
    func deleteCloudDataBeforeAccountDeletion() async throws {
        try await withEngineSuspended {
            var state = currentState
            let epoch: Int
            if state.isBound {
                epoch = state.epoch
            } else {
                epoch = try await callAPI { try await api.fetchState() }.epoch
            }
            _ = try await callAPI { try await api.deleteAllData(epoch: epoch) }
            try storage { try store.clearLedger() }
            state.unbind()
            state.save(to: defaults)
        }
    }

    // MARK: - 私有方法

    /// 暂停同步引擎执行操作，结束后恢复并立即同步一次。
    private func withEngineSuspended(_ operation: () async throws -> Void) async throws {
        await engine?.suspend()
        defer { engine?.resume() }
        try await operation()
    }

    /// 调用同步接口，把错误统一包装为 `SyncLifecycleError.api`。
    private func callAPI<Value>(_ call: () async throws -> Value) async throws -> Value {
        do {
            return try await call()
        } catch let error as SyncAPIError {
            throw SyncLifecycleError.api(error)
        } catch {
            throw SyncLifecycleError.api(.network)
        }
    }

    /// 读写本地数据，把错误统一包装为 `SyncLifecycleError.storage`。
    private func storage<Value>(_ operation: () throws -> Value) throws -> Value {
        do {
            return try operation()
        } catch {
            throw SyncLifecycleError.storage
        }
    }
}
