import Combine
import Foundation

/// 数据恢复流程的可观察状态。
enum DataImportState: Equatable {
    /// 尚未选择备份，或上一次流程已结束。
    case idle

    /// 备份已通过校验，等待用户确认替换本地数据。
    case confirming(BackupImportPlan)

    /// 读取、校验或写入失败，用户关闭提示后可重新选择文件。
    case failed(BackupImportError)

    /// 恢复已完成，等待用户关闭结果提示。
    case succeeded(BackupImportPlan)
}

/// 在主 actor 上协调「选择文件 → 校验 → 确认 → 恢复」的状态机。
///
/// 只有用户在确认提示中明确同意后才会写入存储；
/// 校验失败和取消都不会触碰现有数据。
@MainActor
final class DataImportFlow: ObservableObject {
    /// 当前恢复状态；视图据此控制确认、失败和完成提示。
    @Published private(set) var state: DataImportState = .idle

    /// 读取并校验备份文件的动作；生产环境由 `BackupImportService` 提供。
    private let prepareAction: (URL) throws -> BackupImportPlan

    /// 用户确认后执行的整体替换动作。
    private let restoreAction: (BackupImportPlan) throws -> Void

    /// 使用生产导入服务创建流程。
    ///
    /// - Parameter service: 当前本地财务容器对应的导入服务。
    convenience init(service: BackupImportService) {
        self.init(
            prepareAction: { try service.prepare(from: $0) },
            restoreAction: { try service.restore($0) }
        )
    }

    /// 创建可注入的恢复流程，供状态机测试覆盖失败与取消路径。
    ///
    /// - Parameters:
    ///   - prepareAction: 读取并校验所选文件的动作。
    ///   - restoreAction: 确认后执行的整体替换动作。
    init(
        prepareAction: @escaping (URL) throws -> BackupImportPlan,
        restoreAction: @escaping (BackupImportPlan) throws -> Void
    ) {
        self.prepareAction = prepareAction
        self.restoreAction = restoreAction
    }

    /// 等待确认的恢复计划；非确认状态返回 `nil`。
    var pendingPlan: BackupImportPlan? {
        guard case let .confirming(plan) = state else { return nil }
        return plan
    }

    /// 当前失败错误；非失败状态返回 `nil`。
    var failure: BackupImportError? {
        guard case let .failed(error) = state else { return nil }
        return error
    }

    /// 已完成恢复的计划；非完成状态返回 `nil`。
    var completedPlan: BackupImportPlan? {
        guard case let .succeeded(plan) = state else { return nil }
        return plan
    }

    /// 读取并校验用户选择的备份文件，成功后进入确认状态。
    ///
    /// 确认提示仍在展示时拒绝重入，避免计划被悄悄替换。
    func loadBackup(from url: URL) {
        guard pendingPlan == nil else { return }
        do {
            state = .confirming(try prepareAction(url))
        } catch {
            state = .failed(Self.importError(from: error))
        }
    }

    /// 文件选择器自身报错时进入失败状态。
    func failSelection() {
        guard pendingPlan == nil else { return }
        state = .failed(.fileUnreadable)
    }

    /// 用户确认后执行整体替换。
    func confirmRestore() {
        guard let plan = pendingPlan else { return }
        do {
            try restoreAction(plan)
            state = .succeeded(plan)
        } catch {
            state = .failed(Self.importError(from: error))
        }
    }

    /// 关闭确认、失败或完成提示并回到空闲状态；不写入存储。
    func dismiss() {
        state = .idle
    }

    /// 注入动作不应绕过统一的本地化错误反馈。
    private static func importError(from error: Error) -> BackupImportError {
        error as? BackupImportError ?? .restoreFailed
    }
}
