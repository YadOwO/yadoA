import Foundation
import SwiftData

/// 账户数据容器及其显式存储介质。
struct AccountDataContainer {
    /// 容器实际使用的存储介质，防止生产环境误用临时存储。
    enum Storage: Equatable {
        /// 持久化到指定 URL 的文件存储。
        case file(URL)
        /// 仅供预览和隔离测试使用的内存存储。
        case inMemory
    }

    /// 应用和 SwiftUI 环境共享的 SwiftData 容器。
    let modelContainer: ModelContainer

    /// 创建容器时明确选择的存储介质。
    let storage: Storage

    /// 当前本地财务 schema，包含账户与类型化账户流水。
    static let schema = Schema(
        [Account.self, AccountTransaction.self],
        version: .init(3, 0, 0)
    )

    /// 创建生产环境文件存储，不会在失败时删除、替换或降级现有文件。
    ///
    /// - Parameter storeURL: 可选的显式文件 URL；默认使用 Application Support。
    /// - Returns: 基于文件的账户数据容器。
    /// - Throws: 目录或 SwiftData 容器初始化失败时原样向上传递错误。
    static func production(storeURL: URL? = nil) throws -> AccountDataContainer {
        try fileBacked(storeURL: storeURL ?? defaultStoreURL())
    }

    /// 创建基于指定 URL 的文件容器，供生产与持久化集成测试复用。
    static func fileBacked(storeURL: URL) throws -> AccountDataContainer {
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let configuration = ModelConfiguration(
            "FinanceSchemaV3",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return AccountDataContainer(modelContainer: container, storage: .file(storeURL))
    }

    /// 创建显式隔离的内存容器；生产初始化逻辑不会调用该方法作为降级。
    static func inMemory() throws -> AccountDataContainer {
        let configuration = ModelConfiguration(
            "FinanceSchemaV3Preview",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return AccountDataContainer(modelContainer: container, storage: .inMemory)
    }

    /// 生产账户存储的稳定默认位置。
    static func defaultStoreURL(fileManager: FileManager = .default) throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport
            .appending(path: "yadoA", directoryHint: .isDirectory)
            .appending(path: "accounts.store")
    }
}
