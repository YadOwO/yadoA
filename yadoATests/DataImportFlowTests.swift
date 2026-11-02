import Foundation
import Testing
@testable import yadoA

@Suite("数据恢复流程", .serialized)
@MainActor
struct DataImportFlowTests {
    private let fileURL = URL(fileURLWithPath: "/tmp/yadoA-flow-test.yadoabackup")

    private func makePlan(replacesExistingData: Bool = true) -> BackupImportPlan {
        BackupImportPlan(
            backup: BackupFile(
                exportedAt: Date(timeIntervalSince1970: 1_000),
                appVersion: "1.0",
                appBuild: "1",
                accounts: [],
                transactions: [],
                bookkeepingPreference: nil
            ),
            replacesExistingData: replacesExistingData
        )
    }

    @Test("选择文件只进入确认状态，确认后才执行恢复")
    func restoresOnlyAfterExplicitConfirmation() {
        let plan = makePlan()
        var restoredPlans: [BackupImportPlan] = []
        let flow = DataImportFlow(
            prepareAction: { _ in plan },
            restoreAction: { restoredPlans.append($0) }
        )

        flow.loadBackup(from: fileURL)
        #expect(flow.state == .confirming(plan))
        #expect(restoredPlans.isEmpty)

        flow.confirmRestore()
        #expect(flow.state == .succeeded(plan))
        #expect(restoredPlans == [plan])

        flow.dismiss()
        #expect(flow.state == .idle)
    }

    @Test("取消确认不会写入，未确认时调用恢复无效")
    func cancelSkipsRestore() {
        var restoreCount = 0
        let flow = DataImportFlow(
            prepareAction: { [self] _ in makePlan() },
            restoreAction: { _ in restoreCount += 1 }
        )

        flow.confirmRestore()
        flow.loadBackup(from: fileURL)
        flow.dismiss()
        flow.confirmRestore()

        #expect(flow.state == .idle)
        #expect(restoreCount == 0)
    }

    @Test("校验失败进入失败状态，关闭后可重新选择")
    func prepareFailureCanBeRetried() {
        var shouldFail = true
        let plan = makePlan()
        let flow = DataImportFlow(
            prepareAction: { _ in
                if shouldFail { throw BackupImportError.invalidFormat }
                return plan
            },
            restoreAction: { _ in }
        )

        flow.loadBackup(from: fileURL)
        #expect(flow.failure == .invalidFormat)

        shouldFail = false
        flow.dismiss()
        flow.loadBackup(from: fileURL)
        #expect(flow.pendingPlan == plan)
    }

    @Test("恢复失败与未知错误统一映射为可展示的导入错误")
    func restoreFailureMapsToImportError() {
        struct InjectedFailure: Error {}
        let flow = DataImportFlow(
            prepareAction: { [self] _ in makePlan() },
            restoreAction: { _ in throw InjectedFailure() }
        )

        flow.loadBackup(from: fileURL)
        flow.confirmRestore()
        #expect(flow.failure == .restoreFailed)

        flow.dismiss()
        flow.failSelection()
        #expect(flow.failure == .fileUnreadable)
    }
}
