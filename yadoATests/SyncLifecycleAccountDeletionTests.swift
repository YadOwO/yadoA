import Foundation
import SwiftData
import Testing
@testable import yadoA

/// 覆盖注销账号时的本机处理：远端失败不改任何东西，成功后先解除绑定再按选择处理本机数据。
@Suite("注销账号的同步生命周期", .serialized)
@MainActor
struct SyncLifecycleAccountDeletionTests {
    /// 测试用的远端失败。
    private struct RemoteFailure: Error, Equatable {}

    @Test("远端删除失败：错误原样抛出，绑定状态和本机数据不变")
    func remoteFailureChangesNothing() async throws {
        try await SyncTestEnvironment.run { environment in
            let device = try environment.makeDevice()
            try saveAccount(in: device.container)
            let before = device.state

            await #expect(throws: RemoteFailure()) {
                try await lifecycle(for: device, in: environment).deleteAccount(.eraseFromDevice) {
                    throw RemoteFailure()
                }
            }
            #expect(device.state == before)
            #expect(device.state.isBound)
            #expect(try accountCount(in: device.container) == 1)
        }
    }

    @Test("意见反馈删除失败：注销中止，绑定和本机数据不变，不会删除账号")
    func feedbackFailureChangesNothingAndSkipsAccountDeletion() async throws {
        try await SyncTestEnvironment.run { environment in
            let device = try environment.makeDevice()
            try saveAccount(in: device.container)
            let before = device.state
            let deleter = FakeAccountDeleter(failing: .feedback, error: .serviceUnavailable)

            await #expect(throws: AccountDeletionAPIError.serviceUnavailable) {
                try await lifecycle(for: device, in: environment).deleteAccount(.eraseFromDevice) {
                    try await deleter.deleteRemoteData()
                }
            }
            #expect(device.state == before)
            #expect(device.state.isBound)
            #expect(try accountCount(in: device.container) == 1)
            #expect(deleter.calls == [.ai, .feedback])
            #expect(!deleter.calls.contains(.account))
        }
    }

    @Test("保留在本机：成功后解除绑定，本机数据还在")
    func keepOnDeviceUnbindsAndKeepsData() async throws {
        try await SyncTestEnvironment.run { environment in
            let device = try environment.makeDevice()
            try saveAccount(in: device.container)

            try await lifecycle(for: device, in: environment).deleteAccount(.keepOnDevice) {}

            #expect(!device.state.isBound)
            #expect(try accountCount(in: device.container) == 1)
        }
    }

    @Test("从本机清除：成功后解除绑定，本机数据被清空")
    func eraseFromDeviceUnbindsAndErasesData() async throws {
        try await SyncTestEnvironment.run { environment in
            let device = try environment.makeDevice()
            try saveAccount(in: device.container)

            try await lifecycle(for: device, in: environment).deleteAccount(.eraseFromDevice) {}

            #expect(!device.state.isBound)
            #expect(try accountCount(in: device.container) == 0)
        }
    }

    // MARK: - 辅助方法

    /// 不带同步引擎的生命周期服务，只检查数据和同步状态。
    private func lifecycle(for device: SyncTestDevice, in environment: SyncTestEnvironment) -> SyncLifecycle {
        SyncLifecycle(container: device.container, api: environment.server, defaults: device.defaults, engine: nil)
    }

    /// 保存一个现金账户。
    private func saveAccount(in container: ModelContainer) throws {
        try LocalAccountRepository(container: container).save(
            AccountDraft(id: UUID(), accountType: .cash, template: nil, name: "现金", amountText: "100"),
            locale: Locale(identifier: "en_US")
        )
    }

    /// 本机账户数量。
    private func accountCount(in container: ModelContainer) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<Account>())
    }
}
