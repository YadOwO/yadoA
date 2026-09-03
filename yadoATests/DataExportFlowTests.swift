import Foundation
import SwiftData
import Testing
@testable import yadoA

@Suite("数据导出流程", .serialized)
@MainActor
struct DataExportFlowTests {
    /// 每个用例独享的临时导出目录。
    private func makeExportDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "data-export-flow-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test("流程只在显式确认后执行，分享关闭后回到空闲")
    func startsOnlyWhenExplicitlyRequestedAndFinishesCleanly() throws {
        let fileURL = URL(fileURLWithPath: "/tmp/yadoA-flow-test.yadoabackup")
        var callCount = 0
        var removedURL: URL?
        let flow = DataExportFlow(
            exportAction: {
                callCount += 1
                return fileURL
            },
            removeExportedFile: { removedURL = $0 }
        )

        #expect(flow.state == .idle)
        #expect(callCount == 0)

        flow.startExport()
        #expect(flow.state == .sharing(fileURL))
        #expect(callCount == 1)

        flow.finishSharing()
        #expect(flow.state == .idle)
        #expect(removedURL == fileURL)
    }

    @Test("真实服务失败后重试会重新导出并清理临时文件")
    func failureCanRetryWithFreshExport() throws {
        let container = try AccountDataContainer.inMemory()
        let exportDirectory = makeExportDirectory()
        var shouldFail = true
        var attempts = 0
        struct InjectedFailure: Error {}
        let service = BackupExportService(
            container: container.modelContainer,
            exportDirectory: exportDirectory,
            beforeWrite: {
                attempts += 1
                if shouldFail {
                    shouldFail = false
                    throw InjectedFailure()
                }
            }
        )
        let flow = DataExportFlow(service: service)

        flow.startExport()
        #expect(flow.state == .failed(.writeFailed))
        #expect(attempts == 1)

        flow.retry()
        guard case let .sharing(fileURL) = flow.state else {
            Issue.record("重试后应进入 sharing 状态")
            return
        }
        #expect(attempts == 2)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        flow.finishSharing()
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
    }

    @Test("流程初始化时清扫分享期间遗留的文件")
    func initializationSweepsStaleExports() throws {
        let container = try AccountDataContainer.inMemory()
        let exportDirectory = makeExportDirectory()
        try FileManager.default.createDirectory(
            at: exportDirectory,
            withIntermediateDirectories: true
        )
        let staleURL = exportDirectory.appending(path: "stale.yadoabackup")
        try Data("stale".utf8).write(to: staleURL)

        let service = BackupExportService(
            container: container.modelContainer,
            exportDirectory: exportDirectory
        )
        _ = DataExportFlow(service: service)

        #expect(FileManager.default.fileExists(atPath: staleURL.path) == false)
    }

    @Test("导出动作重入时只允许一个执行")
    func reentrantStartIsIgnored() throws {
        let fileURL = URL(fileURLWithPath: "/tmp/yadoA-flow-reentrant-test.yadoabackup")
        var callCount = 0
        var flow: DataExportFlow!
        flow = DataExportFlow(exportAction: {
            callCount += 1
            flow.startExport()
            return fileURL
        })

        flow.startExport()

        #expect(callCount == 1)
        #expect(flow.state == .sharing(fileURL))
    }
}
