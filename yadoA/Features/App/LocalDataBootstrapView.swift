import Combine
import SwiftData
import SwiftUI

/// 本地数据引导当前所处的用户可见阶段。
enum LocalDataBootstrapPhase: Equatable {
    /// 首次初始化文件容器。
    case initializing
    /// 文件容器已准备好，可以进入账户界面。
    case ready
    /// 用户触发重试且初始化尚未完成。
    case retrying
    /// 最近一次初始化失败，关联累计尝试次数。
    case failed(attempts: Int)
}

/// 存储失败对应的用户处理阶段。
enum LocalDataFailureKind: Equatable {
    /// 首次失败，允许用户再次尝试打开同一存储。
    case retryable
    /// 连续失败，强调文件已保留并提供支持提示。
    case dataPreserved
}

/// 管理生产文件容器初始化、阻断和安全重试的状态对象。
@MainActor
final class LocalDataBootstrap: ObservableObject {
    /// 当前引导阶段。
    @Published private(set) var phase: LocalDataBootstrapPhase = .initializing

    /// 仅在生产文件容器成功创建后才会提供的数据容器。
    @Published private(set) var dataContainer: AccountDataContainer?

    /// 生产容器工厂；失败时不会调用内存容器作为降级。
    private let makeDataContainer: () async throws -> AccountDataContainer

    /// 累计初始化次数，用于持续失败后的支持提示。
    private var attempts = 0

    /// 防止同一时刻重复激活容器。
    private var isActivating = false

    /// 根据连续失败次数切换“可重试”或“数据保护与支持”提示。
    var failureKind: LocalDataFailureKind {
        guard case let .failed(attempts) = phase, attempts > 1 else {
            return .retryable
        }
        return .dataPreserved
    }

    /// 创建本地数据引导状态。
    init(
        makeDataContainer: @escaping () async throws -> AccountDataContainer = {
            try await Task.detached(priority: .userInitiated) {
                try AccountDataContainer.production()
            }.value
        }
    ) {
        self.makeDataContainer = makeDataContainer
    }

    /// 首次激活生产容器；就绪或正在激活时不会重复创建。
    func activate() async {
        guard dataContainer == nil, !isActivating else { return }
        await initialize(isRetry: attempts > 0)
    }

    /// 从阻断状态安全重试同一生产位置，不删除或重建存储文件。
    func retry() async {
        guard dataContainer == nil, !isActivating else { return }
        await initialize(isRetry: true)
    }

    /// 执行一次容器初始化并收敛到 ready 或 failed。
    private func initialize(isRetry: Bool) async {
        isActivating = true
        phase = isRetry ? .retrying : .initializing
        attempts += 1
        defer { isActivating = false }

        do {
            let container = try await makeDataContainer()
            guard case .file = container.storage else {
                // 生产引导绝不接受临时存储，即使工厂被错误配置。
                throw LocalDataBootstrapError.ephemeralStoreRejected
            }
            dataContainer = container
            phase = .ready
        } catch {
            dataContainer = nil
            phase = .failed(attempts: attempts)
        }
    }
}

/// 生产引导拒绝不安全存储配置时的内部错误。
private enum LocalDataBootstrapError: Error {
    case ephemeralStoreRejected
}

/// 在本地文件数据可用前阻断账户界面的应用级引导视图。
struct LocalDataBootstrapView<Content: View>: View {
    @StateObject private var bootstrap: LocalDataBootstrap
    private let content: () -> Content

    /// 创建使用生产文件容器的引导视图。
    init(@ViewBuilder content: @escaping () -> Content) {
        _bootstrap = StateObject(wrappedValue: LocalDataBootstrap())
        self.content = content
    }

    /// 创建可注入容器工厂的引导视图，供预览和测试使用。
    init(
        makeDataContainer: @escaping () async throws -> AccountDataContainer,
        @ViewBuilder content: @escaping () -> Content
    ) {
        _bootstrap = StateObject(
            wrappedValue: LocalDataBootstrap(makeDataContainer: makeDataContainer)
        )
        self.content = content
    }

    var body: some View {
        Group {
            switch bootstrap.phase {
            case .initializing, .retrying:
                ProgressView(AccountLocalization.string("local_data.loading"))
            case .ready:
                if let dataContainer = bootstrap.dataContainer {
                    content()
                        .modelContainer(dataContainer.modelContainer)
                } else {
                    blockedContent
                }
            case .failed:
                blockedContent
            }
        }
        .task {
            await bootstrap.activate()
        }
    }

    /// 文件容器失败后的数据保护说明与显式重试入口。
    private var blockedContent: some View {
        ContentUnavailableView {
            Label(
                AccountLocalization.string("local_data.error.title"),
                systemImage: "externaldrive.badge.exclamationmark"
            )
        } description: {
            Text(AccountLocalization.string(failureMessageLocalizationKey))
        } actions: {
            Button(AccountLocalization.string("common.retry")) {
                Task {
                    await bootstrap.retry()
                }
            }
        }
    }

    /// 当前失败阶段对应的本地化说明键。
    private var failureMessageLocalizationKey: String {
        switch bootstrap.failureKind {
        case .retryable:
            "local_data.error.retry_message"
        case .dataPreserved:
            "local_data.error.protection_message"
        }
    }
}
