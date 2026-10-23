import Foundation
import SwiftData
import Testing
@testable import yadoA

/// 模拟 yadoA_be 同步接口的内存服务端：用户内序号、严格更新者胜出、分页、清理边界与数据代次与真实服务端一致。
actor MockSyncServer: SyncServing {
    /// 服务端保存的记录，按台账唯一键索引。
    private(set) var records: [String: SyncRemoteRecord] = [:]

    /// 已分配的最大序号。
    private(set) var lastVersion: Int64 = 0

    /// 当前数据代次。
    private(set) var epoch = 0

    /// 墓碑清理边界。
    private(set) var purgedThrough: Int64 = 0

    /// 每次拉取请求的 since，按请求顺序。
    private(set) var pullSinces: [Int64] = []

    /// 每页条数。
    private var pageLimit = 500

    /// 推送写入前执行一次的动作，用来模拟推送进行中其他设备或本机的修改。
    private var beforePushResponse: (@Sendable () async -> Void)?

    func setPageLimit(_ limit: Int) {
        pageLimit = limit
    }

    func setBeforePushResponse(_ action: @escaping @Sendable () async -> Void) {
        beforePushResponse = action
    }

    func fetchState() async throws -> SyncServerState {
        SyncServerState(epoch: epoch)
    }

    func push(_ request: SyncPushRequest) async throws -> SyncPushResponse {
        guard request.epoch == epoch else { throw SyncAPIError.epochMismatch(currentEpoch: epoch) }
        if request.since < purgedThrough || request.since > lastVersion {
            return SyncPushResponse(results: [], resetRequired: true)
        }
        if let action = beforePushResponse {
            beforePushResponse = nil
            await action()
        }
        var results: [SyncPushResult] = []
        for change in request.changes {
            let key = SyncLedgerEntry.key(entityType: change.entityType, recordID: change.recordID)
            let modifiedAt = min(max(change.modifiedAt, SyncCoding.minimumModifiedAt), .now)
            if let existing = records[key], modifiedAt <= existing.modifiedAt {
                results.append(
                    SyncPushResult(
                        entityTypeRawValue: change.entityType.rawValue,
                        recordID: change.recordID,
                        status: .stale,
                        serverVersion: existing.serverVersion,
                        modifiedAt: existing.modifiedAt,
                        current: existing
                    )
                )
                continue
            }
            let stored = store(
                entityType: change.entityType,
                recordID: change.recordID,
                modifiedAt: modifiedAt,
                payload: change.payload
            )
            results.append(
                SyncPushResult(
                    entityTypeRawValue: change.entityType.rawValue,
                    recordID: change.recordID,
                    status: .applied,
                    serverVersion: stored.serverVersion,
                    modifiedAt: modifiedAt,
                    current: nil
                )
            )
        }
        return SyncPushResponse(results: results, resetRequired: false)
    }

    func pull(since: Int64, deviceID: UUID, epoch: Int, limit: Int?) async throws -> SyncPullPage {
        guard epoch == self.epoch else { throw SyncAPIError.epochMismatch(currentEpoch: self.epoch) }
        pullSinces.append(since)
        if since > 0, since < purgedThrough || since > lastVersion {
            return SyncPullPage(changes: [], nextSince: since, hasMore: false, resetRequired: true)
        }
        let newer = records.values
            .filter { $0.serverVersion > since }
            .sorted { $0.serverVersion < $1.serverVersion }
        let page = Array(newer.prefix(limit ?? pageLimit))
        let hasMore = newer.count > page.count
        return SyncPullPage(
            changes: page,
            nextSince: hasMore ? (page.last?.serverVersion ?? since) : lastVersion,
            hasMore: hasMore,
            resetRequired: false
        )
    }

    func deleteAllData(epoch: Int) async throws -> SyncServerState {
        guard epoch == self.epoch else { throw SyncAPIError.epochMismatch(currentEpoch: self.epoch) }
        records.removeAll()
        self.epoch += 1
        lastVersion += 1
        purgedThrough = lastVersion
        return SyncServerState(epoch: self.epoch)
    }

    // MARK: - 测试辅助

    /// 模拟另一台设备写入一条记录（修改时间为当前时间）。
    @discardableResult
    func store(
        entityType: SyncEntityType,
        recordID: UUID,
        modifiedAt: Date = .now,
        payload: SyncJSONValue?
    ) -> SyncRemoteRecord {
        lastVersion += 1
        let record = SyncRemoteRecord(
            entityTypeRawValue: entityType.rawValue,
            recordID: recordID,
            modifiedAt: modifiedAt,
            isDeleted: payload == nil,
            payload: payload,
            serverVersion: lastVersion
        )
        records[SyncLedgerEntry.key(entityType: entityType, recordID: recordID)] = record
        return record
    }

    /// 模拟墓碑被清理：移除记录，并把清理边界推进到当前序号之后，落后的设备会被要求全量同步。
    func purge(_ keys: [String]) {
        keys.forEach { records.removeValue(forKey: $0) }
        lastVersion += 1
        purgedThrough = lastVersion
    }

    /// 读取一条记录。
    func record(_ entityType: SyncEntityType, _ recordID: UUID) -> SyncRemoteRecord? {
        records[SyncLedgerEntry.key(entityType: entityType, recordID: recordID)]
    }
}

/// 一台参与同步的测试设备：独立的内存账本和同步状态。
@MainActor
struct SyncTestDevice {
    let container: ModelContainer
    let defaults: UserDefaults
    let engine: SyncEngine

    var state: SyncState { SyncState.load(from: defaults) }

    func updateState(_ change: (inout SyncState) -> Void) {
        var state = state
        change(&state)
        state.save(to: defaults)
    }
}

/// 一个测试用到的同步环境：多台设备共用同一个模拟服务端和登录账号。
@MainActor
final class SyncTestEnvironment {
    let server = MockSyncServer()
    let userID = "user-1"
    private(set) var suiteNames: [String] = []

    /// 在独立的同步环境中执行测试，结束后还原全局台账设置并清理同步状态。
    static func run(_ body: (SyncTestEnvironment) async throws -> Void) async throws {
        let originalDefaults = SyncChangeTracker.defaults
        let environment = SyncTestEnvironment()
        defer {
            SyncChangeTracker.defaults = originalDefaults
            for suiteName in environment.suiteNames {
                UserDefaults().removePersistentDomain(forName: suiteName)
            }
        }
        try await body(environment)
    }

    /// 创建一台设备；默认已开启同步、绑定到同一账号，本地删除按已绑定规则保留墓碑。
    ///
    /// - Parameter bound: 为 false 时设备未绑定、未开启同步，模拟还没开启过同步的本机。
    func makeDevice(bound: Bool = true) throws -> SyncTestDevice {
        let suiteName = "SyncEngineTests.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        var state = SyncState.load(from: defaults)
        state.boundUserID = bound ? userID : nil
        state.isEnabled = bound
        state.save(to: defaults)
        // 台账只读取「是否已绑定」；测试里最后创建的设备决定这条规则，同一测试内的设备绑定状态一致
        SyncChangeTracker.defaults = defaults

        let container = try AccountDataContainer.inMemory().modelContainer
        let userID = userID
        let engine = SyncEngine(container: container, api: server, defaults: defaults, currentUserID: { userID })
        return SyncTestDevice(container: container, defaults: defaults, engine: engine)
    }
}

@Suite("同步引擎", .serialized)
@MainActor
struct SyncEngineTests {
    @Test("推送和拉取往返：另一台设备拿到账户和流水，并按期初余额重算余额")
    func pushAndPullRoundTrip() async throws {
        try await withEnvironment { environment in
            let deviceA = try environment.makeDevice()
            let deviceB = try environment.makeDevice()
            let accountID = UUID()
            try saveAccount(id: accountID, in: deviceA.container)
            let draft = DiningExpenseDraft(accountID: accountID, amountText: "30", transactionDay: 20261020)
            try LocalExpenseRepository(container: deviceA.container).save(draft)

            await deviceA.engine.synchronize()
            #expect(deviceA.engine.status == .idle)
            #expect(try pendingEntries(in: deviceA.container).isEmpty)
            #expect(deviceA.state.syncSchemaVersion == SyncEngine.currentSchemaVersion)
            // 进度只由拉取推进，推送不前移：下一轮拉回自己的推送后才追上服务端
            #expect(deviceA.state.since == 0)
            await deviceA.engine.synchronize()
            let lastVersion = await environment.server.lastVersion
            #expect(deviceA.state.since == lastVersion)
            #expect(try pendingEntries(in: deviceA.container).isEmpty)

            await deviceB.engine.synchronize()
            let context = ModelContext(deviceB.container)
            let account = try #require(try context.account(id: accountID))
            #expect(account.openingBalance == 100)
            #expect(account.balance == 70)
            #expect(try context.transaction(id: draft.id)?.amount == 30)
            #expect(try ledgerEntry(.transaction, draft.id, in: deviceB.container)?.hasPendingChanges == false)
        }
    }

    @Test("推送时服务端已有更新的版本（stale）：用服务端版本覆盖本地")
    func staleResultOverwritesLocal() async throws {
        try await withEnvironment { environment in
            let device = try environment.makeDevice()
            let server = environment.server
            let accountID = UUID()
            try saveAccount(id: accountID, in: device.container)
            // 本机拉取完、推送前，另一台设备写入了更新的版本
            let newer = try accountPayload(id: accountID, name: "服务端")
            await server.setBeforePushResponse {
                _ = await server.store(entityType: .account, recordID: accountID, payload: newer)
            }

            await device.engine.synchronize()

            #expect(try ModelContext(device.container).account(id: accountID)?.name == "服务端")
            #expect(try ledgerEntry(.account, accountID, in: device.container)?.hasPendingChanges == false)
        }
    }

    @Test("推送进行中本地又被修改：只确认已推送的版本，新修改保持待上传")
    func localChangeDuringPushStaysPending() async throws {
        try await withEnvironment { environment in
            let device = try environment.makeDevice()
            let accountID = UUID()
            try saveAccount(id: accountID, in: device.container)
            let repository = LocalExpenseRepository(container: device.container)
            let draft = DiningExpenseDraft(accountID: accountID, amountText: "30", transactionDay: 20261020)
            try repository.save(draft)
            let store = SyncStore(container: device.container)

            let batch = try store.pendingBatch()
            try repository.update(
                DiningExpenseEditDraft(id: draft.id, accountID: accountID, title: "午饭", amountText: "45", transactionDay: 20261020)
            )
            let results = batch.items.enumerated().map { index, item in
                SyncPushResult(
                    entityTypeRawValue: item.change.entityType.rawValue,
                    recordID: item.change.recordID,
                    status: .applied,
                    serverVersion: Int64(index + 1),
                    modifiedAt: item.change.modifiedAt,
                    current: nil
                )
            }
            try store.applyPushResults(batch, response: SyncPushResponse(results: results, resetRequired: false))

            let pushedRevision = try #require(batch.items.first { $0.change.recordID == draft.id }?.revision)
            let transactionEntry = try #require(try ledgerEntry(.transaction, draft.id, in: device.container))
            #expect(transactionEntry.hasPendingChanges)
            #expect(transactionEntry.pushedRevision == pushedRevision)
            #expect(try ModelContext(device.container).transaction(id: draft.id)?.amount == 45)
            #expect(try ledgerEntry(.account, accountID, in: device.container)?.hasPendingChanges == false)
        }
    }

    @Test("本地待上传且更新的版本不会被拉取覆盖，之后推送到服务端")
    func newerLocalChangeSurvivesPull() async throws {
        try await withEnvironment { environment in
            let deviceA = try environment.makeDevice()
            let deviceB = try environment.makeDevice()
            let accountID = UUID()
            try saveAccount(id: accountID, in: deviceA.container)
            let draft = DiningExpenseDraft(accountID: accountID, amountText: "30", transactionDay: 20261020)
            try LocalExpenseRepository(container: deviceA.container).save(draft)
            await deviceA.engine.synchronize()
            await deviceB.engine.synchronize()

            // A 先改并上传，B 后改但还没同步
            try LocalExpenseRepository(container: deviceA.container).update(
                DiningExpenseEditDraft(id: draft.id, accountID: accountID, title: "A", amountText: "40", transactionDay: 20261020)
            )
            await deviceA.engine.synchronize()
            try LocalExpenseRepository(container: deviceB.container).update(
                DiningExpenseEditDraft(id: draft.id, accountID: accountID, title: "B", amountText: "50", transactionDay: 20261020)
            )
            await deviceB.engine.synchronize()

            #expect(try ModelContext(deviceB.container).transaction(id: draft.id)?.amount == 50)
            let remoteRecord = await environment.server.record(.transaction, draft.id)
            let remote = try #require(remoteRecord)
            #expect(field("amount", of: remote) == .string("50"))

            await deviceA.engine.synchronize()
            let contextA = ModelContext(deviceA.container)
            #expect(try contextA.transaction(id: draft.id)?.amount == 50)
            #expect(try contextA.account(id: accountID)?.balance == 50)
        }
    }

    @Test("远端删除了账户但本地仍有流水引用：保留账户并推送回服务端")
    func remoteAccountDeletionKeepsReferencedAccount() async throws {
        try await withEnvironment { environment in
            let device = try environment.makeDevice()
            let server = environment.server
            let accountID = UUID()
            try saveAccount(id: accountID, in: device.container)
            await device.engine.synchronize()

            // 本机离线记了一笔，同时另一台设备删除了这个账户
            let draft = DiningExpenseDraft(accountID: accountID, amountText: "30", transactionDay: 20261020)
            try LocalExpenseRepository(container: device.container).save(draft)
            await server.store(entityType: .account, recordID: accountID, payload: nil)

            await device.engine.synchronize()

            #expect(try ModelContext(device.container).account(id: accountID) != nil)
            let remoteAccountRecord = await server.record(.account, accountID)
            let remoteAccount = try #require(remoteAccountRecord)
            #expect(!remoteAccount.isDeleted)
            let remoteTransaction = await server.record(.transaction, draft.id)
            #expect(remoteTransaction != nil)
        }
    }

    @Test("远端删除分类并指定迁移目标：本地仍引用它的流水迁到目标分类，并作为修改推送")
    func remoteCategoryDeletionMigratesTransactions() async throws {
        try await withEnvironment { environment in
            let device = try environment.makeDevice()
            let server = environment.server
            let accountID = UUID()
            try saveAccount(id: accountID, in: device.container)
            await device.engine.synchronize()

            let draft = DiningExpenseDraft(
                accountID: accountID,
                expenseCategoryKey: ExpenseCategory.shopping.rawValue,
                amountText: "30",
                transactionDay: 20261020
            )
            try LocalExpenseRepository(container: device.container).save(draft)
            let preset = try #require(
                BookkeepingCategoryKey.preset(direction: .expense, key: ExpenseCategory.shopping.rawValue)
            )
            let deletedCategory = BackupCategory(
                id: preset.id,
                direction: BookkeepingEntryType.expense.rawValue,
                key: preset.key,
                customName: nil,
                symbolName: preset.symbolName,
                sortIndex: preset.sortIndex,
                updatedAt: .now,
                deletedAt: .now,
                replacementKey: ExpenseCategory.dining.rawValue
            )
            await server.store(entityType: .category, recordID: preset.id, payload: try payload(deletedCategory))

            await device.engine.synchronize()

            let transaction = try #require(try ModelContext(device.container).transaction(id: draft.id))
            #expect(transaction.categoryRawValue == ExpenseCategory.dining.rawValue)
            let remoteRecord = await server.record(.transaction, draft.id)
            let remote = try #require(remoteRecord)
            #expect(field("category", of: remote) == .string(ExpenseCategory.dining.rawValue))
        }
    }

    @Test("全量同步后删除服务端已经没有的本地记录，从未上传过的记录保留并推送")
    func fullSyncRemovesRecordsMissingOnServer() async throws {
        try await withEnvironment { environment in
            let device = try environment.makeDevice()
            let server = environment.server
            let syncedAccountID = UUID()
            try saveAccount(id: syncedAccountID, in: device.container)
            let draft = DiningExpenseDraft(accountID: syncedAccountID, amountText: "30", transactionDay: 20261020)
            try LocalExpenseRepository(container: device.container).save(draft)
            await device.engine.synchronize()

            let localOnlyAccountID = UUID()
            try saveAccount(id: localOnlyAccountID, in: device.container)
            // 云端已删除这两条且墓碑已清理，本机进度落后于清理边界
            await server.purge([
                SyncLedgerEntry.key(entityType: .account, recordID: syncedAccountID),
                SyncLedgerEntry.key(entityType: .transaction, recordID: draft.id),
            ])

            await device.engine.synchronize()

            let context = ModelContext(device.container)
            #expect(try context.account(id: syncedAccountID) == nil)
            #expect(try context.transaction(id: draft.id) == nil)
            #expect(try ledgerEntry(.account, syncedAccountID, in: device.container) == nil)
            #expect(try context.account(id: localOnlyAccountID) != nil)
            let pushedLocalOnly = await server.record(.account, localOnlyAccountID)
            #expect(pushedLocalOnly != nil)
            let pullSinces = await server.pullSinces
            #expect(pullSinces.contains(0))
        }
    }

    @Test("全量拉取翻完所有页后才应用")
    func fullPullReadsEveryPage() async throws {
        try await withEnvironment { environment in
            let deviceA = try environment.makeDevice()
            let deviceB = try environment.makeDevice()
            let accountIDs = (0 ..< 5).map { _ in UUID() }
            for accountID in accountIDs {
                try saveAccount(id: accountID, in: deviceA.container)
            }
            await deviceA.engine.synchronize()
            await environment.server.setPageLimit(2)

            await deviceB.engine.synchronize()

            let context = ModelContext(deviceB.container)
            for accountID in accountIDs {
                #expect(try context.account(id: accountID) != nil)
            }
            let lastVersion = await environment.server.lastVersion
            #expect(deviceB.state.since == lastVersion)
        }
    }

    @Test("同步格式版本升级时重新全量同步")
    func schemaUpgradeTriggersFullSync() async throws {
        try await withEnvironment { environment in
            let device = try environment.makeDevice()
            try saveAccount(id: UUID(), in: device.container)
            // 第二轮拉回第一轮的推送，进度才大于 0
            await device.engine.synchronize()
            await device.engine.synchronize()
            #expect(device.state.since > 0)

            device.updateState { $0.syncSchemaVersion = 0 }
            let requestCount = await environment.server.pullSinces.count
            await device.engine.synchronize()

            let sinces = await environment.server.pullSinces
            #expect(sinces.count > requestCount)
            #expect(sinces.dropFirst(requestCount).first == 0)
            #expect(device.state.syncSchemaVersion == SyncEngine.currentSchemaVersion)
        }
    }

    @Test("云端数据被删除后代次不一致：暂停同步，代次更新前不再请求")
    func epochMismatchPausesSync() async throws {
        try await withEnvironment { environment in
            let device = try environment.makeDevice()
            try saveAccount(id: UUID(), in: device.container)
            await device.engine.synchronize()
            _ = try await environment.server.deleteAllData(epoch: 0)

            await device.engine.synchronize()
            #expect(device.engine.status == .epochMismatch(currentEpoch: 1))

            let requestCount = await environment.server.pullSinces.count
            await device.engine.synchronize()
            let laterCount = await environment.server.pullSinces.count
            #expect(laterCount == requestCount)
        }
    }

    @Test("未开启同步或登录账号与绑定账号不一致时不请求服务端")
    func skipsWhenDisabledOrDifferentUser() async throws {
        try await withEnvironment { environment in
            let device = try environment.makeDevice()
            device.updateState { $0.isEnabled = false }
            await device.engine.synchronize()
            let sincesWhenDisabled = await environment.server.pullSinces
            #expect(sincesWhenDisabled.isEmpty)

            let otherUserEngine = SyncEngine(
                container: device.container,
                api: environment.server,
                defaults: device.defaults,
                currentUserID: { "someone-else" }
            )
            device.updateState { $0.isEnabled = true }
            await otherUserEngine.synchronize()
            let sincesForOtherUser = await environment.server.pullSinces
            #expect(sincesForOtherUser.isEmpty)
        }
    }

    @Test("重试间隔从 5 秒起翻倍，最长 5 分钟")
    func retryDelayBacksOff() {
        #expect(SyncEngine.retryDelay(attempt: 1) == .seconds(5))
        #expect(SyncEngine.retryDelay(attempt: 2) == .seconds(10))
        #expect(SyncEngine.retryDelay(attempt: 4) == .seconds(40))
        #expect(SyncEngine.retryDelay(attempt: 7) == .seconds(300))
        #expect(SyncEngine.retryDelay(attempt: 50) == .seconds(300))
    }

    // MARK: - 辅助

    /// 在独立的同步环境中执行测试。
    private func withEnvironment(_ body: (SyncTestEnvironment) async throws -> Void) async throws {
        try await SyncTestEnvironment.run(body)
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
        try payload(
            BackupAccount(
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
        )
    }

    /// 把备份 DTO 编码为同步内容。
    private func payload(_ dto: some Encodable) throws -> SyncJSONValue {
        try SyncJSONValue(payload: BackupFileEncoding.makeEncoder().encode(dto))
    }

    /// 读取服务端记录内容中的一个字段。
    private func field(_ name: String, of record: SyncRemoteRecord) -> SyncJSONValue? {
        guard case let .object(fields) = record.payload else { return nil }
        return fields[name]
    }

    /// 全部待上传的台账。
    private func pendingEntries(in container: ModelContainer) throws -> [SyncLedgerEntry] {
        try ModelContext(container).fetch(FetchDescriptor<SyncLedgerEntry>()).filter(\.hasPendingChanges)
    }

    /// 读取一条台账。
    private func ledgerEntry(
        _ entityType: SyncEntityType,
        _ recordID: UUID,
        in container: ModelContainer
    ) throws -> SyncLedgerEntry? {
        let key = SyncLedgerEntry.key(entityType: entityType, recordID: recordID)
        var descriptor = FetchDescriptor<SyncLedgerEntry>(
            predicate: #Predicate<SyncLedgerEntry> { entry in entry.key == key }
        )
        descriptor.fetchLimit = 1
        return try ModelContext(container).fetch(descriptor).first
    }
}
