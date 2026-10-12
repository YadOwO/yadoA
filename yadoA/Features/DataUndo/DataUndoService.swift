import Foundation
import SwiftData

/// 可以被撤销的整体数据操作。
nonisolated enum DataUndoOperation: String, Codable, Sendable {
    /// 从备份恢复（整体替换本地数据）。
    case restore

    /// 清除所有数据。
    case reset
}

/// 撤销功能的固定规则。
nonisolated enum DataUndoPolicy {
    /// 快照的保留天数；超过后自动失效并删除。
    static let retentionDays = 7

    /// 快照的保留时长（秒）。
    static let retention = TimeInterval(retentionDays) * 24 * 60 * 60
}

/// 操作执行前保存的完整数据快照，撤销时用它整体还原。
///
/// 只保留最近一次操作的快照；新的操作会覆盖旧快照。
nonisolated struct DataUndoSnapshot: Codable, Equatable, Sendable {
    /// 产生这份快照的操作类型，决定入口与提示文案。
    let operation: DataUndoOperation

    /// 操作发生的时间，也是保留期的起点。
    let createdAt: Date

    /// 操作执行前的全部业务数据。
    let backup: BackupFile

    /// 快照失效时间；到达后不再允许撤销。
    var expiresAt: Date { createdAt.addingTimeInterval(DataUndoPolicy.retention) }

    /// 撤销后会回来的账户数量。
    var accountCount: Int { backup.accounts.count }

    /// 撤销后会回来的流水数量。
    var transactionCount: Int { backup.transactions.count }
}

/// 撤销边界产生的错误。
enum DataUndoError: Error, Equatable {
    /// 操作前的快照无法生成或保存；操作未执行，数据保持原样。
    case snapshotFailed

    /// 没有可用快照（从未操作、已撤销或已过期）。
    case nothingToUndo

    /// 还原快照失败；数据保持撤销前的状态，快照仍然保留。
    case undoFailed
}

extension Notification.Name {
    /// 撤销快照被创建、使用或删除后发出，入口据此刷新显隐。
    static let dataUndoSnapshotDidChange = Notification.Name("DataUndoSnapshotDidChange")
}

/// 在主 actor 上管理「操作前存快照 → 保留期内整体还原」的撤销服务。
///
/// 快照先写入待定文件，操作成功后才转正：操作失败时旧快照原样保留，
/// 不会出现「数据没变、可撤销的内容却被换掉」的状态。
/// 撤销复用备份恢复的整体替换，因此操作之后新增或修改的内容会被快照覆盖。
@MainActor
final class DataUndoService {
    /// 应用或测试持有的完整本地财务容器。
    private let container: ModelContainer

    /// 快照所在目录；测试注入隔离目录。
    private let directory: URL

    /// 时间源；测试注入固定时间以覆盖保留期边界。
    private let now: () -> Date

    /// 测试可注入的还原保存前故障点；生产环境默认为空操作。
    private let beforeSave: () throws -> Void

    /// 文件系统操作边界。
    private let fileManager: FileManager

    /// 创建撤销服务。
    ///
    /// - Parameters:
    ///   - container: 应用或测试持有的完整本地财务容器。
    ///   - directory: 快照目录；默认按容器是否为内存存储自动选择。
    ///   - now: 时间源，用于快照时间与保留期判断。
    ///   - beforeSave: 撤销还原保存前执行的故障注入点。
    ///   - fileManager: 文件系统操作边界。
    init(
        container: ModelContainer,
        directory: URL? = nil,
        now: @escaping () -> Date = { .now },
        beforeSave: @escaping () throws -> Void = {},
        fileManager: FileManager = .default
    ) {
        self.container = container
        self.directory = directory ?? Self.defaultDirectory(for: container)
        self.now = now
        self.beforeSave = beforeSave
        self.fileManager = fileManager
    }

    /// 先保存当前数据的快照，再执行会整体改写数据的操作。
    ///
    /// 账本本来就是空的时候执行清除不产生新快照，
    /// 避免连续清除两次把上一份还有内容的快照换成空快照。
    ///
    /// - Parameters:
    ///   - operation: 即将执行的操作类型。
    ///   - work: 实际改写数据的动作。
    /// - Throws: 快照失败抛出 `DataUndoError.snapshotFailed`（此时 `work` 不会执行）；
    ///   `work` 自身的错误原样抛出，旧快照保持不变。
    func perform(_ operation: DataUndoOperation, _ work: () throws -> Void) throws {
        let backup: BackupFile
        do {
            backup = try BackupExportService(container: container, now: now).makeSnapshot()
        } catch {
            throw DataUndoError.snapshotFailed
        }

        if operation == .reset, backup.accounts.isEmpty, backup.transactions.isEmpty {
            try work()
            return
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let snapshot = DataUndoSnapshot(operation: operation, createdAt: now(), backup: backup)
            try BackupFileEncoding.makeEncoder().encode(snapshot).write(to: pendingURL, options: .atomic)
        } catch {
            try? fileManager.removeItem(at: pendingURL)
            throw DataUndoError.snapshotFailed
        }

        do {
            try work()
        } catch {
            try? fileManager.removeItem(at: pendingURL)
            throw error
        }

        // 操作已生效，待定快照转正并覆盖上一份快照。
        try? fileManager.removeItem(at: snapshotURL)
        try? fileManager.moveItem(at: pendingURL, to: snapshotURL)
        notifyChange()
    }

    /// 当前仍在保留期内的快照；过期或损坏的快照会被顺手删除。
    func availableSnapshot() -> DataUndoSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        guard let snapshot = try? BackupFileEncoding.makeDecoder().decode(DataUndoSnapshot.self, from: data),
              now() < snapshot.expiresAt
        else {
            try? fileManager.removeItem(at: snapshotURL)
            return nil
        }
        return snapshot
    }

    /// 用快照整体还原数据；成功后删除快照，撤销本身不能再被撤销。
    ///
    /// - Throws: 没有可用快照抛出 `.nothingToUndo`；还原失败抛出 `.undoFailed`，
    ///   此时数据保持撤销前的状态，快照仍可再次使用。
    func undo() throws {
        guard let snapshot = availableSnapshot() else {
            notifyChange()
            throw DataUndoError.nothingToUndo
        }
        do {
            try BackupImportService(container: container, beforeSave: beforeSave).restore(
                BackupImportPlan(backup: snapshot.backup, replacesExistingData: true)
            )
        } catch {
            throw DataUndoError.undoFailed
        }
        discardSnapshot()
    }

    /// 删除当前快照；尽力而为，失败不向调用方抛错。
    func discardSnapshot() {
        try? fileManager.removeItem(at: snapshotURL)
        try? fileManager.removeItem(at: pendingURL)
        notifyChange()
    }

    /// 已转正、可用于撤销的快照文件。
    private var snapshotURL: URL { directory.appending(path: "last-operation.json") }

    /// 操作尚未确认成功时的待定快照文件。
    private var pendingURL: URL { directory.appending(path: "pending-operation.json") }

    /// 通知入口刷新显隐。
    private func notifyChange() {
        NotificationCenter.default.post(name: .dataUndoSnapshotDidChange, object: nil)
    }

    /// 生产容器把快照放在 Application Support；内存容器（预览、UI 自动化）
    /// 使用按进程隔离的临时目录，避免残留快照串到下一次启动。
    private static func defaultDirectory(for container: ModelContainer) -> URL {
        if container.configurations.contains(where: \.isStoredInMemoryOnly) {
            return FileManager.default.temporaryDirectory.appending(
                path: "undo-snapshot-\(ProcessInfo.processInfo.processIdentifier)",
                directoryHint: .isDirectory
            )
        }
        return URL.applicationSupportDirectory
            .appending(path: "UndoSnapshot", directoryHint: .isDirectory)
    }
}
