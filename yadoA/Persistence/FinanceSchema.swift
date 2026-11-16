import Foundation
import SwiftData

/// 本地财务库的第一个显式版本，在 1.0 上线前冻结，版本号沿用开发期的 9.0.0。
///
/// 它是当前最新版本，所以 `models` 直接引用顶层模型，不复制成嵌套副本。
/// 以后出 V2 时，要先把那时会改的模型复制成本枚举里的嵌套 `@Model` 类冻结住，再改顶层模型
/// （参见 AGENTS.md「本地数据模型改动」）。
enum FinanceSchemaV1: VersionedSchema {
    /// 版本号，沿用开发期的 9.0.0，开发机上已有的库就是这个版本。
    static let versionIdentifier = Schema.Version(9, 0, 0)

    /// 本版本包含的全部顶层模型：账户、类型化流水、默认账户偏好、收支分类设置、周期记账规则、同步台账和 AI 对话记录。
    static var models: [any PersistentModel.Type] {
        [
            Account.self,
            AccountTransaction.self,
            BookkeepingPreference.self,
            BookkeepingCategory.self,
            RecurringRule.self,
            SyncLedgerEntry.self,
            AIChatTurnRecord.self,
        ]
    }

    /// 本版本的 Schema 实例，供容器配置和迁移测试建旧库使用。
    static var schema: Schema {
        Schema(versionedSchema: Self.self)
    }
}

/// 本地财务库的迁移计划，`AccountDataContainer` 的文件容器和内存容器都按它打开。
///
/// 以后的版本只往 `schemas` 末尾追加，已发布的版本不替换、不删除；
/// 每加一个版本，要在 `stages` 里追加对应的 lightweight 或 custom 步骤。
enum FinanceMigrationPlan: SchemaMigrationPlan {
    /// 按发布顺序排列的全部版本，最后一个是当前最新版本。
    static var schemas: [any VersionedSchema.Type] {
        [FinanceSchemaV1.self]
    }

    /// 相邻版本之间的迁移步骤。
    static var stages: [MigrationStage] {
        // 目前只有 V1 一个版本，暂时没有迁移步骤。
        []
    }
}
