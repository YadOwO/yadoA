import Foundation
import SwiftData

/// 备份导出边界产生的错误。
///
/// 错误不携带可展示的记录细节；用户界面只呈现通用失败文案，
/// 避免把财务数据细节泄露到弹窗或日志之外的位置。
enum BackupExportError: Error, Equatable {
    /// 某条流水无法通过持久化字段矩阵校验；关联值为该流水 UUID，仅供诊断。
    case recordUnreadable(UUID)

    /// 备份 JSON 编码失败。
    case encodingFailed

    /// 写入阶段失败（含目录创建与原子写盘）。
    case writeFailed
}

/// 在主 actor 上串行完成「清扫 → 读取 → 校验 → 编码 → 原子写盘」的备份导出服务。
///
/// 完整优先：任何一条记录不可靠时整次导出失败，不产出部分备份文件。
/// 每次导出通过新建 context 读取，保证单一时间点一致的快照；
/// 编辑发生在快照之后的内容不会进入本次备份，`exportedAt` 即备份边界。
@MainActor
final class BackupExportService {
    /// 应用或测试持有的完整本地财务容器。
    private let container: ModelContainer

    /// 导出文件的输出目录；测试注入隔离目录避免并行用例互相污染。
    private let exportDirectory: URL

    /// 导出时间源；测试注入固定时间以获得确定性文件名。
    private let now: () -> Date

    /// 测试可注入的写入前故障点；生产环境默认为空操作。
    private let beforeWrite: () throws -> Void

    /// 文件系统操作边界，测试可注入隔离实现。
    private let fileManager: FileManager

    /// 创建备份导出服务。
    ///
    /// - Parameters:
    ///   - container: 应用或测试持有的完整本地财务容器。
    ///   - exportDirectory: 导出文件输出目录；默认使用 `tmp/exports/`。
    ///   - now: 导出时间源，用于信封时间戳与文件名。
    ///   - beforeWrite: 编码完成后、写盘前执行的故障注入点。
    ///   - fileManager: 文件系统操作边界。
    init(
        container: ModelContainer,
        exportDirectory: URL? = nil,
        now: @escaping () -> Date = { .now },
        beforeWrite: @escaping () throws -> Void = {},
        fileManager: FileManager = .default
    ) {
        self.container = container
        self.exportDirectory = exportDirectory
            ?? FileManager.default.temporaryDirectory
                .appending(path: "exports", directoryHint: .isDirectory)
        self.now = now
        self.beforeWrite = beforeWrite
        self.fileManager = fileManager
    }

    /// 执行完整导出并返回写好的备份文件 URL。
    ///
    /// - Returns: 原子写入完成的备份文件地址。
    /// - Throws: 任一流水校验失败、编码失败或写盘失败时抛出
    ///   `BackupExportError`；失败路径不会在输出目录留下任何文件。
    func export() throws -> URL {
        sweepStaleExports()
        let exportedAt = now()
        let backup = try makeBackup(exportedAt: exportedAt)
        let data = try encodeBackup(backup)
        do {
            try beforeWrite()
        } catch {
            throw BackupExportError.writeFailed
        }

        let fileURL = makeFileURL(exportedAt: exportedAt)
        do {
            try fileManager.createDirectory(
                at: exportDirectory,
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // 原子写入失败时也清扫可能由 Foundation 留下的临时文件。
            sweepStaleExports()
            throw BackupExportError.writeFailed
        }
        return fileURL
    }

    /// 删除分享面板关闭后的导出文件；尽力而为，失败不向调用方抛错。
    func removeExportedFile(at url: URL) {
        try? fileManager.removeItem(at: url)
    }

    /// 清扫输出目录中的全部残留文件。
    ///
    /// 在每次导出开始与启动期调用，覆盖分享面板打开期间进程被杀、
    /// 关闭回调未执行的残留场景。
    func sweepStaleExports() {
        let fileURLs = (try? fileManager.contentsOfDirectory(
            at: exportDirectory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )) ?? []
        for fileURL in fileURLs
        where (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    /// 在单一新鲜 context 中读取、校验并组装备份信封。
    private func makeBackup(exportedAt: Date) throws -> BackupFile {
        let context = makeContext()

        let accounts = try context.fetch(FetchDescriptor<Account>()).sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        let transactions = try context.fetch(FetchDescriptor<AccountTransaction>()).sorted { lhs, rhs in
            if lhs.savedAt != rhs.savedAt { return lhs.savedAt < rhs.savedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        // 完整优先：展示层允许跳过坏行，导出必须整体失败。
        for transaction in transactions {
            do {
                _ = try transaction.validatedPayload()
            } catch {
                throw BackupExportError.recordUnreadable(transaction.id)
            }
        }

        let preference = try canonicalPreference(in: context)
        return BackupFile(
            exportedAt: exportedAt,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "0",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
                as? String ?? "0",
            accounts: accounts.map(BackupAccount.init),
            transactions: transactions.map(BackupTransaction.init),
            bookkeepingPreference: preference.map {
                BackupBookkeepingPreference(defaultAccountID: $0.defaultAccountID)
            }
        )
    }

    /// 使用固定策略编码信封；编码失败映射为领域错误。
    private func encodeBackup(_ backup: BackupFile) throws -> Data {
        do {
            return try BackupFileEncoding.makeEncoder().encode(backup)
        } catch {
            throw BackupExportError.encodingFailed
        }
    }

    /// 生成确定性的备份文件名：产品名 + 日期到分钟，规避同日重复导出重名。
    private func makeFileURL(exportedAt: Date) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let fileName = "yadoA-backup-\(formatter.string(from: exportedAt)).yadoabackup"
        return exportDirectory.appending(path: fileName)
    }

    /// 读取 canonical singleton 偏好，忽略非 canonical 的杂散记录。
    private func canonicalPreference(in context: ModelContext) throws -> BookkeepingPreference? {
        let singletonID = BookkeepingPreference.singletonID
        var descriptor = FetchDescriptor<BookkeepingPreference>(
            predicate: #Predicate<BookkeepingPreference> { preference in
                preference.id == singletonID
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// 创建一个关闭自动保存的新鲜 context。
    private func makeContext() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }
}
