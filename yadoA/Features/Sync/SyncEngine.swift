import Foundation
import OSLog
import Observation
import SwiftData

/// 同步失败的原因，界面据此展示提示。
enum SyncFailure: Error, Equatable {
    /// 接口调用失败。
    case api(SyncAPIError)

    /// 读写本地数据失败。
    case storage
}

/// 同步调度器：保证同一时间只有一轮同步，按「先拉后推」执行，失败时按指数退避重试。
///
/// 一轮同步：
/// 1. 本机进度为 0（首次、收到 resetRequired、同步格式升级）时做一轮全量拉取：翻完所有页，合并后一次性替换本地；
///    否则逐页增量拉取并应用；
/// 2. 拉取完成后分批推送待上传的台账，每批 `SyncContractLimits.maxPushChanges` 条；
///    推送被要求先全量拉取时，做一轮全量拉取后继续推送。
///
/// 只有开启了同步、且本机绑定的账号就是当前登录账号时才执行；绑定与开关由 U6 的生命周期流程维护。
@MainActor
@Observable
final class SyncEngine {
    /// 同步状态。
    enum Status: Equatable {
        /// 空闲：未开启同步，或上一轮已成功完成。
        case idle

        /// 正在同步。
        case syncing

        /// 上一轮失败；临时故障会自动重试。
        case failed(SyncFailure)

        /// 云端数据已被其他设备删除，本机代次过期；暂停同步，等待用户处理（U6）。
        case epochMismatch(currentEpoch: Int)
    }

    /// 当前的同步格式版本；以后新增同步类型时加 1，旧版本客户端升级后会重新全量同步，补回之前忽略的类型。
    static let currentSchemaVersion = 1

    /// 本地修改后等待多久再同步，合并连续的保存。
    static let localChangeDebounce: Duration = .seconds(2)

    /// 自动重试的最长间隔。
    static let maxRetryDelay: Duration = .seconds(300)

    /// 一轮推送最多的批数，防止异常情况下无限循环（250 × 200 = 5 万条）。
    private static let maxPushBatchesPerRun = 200

    /// 当前状态。
    private(set) var status: Status = .idle

    /// 最近一次成功同步的时间。
    private(set) var lastSyncedAt: Date?

    /// 最近一轮发现的、因内容过大而不会上传的记录数。
    private(set) var oversizedRecordCount = 0

    /// 同步接口。
    private let api: any SyncServing

    /// 本地读写边界。
    private let store: SyncStore

    /// 保存同步状态的 UserDefaults。
    private let defaults: UserDefaults

    /// 读取当前登录用户 ID 的动作。
    private let currentUserID: () -> String?

    /// 正在执行的一轮同步。
    private var runTask: Task<Void, Never>?

    /// 同步进行中又有新的触发，本轮结束后再跑一轮。
    private var needsAnotherRun = false

    /// 等待中的防抖或重试。
    private var scheduledTask: Task<Void, Never>?

    /// 连续失败的次数，决定下一次重试的间隔。
    private var retryAttempt = 0

    /// 暂停同步时本机记录的代次；`SyncState.epoch` 被 U6 更新前不再请求。
    private var pausedEpoch: Int?

    /// 本地修改通知的监听。
    private var localChangeObserver: NSObjectProtocol?

    /// 创建同步调度器。
    ///
    /// - Parameters:
    ///   - container: 本地财务容器。
    ///   - api: 同步接口。
    ///   - defaults: 保存同步状态的 UserDefaults。
    ///   - currentUserID: 读取当前登录用户 ID 的动作，通常是 `AuthStore.userID`。
    init(
        container: ModelContainer,
        api: any SyncServing,
        defaults: UserDefaults = .standard,
        currentUserID: @escaping () -> String?
    ) {
        self.api = api
        store = SyncStore(container: container)
        self.defaults = defaults
        self.currentUserID = currentUserID
        lastSyncedAt = SyncState.load(from: defaults).lastSyncedAt
    }

    /// 开始监听本地修改，并立即同步一次（App 启动）。
    func start() {
        if localChangeObserver == nil {
            localChangeObserver = NotificationCenter.default.addObserver(
                forName: .syncLedgerDidRecordLocalChanges,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleAfterLocalChange()
                }
            }
        }
        syncNow()
    }

    /// 停止监听并取消等待中的同步；正在进行的一轮不中断。
    func stop() {
        if let localChangeObserver {
            NotificationCenter.default.removeObserver(localChangeObserver)
        }
        localChangeObserver = nil
        scheduledTask?.cancel()
        scheduledTask = nil
    }

    /// 立即同步（启动、回到前台、用户手动触发）；正在同步时，本轮结束后再跑一轮。
    func syncNow() {
        scheduledTask?.cancel()
        scheduledTask = nil
        guard runTask == nil else {
            needsAnotherRun = true
            return
        }
        runTask = Task { [weak self] in
            await self?.runUntilSettled()
        }
    }

    /// 立即同步并等待完成；测试和「立即同步」按钮使用。
    func synchronize() async {
        syncNow()
        await runTask?.value
    }

    /// 本地保存后防抖同步。
    func scheduleAfterLocalChange() {
        schedule(after: Self.localChangeDebounce)
    }

    // MARK: - 一轮同步

    /// 连续执行，直到没有新的触发。
    private func runUntilSettled() async {
        repeat {
            needsAnotherRun = false
            await runOnce()
        } while needsAnotherRun
        runTask = nil
    }

    /// 执行一轮同步并处理结果。
    private func runOnce() async {
        var state = SyncState.load(from: defaults)
        guard state.isEnabled, let boundUserID = state.boundUserID, boundUserID == currentUserID() else {
            status = .idle
            return
        }
        if let pausedEpoch, pausedEpoch == state.epoch { return }
        pausedEpoch = nil

        status = .syncing
        do {
            if state.syncSchemaVersion < Self.currentSchemaVersion {
                state.since = 0
            }
            try await pull(&state)
            try await push(&state)
            state.lastSyncedAt = .now
            persistProgress(of: state)
            lastSyncedAt = state.lastSyncedAt
            retryAttempt = 0
            status = .idle
        } catch let error as SyncAPIError {
            handle(error, epoch: state.epoch)
        } catch {
            SyncRecordApplier.logger.error("同步写入本地数据失败：\(String(describing: error), privacy: .public)")
            status = .failed(.storage)
        }
    }

    /// 拉取：本机进度为 0 时全量，否则逐页增量；增量时被要求重置则改做全量。
    private func pull(_ state: inout SyncState) async throws {
        guard state.since > 0 else {
            try await fullPull(&state)
            return
        }
        while true {
            let page = try await api.pull(since: state.since, deviceID: state.deviceID, epoch: state.epoch, limit: nil)
            if page.resetRequired {
                try await fullPull(&state)
                return
            }
            if !page.changes.isEmpty {
                try store.applyIncremental(page.changes)
            }
            // 每页应用后立刻记下进度，中途失败时下次从这里继续
            state.since = page.nextSince
            persistProgress(of: state)
            guard page.hasMore else { return }
        }
    }

    /// 全量拉取：翻完所有页、合并整轮结果后一次性替换本地，再记下最后一页的 nextSince。
    ///
    /// 单页不是完整状态，整轮完成前不应用、不推送。
    private func fullPull(_ state: inout SyncState) async throws {
        var records: [SyncRemoteRecord] = []
        var cursor: Int64 = 0
        while true {
            let page = try await api.pull(since: cursor, deviceID: state.deviceID, epoch: state.epoch, limit: nil)
            // since = 0 时服务端不会要求重置；出现即契约不符
            guard !page.resetRequired else { throw SyncAPIError.invalidContract }
            records.append(contentsOf: page.changes)
            cursor = page.nextSince
            guard page.hasMore else { break }
        }
        try store.replaceAll(with: records)
        state.since = cursor
        state.syncSchemaVersion = Self.currentSchemaVersion
        persistProgress(of: state)
    }

    /// 把本轮推进的进度写回，只改引擎负责的字段（进度、同步格式版本、同步时间）。
    ///
    /// 开关、绑定和代次由 U6 的生命周期流程维护，可能在本轮进行中被修改，所以每次重新读取再合并；
    /// 期间绑定、代次或设备标识变了时丢弃本轮进度。
    private func persistProgress(of run: SyncState) {
        var latest = SyncState.load(from: defaults)
        guard latest.boundUserID == run.boundUserID,
              latest.epoch == run.epoch,
              latest.deviceID == run.deviceID
        else { return }
        latest.since = run.since
        latest.syncSchemaVersion = run.syncSchemaVersion
        latest.lastSyncedAt = run.lastSyncedAt
        latest.save(to: defaults)
    }

    /// 分批推送待上传的台账，直到没有待上传的记录。
    private func push(_ state: inout SyncState) async throws {
        var hasResetOnce = false
        for _ in 0 ..< Self.maxPushBatchesPerRun {
            let batch = try store.pendingBatch()
            oversizedRecordCount = batch.oversizedCount
            guard !batch.items.isEmpty else { return }

            let response = try await api.push(
                SyncPushRequest(
                    deviceID: state.deviceID,
                    epoch: state.epoch,
                    since: state.since,
                    changes: batch.items.map(\.change)
                )
            )
            if response.resetRequired {
                // 本机进度落后于墓碑清理边界：全量拉取后用新的进度重推；连续两次仍被要求重置视为异常
                guard !hasResetOnce else { throw SyncAPIError.invalidContract }
                hasResetOnce = true
                try await fullPull(&state)
                continue
            }
            try store.applyPushResults(batch, response: response)
        }
    }

    // MARK: - 失败与重试

    /// 处理接口错误：代次不一致时暂停；临时故障按指数退避重试；其他错误等待下一次触发。
    private func handle(_ error: SyncAPIError, epoch: Int) {
        status = .failed(.api(error))
        if case let .epochMismatch(currentEpoch) = error {
            pausedEpoch = epoch
            status = .epochMismatch(currentEpoch: currentEpoch)
            return
        }
        guard error.isRetryable else { return }
        retryAttempt += 1
        schedule(after: Self.retryDelay(attempt: retryAttempt))
    }

    /// 第 n 次重试前等待的时间：5 秒起翻倍，最长 5 分钟。
    ///
    /// - Parameter attempt: 连续失败次数，从 1 开始。
    /// - Returns: 等待时长。
    static func retryDelay(attempt: Int) -> Duration {
        let exponent = min(max(attempt, 1), 10) - 1
        return min(.seconds(5 << exponent), maxRetryDelay)
    }

    /// 延迟一段时间后同步；新的安排覆盖旧的。
    private func schedule(after delay: Duration) {
        scheduledTask?.cancel()
        scheduledTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.syncNow()
        }
    }
}
