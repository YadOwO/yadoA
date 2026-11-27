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

    /// 当前本地财务 schema，取迁移计划里的最新版本 `FinanceSchemaV2`（10.0.0）。
    ///
    /// 包含账户、类型化流水、默认账户偏好、收支分类设置、周期记账规则、同步台账、AI 对话记录和订阅。
    /// 出新版本时，改指向最新的 `FinanceSchemaV<n>`。
    static let schema = FinanceSchemaV2.schema

    /// 创建生产环境文件存储，不会在失败时删除、替换或降级现有文件。
    ///
    /// - Parameter storeURL: 可选的显式文件 URL；默认使用 Application Support。
    /// - Returns: 基于文件的账户数据容器。
    /// - Throws: 目录或 SwiftData 容器初始化失败时原样向上传递错误。
    static func production(storeURL: URL? = nil) throws -> AccountDataContainer {
        try fileBacked(storeURL: storeURL ?? defaultStoreURL())
    }

    /// 创建基于指定 URL 的文件容器，供生产与持久化集成测试复用。
    ///
    /// 按 `FinanceMigrationPlan` 打开（需要时迁移）。
    static func fileBacked(storeURL: URL) throws -> AccountDataContainer {
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let configuration = ModelConfiguration(
            "FinanceSchemaV9",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let container = try makeModelContainer(configuration: configuration)
        return AccountDataContainer(modelContainer: container, storage: .file(storeURL))
    }

    /// 创建显式隔离的内存容器；生产初始化逻辑不会调用该方法作为降级。
    ///
    /// 按 `FinanceMigrationPlan` 打开（需要时迁移）。
    static func inMemory() throws -> AccountDataContainer {
        let configuration = ModelConfiguration(
            "FinanceSchemaV9Preview",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try makeModelContainer(configuration: configuration)
        return AccountDataContainer(modelContainer: container, storage: .inMemory)
    }

    /// 按迁移计划创建 SwiftData 容器，文件容器和内存容器统一走这里，保证都带迁移计划。
    ///
    /// - Parameter configuration: 已指定名字、存储位置和 CloudKit 设置的容器配置。
    /// - Returns: 带 `FinanceMigrationPlan` 的 SwiftData 容器。
    /// - Throws: 容器创建或迁移失败时原样抛出，不删库、不降级。
    private static func makeModelContainer(configuration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(
            for: schema,
            migrationPlan: FinanceMigrationPlan.self,
            configurations: [configuration]
        )
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
