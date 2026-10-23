import Foundation
import SwiftData
import Testing
@testable import yadoA

/// 覆盖绑定生命周期每条路径执行后的同步状态、台账和云端数据。
@Suite("同步绑定生命周期", .serialized)
@MainActor
struct SyncLifecycleTests {
    @Test("未绑定时开启同步：读取云端代次、补登记没有台账的记录，全量同步后全部上传")
    func enableBindsAndUploadsLocalData() async throws {
        try await SyncTestEnvironment.run { environment in
            _ = try await environment.server.deleteAllData(epoch: 0)
            let device = try environment.makeDevice(bound: false)
            let firstAccountID = UUID()
            try saveAccount(id: firstAccountID, in: device.container)
            // 模拟台账被清空后一直没改过的记录
            try SyncStore(container: device.container).clearLedger()
            let secondAccountID = UUID()
            try saveAccount(id: secondAccountID, in: device.container)

            try await lifecycle(for: device, in: environment).enable(userID: environment.userID)
            await device.engine.synchronize()

            #expect(device.state.boundUserID == environment.userID)
            #expect(device.state.isEnabled)
            #expect(device.state.epoch == 1)
            let firstRemote = await environment.server.record(.account, firstAccountID)
            let secondRemote = await environment.server.record(.account, secondAccountID)
            #expect(firstRemote != nil)
            #expect(secondRemote != nil)
            #expect(try pendingEntries(in: device.container).isEmpty)
        }
    }

    @Test("本机已绑定其他账号时拒绝开启，状态不变")
    func enableRejectsAnotherAccount() async throws {
        try await SyncTestEnvironment.run { environment in
            let device = try environment.makeDevice()
            let before = device.state

            await #expect(throws: SyncLifecycleError.boundToAnotherAccount) {
                try await lifecycle(for: device, in: environment).enable(userID: "user-2")
            }
            #expect(device.state == before)
        }
    }

    @Test("重新开启时补登记的旧副本不覆盖云端的新版本")
    func backfilledCopyLosesToCloud() async throws {
        try await SyncTestEnvironment.run { environment in
            let device = try environment.makeDevice()
            let accountID = UUID()
            try saveAccount(id: accountID, in: device.container)
            await device.engine.synchronize()
            let lifecycle = lifecycle(for: device, in: environment)

            // 退出登录时保留本机数据；之后另一台设备改了这个账户
            try await lifecycle.prepareForSignOut(.keepOnDevice)
            await environment.server.store(
                entityType: .account,
                recordID: accountID,
                payload: try accountPayload(id: accountID, name: "新名字")
            )
            try await lifecycle.enable(userID: environment.userID)
            await device.engine.synchronize()

            #expect(try ModelContext(device.container).account(id: accountID)?.name == "新名字")
            let remote = await environment.server.record(.account, accountID)
            #expect(field("name", of: remote) == .string("新名字"))
        }
    }

    @Test("关闭同步后不再请求，绑定保持不变")
    func disableStopsSyncing() async throws {
        try await SyncTestEnvironment.run { environment in
            let device = try environment.makeDevice()
            await lifecycle(for: device, in: environment).disable()
            let requestCount = await environment.server.pullSinces.count
            try saveAccount(id: UUID(), in: device.container)
            await device.engine.synchronize()

            #expect(!device.state.isEnabled)
            #expect(device.state.boundUserID == environment.userID)
            let laterCount = await environment.server.pullSinces.count
            #expect(laterCount == requestCount)
            #expect(try !pendingEntries(in: device.container).isEmpty)
        }
    }

    @Test("退出登录并保留本机数据：解除绑定、清空台账，数据和设备标识保留")
    func signOutKeepsLocalData() async throws {
        try await SyncTestEnvironment.run { environment in
            let device = try environment.makeDevice()
            let accountID = UUID()
            try saveAccount(id: accountID, in: device.container)
            await device.engine.synchronize()
            let deviceID = device.state.deviceID

            try await lifecycle(for: device, in: environment).prepareForSignOut(.keepOnDevice)

            #expect(!device.state.isBound)
            #expect(!device.state.isEnabled)
            #expect(device.state.since == 0)
            #expect(device.state.deviceID == deviceID)
            #expect(try allEntries(in: device.container).isEmpty)
            #expect(try ModelContext(device.container).account(id: accountID) != nil)
            let remote = await environment.server.record(.account, accountID)
            #expect(remote != nil)
        }
    }

    @Test("退出登录前把还没上传的修改送到云端")
    func signOutPushesPendingChangesFirst() async throws {
        try await SyncTestEnvironment.run { environment in
            let device = try environment.makeDevice()
            let accountID = UUID()
            try saveAccount(id: accountID, in: device.container)

            try await lifecycle(for: device, in: environment).prepareForSignOut(.keepOnDevice)

            let remote = await environment.server.record(.account, accountID)
            #expect(remote != nil)
        }
    }

    @Test("退出登录并从本机清除：本机数据清空、解除绑定，云端数据保留")
    func signOutErasesLocalData() async throws {
        try await SyncTestEnvironment.run { environment in
            let device = try environment.makeDevice()
            let accountID = UUID()
            try saveAccount(id: accountID, in: device.container)
            await device.engine.synchronize()

            try await lifecycle(for: device, in: environment).prepareForSignOut(.eraseFromDevice)

            #expect(!device.state.isBound)
            #expect(try ModelContext(device.container).account(id: accountID) == nil)
            #expect(try ledgerEntry(.account, accountID, in: device.container) == nil)
            let remote = await environment.server.record(.account, accountID)
            #expect(remote != nil)
        }
    }

    @Test("仅清空本机：先解除绑定再清空，云端数据保留，清空不会作为删除上传")
    func resetDeviceOnlyKeepsCloud() async throws {
        try await SyncTestEnvironment.run { environment in
            let device = try environment.makeDevice()
            let accountID = UUID()
            try saveAccount(id: accountID, in: device.container)
            await device.engine.synchronize()

            try await lifecycle(for: device, in: environment).resetData(.deviceOnly)
            await device.engine.synchronize()

            #expect(!device.state.isBound)
            #expect(try ModelContext(device.container).account(id: accountID) == nil)
            let remote = await environment.server.record(.account, accountID)
            #expect(remote?.isDeleted == false)
        }
    }

    @Test("清空本机和云端：删除云端数据并换到新代次，同步保持开启")
    func resetDeviceAndCloudStartsNewEpoch() async throws {
        try await SyncTestEnvironment.run { environment in
            let device = try environment.makeDevice()
            let accountID = UUID()
            try saveAccount(id: accountID, in: device.container)
            await device.engine.synchronize()

            try await lifecycle(for: device, in: environment).resetData(.deviceAndCloud)
            await device.engine.synchronize()

            #expect(device.state.isEnabled)
            #expect(device.state.boundUserID == environment.userID)
            #expect(device.state.epoch == 1)
            #expect(device.engine.status == .idle)
            #expect(try ModelContext(device.container).account(id: accountID) == nil)
            let remote = await environment.server.record(.account, accountID)
            #expect(remote == nil)
        }
    }

    @Test("清空时使用调用方传入的清空动作（界面会先留撤销快照）")
    func resetUsesInjectedEraseAction() async throws {
        try await SyncTestEnvironment.run { environment in
            let device = try environment.makeDevice()
            var didErase = false

            try await lifecycle(for: device, in: environment).resetData(.deviceOnly) {
                didErase = true
            }

            #expect(didErase)
        }
    }

    @Test("云端被其他设备重置后重新上传本机数据")
    func resolveEpochMismatchByUploading() async throws {
        try await SyncTestEnvironment.run { environment in
            let deviceA = try environment.makeDevice()
            let deviceB = try environment.makeDevice()
            let accountID = UUID()
            try saveAccount(id: accountID, in: deviceB.container)
            await deviceB.engine.synchronize()
            await deviceA.engine.synchronize()

            try await lifecycle(for: deviceA, in: environment).resetData(.deviceAndCloud)
            await deviceB.engine.synchronize()
            #expect(deviceB.engine.status == .epochMismatch(currentEpoch: 1))

            try await lifecycle(for: deviceB, in: environment).resolveEpochMismatch(.uploadLocalData)
            await deviceB.engine.synchronize()

            #expect(deviceB.engine.status == .idle)
            #expect(deviceB.state.epoch == 1)
            let remote = await environment.server.record(.account, accountID)
            #expect(remote?.isDeleted == false)
        }
    }

    @Test("云端被其他设备重置后停止同步：解除绑定，本机数据保留")
    func resolveEpochMismatchByStopping() async throws {
        try await SyncTestEnvironment.run { environment in
            let device = try environment.makeDevice()
            let accountID = UUID()
            try saveAccount(id: accountID, in: device.container)
            await device.engine.synchronize()
            _ = try await environment.server.deleteAllData(epoch: 0)
            await device.engine.synchronize()

            try await lifecycle(for: device, in: environment).resolveEpochMismatch(.stopSyncing)
            await device.engine.synchronize()

            #expect(!device.state.isBound)
            #expect(device.engine.status == .idle)
            #expect(try allEntries(in: device.container).isEmpty)
            #expect(try ModelContext(device.container).account(id: accountID) != nil)
        }
    }

    @Test("删除云端数据并解除绑定，本机数据保留")
    func deleteCloudDataUnbinds() async throws {
        try await SyncTestEnvironment.run { environment in
            let device = try environment.makeDevice()
            let accountID = UUID()
            try saveAccount(id: accountID, in: device.container)
            await device.engine.synchronize()

            try await lifecycle(for: device, in: environment).deleteCloudData()

            #expect(!device.state.isBound)
            let remote = await environment.server.record(.account, accountID)
            #expect(remote == nil)
            let epoch = await environment.server.epoch
            #expect(epoch == 1)
            #expect(try ModelContext(device.container).account(id: accountID) != nil)
        }
    }

    @Test("操作结束后刷新给界面观察的状态快照，并能判断本机是否绑定到其他账号")
    func stateSnapshotRefreshesAfterOperations() async throws {
        try await SyncTestEnvironment.run { environment in
            let device = try environment.makeDevice()
            let lifecycle = lifecycle(for: device, in: environment)
            #expect(lifecycle.state.isEnabled)
            #expect(lifecycle.isBoundToAnotherAccount(than: "user-2"))
            #expect(!lifecycle.isBoundToAnotherAccount(than: environment.userID))
            #expect(!lifecycle.isBoundToAnotherAccount(than: nil))

            await lifecycle.disable()
            #expect(!lifecycle.state.isEnabled)

            try await lifecycle.prepareForSignOut(.keepOnDevice)
            #expect(!lifecycle.state.isBound)
            #expect(!lifecycle.isBoundToAnotherAccount(than: "user-2"))
        }
    }

    @Test("错误对应的界面文案：登录类错误提示重新登录，非生命周期错误按本机读写失败处理")
    func errorMessageKeys() {
        #expect(SyncMessages.localizationKey(for: .sessionExpired) == "sync.error.signIn")
        #expect(SyncMessages.localizationKey(for: .unauthorized) == "sync.error.signIn")
        #expect(SyncMessages.localizationKey(for: .timeout) == "sync.error.network")
        #expect(SyncMessages.localizationKey(for: SyncFailure.storage) == "sync.error.storage")
        #expect(
            SyncMessages.localizationKey(forLifecycleError: SyncLifecycleError.api(.serviceUnavailable))
                == "sync.error.serviceUnavailable"
        )
        #expect(
            SyncMessages.localizationKey(forLifecycleError: SyncLifecycleError.boundToAnotherAccount)
                == "sync.error.boundToAnotherAccount"
        )
        #expect(SyncMessages.localizationKey(forLifecycleError: CancellationError()) == "sync.error.storage")
    }

    // MARK: - 辅助

    /// 为设备创建生命周期服务，和设备共用同步引擎与同步状态。
    private func lifecycle(for device: SyncTestDevice, in environment: SyncTestEnvironment) -> SyncLifecycle {
        SyncLifecycle(container: device.container, api: environment.server, defaults: device.defaults, engine: device.engine)
    }

    /// 通过账户仓库保存一个期初余额为 100 的现金账户。
    private func saveAccount(id: UUID, in container: ModelContainer) throws {
        try LocalAccountRepository(container: container).save(
            AccountDraft(id: id, accountType: .cash, template: nil, name: "现金", amountText: "100"),
            locale: Locale(identifier: "en_US")
        )
    }

    /// 构造服务端上的账户内容。
    private func accountPayload(id: UUID, name: String) throws -> SyncJSONValue {
        let account = BackupAccount(
            id: id,
            type: AccountType.cash.rawValue,
            templateID: nil,
            name: name,
            note: nil,
            lastFourDigits: nil,
            balance: "100",
            openingBalance: "100",
            currencyCode: "CNY",
            createdAt: .now,
            updatedAt: .now,
            deactivatedAt: nil
        )
        return try SyncJSONValue(payload: BackupFileEncoding.makeEncoder().encode(account))
    }

    /// 读取服务端记录内容中的一个字段。
    private func field(_ name: String, of record: SyncRemoteRecord?) -> SyncJSONValue? {
        guard case let .object(fields) = record?.payload else { return nil }
        return fields[name]
    }

    /// 全部台账。
    private func allEntries(in container: ModelContainer) throws -> [SyncLedgerEntry] {
        try ModelContext(container).fetch(FetchDescriptor<SyncLedgerEntry>())
    }

    /// 全部待上传的台账。
    private func pendingEntries(in container: ModelContainer) throws -> [SyncLedgerEntry] {
        try allEntries(in: container).filter(\.hasPendingChanges)
    }

    /// 读取一条台账。
    private func ledgerEntry(
        _ entityType: SyncEntityType,
        _ recordID: UUID,
        in container: ModelContainer
    ) throws -> SyncLedgerEntry? {
        try allEntries(in: container).first {
            $0.key == SyncLedgerEntry.key(entityType: entityType, recordID: recordID)
        }
    }
}
