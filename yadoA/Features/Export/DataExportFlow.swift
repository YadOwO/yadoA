import Combine
import Foundation

/// 数据导出流程的可观察状态。
enum DataExportState: Equatable {
    /// 尚未开始导出，或分享完成后已复位。
    case idle

    /// 正在读取、校验和写入备份文件。
    case preparing

    /// 备份文件已生成，等待系统分享面板结束。
    case sharing(URL)

    /// 导出失败，用户可以重试或关闭提示。
    case failed(BackupExportError)
}

/// 系统分享面板需要的备份文件值类型。
struct DataExportShareItem: Identifiable, Equatable {
    /// 已完成原子写入的备份文件地址。
    let url: URL

    /// 以文件地址作为稳定标识，避免同一流程重复呈现同一面板。
    var id: URL { url }
}

/// 在主 actor 上协调确认后的导出、分享和临时文件清理。
@MainActor
final class DataExportFlow: ObservableObject {
    /// 当前导出状态；视图据此控制入口、错误提示和分享面板。
    @Published private(set) var state: DataExportState = .idle

    /// 实际导出动作；生产环境由 `BackupExportService` 提供，测试可注入。
    private let exportAction: () throws -> URL

    /// 分享面板关闭后的临时文件清理动作。
    private let removeExportedFile: (URL) -> Void

    /// 使用生产导出服务创建流程，并在初始化时清扫上次残留。
    ///
    /// - Parameter service: 当前本地财务容器对应的导出服务。
    init(service: BackupExportService) {
        exportAction = { try service.export() }
        removeExportedFile = service.removeExportedFile
        service.sweepStaleExports()
    }

    /// 创建可注入的导出流程，供状态机测试覆盖失败与重试路径。
    ///
    /// - Parameters:
    ///   - exportAction: 确认后执行的完整导出动作。
    ///   - removeExportedFile: 分享关闭后删除临时文件的动作。
    init(
        exportAction: @escaping () throws -> URL,
        removeExportedFile: @escaping (URL) -> Void = { _ in }
    ) {
        self.exportAction = exportAction
        self.removeExportedFile = removeExportedFile
    }

    /// 当前是否正在执行导出，供入口行防止重复触发。
    var isPreparing: Bool {
        state == .preparing
    }

    /// 当前失败错误；非失败状态返回 `nil`。
    var failure: BackupExportError? {
        guard case let .failed(error) = state else { return nil }
        return error
    }

    /// 当前已生成的分享文件；非分享状态返回 `nil`。
    var shareItem: DataExportShareItem? {
        guard case let .sharing(url) = state else { return nil }
        return DataExportShareItem(url: url)
    }

    /// 执行一次从新鲜本地数据开始的完整导出。
    ///
    /// 只有空闲或失败状态可以开始；分享面板仍打开时拒绝重入。
    func startExport() {
        guard state == .idle || failure != nil else { return }

        state = .preparing
        do {
            state = .sharing(try exportAction())
        } catch let error as BackupExportError {
            state = .failed(error)
        } catch {
            // 注入动作不应绕过统一的本地化错误反馈。
            state = .failed(.encodingFailed)
        }
    }

    /// 从失败状态重新读取并执行完整导出管线。
    func retry() {
        guard failure != nil else { return }
        startExport()
    }

    /// 分享面板关闭后删除临时文件并回到空闲状态。
    func finishSharing() {
        if case let .sharing(url) = state {
            removeExportedFile(url)
        }
        state = .idle
    }

    /// 关闭失败提示，不执行导出也不写入文件。
    func dismissFailure() {
        guard failure != nil else { return }
        state = .idle
    }
}
