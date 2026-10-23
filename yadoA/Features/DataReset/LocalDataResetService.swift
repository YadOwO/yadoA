import Foundation
import SwiftData

/// 清除本地业务数据边界产生的错误。
enum LocalDataResetError: Error, Equatable {
    /// 读取或保存失败；现有数据保持原样。
    case resetFailed
}

/// 在主 actor 上一次性清除全部本地业务数据的服务。
///
/// 清除范围为账户、账户流水、默认记账账户偏好、分类设置和同步台账，结果等同于全新安装后的空账本；
/// 分类设置清除后立即补回预置分类的默认值；
/// 语言、外观、金额显隐等显示偏好不属于业务数据，不在清除范围内。
/// 全部删除在单一 context 中一次保存，保存失败时回滚，不会留下只删一半的状态。
/// 不直接删除存储文件，避免正在使用的容器失去底层存储。
@MainActor
final class LocalDataResetService {
    /// 应用或测试持有的完整本地财务容器。
    private let container: ModelContainer

    /// 测试可注入的保存前故障点；生产环境默认为空操作。
    private let beforeSave: () throws -> Void

    /// 创建本地数据清除服务。
    ///
    /// - Parameters:
    ///   - container: 应用或测试持有的完整本地财务容器。
    ///   - beforeSave: 内存删除完成后、显式保存前执行的故障注入点。
    init(
        container: ModelContainer,
        beforeSave: @escaping () throws -> Void = {}
    ) {
        self.container = container
        self.beforeSave = beforeSave
    }

    /// 账本里是否还有可清除的内容（账户或流水）。
    ///
    /// 只剩默认记账账户偏好时视为没有数据：偏好指向的账户已不存在，对用户不可见。
    ///
    /// - Throws: 读取失败时抛出 `LocalDataResetError.resetFailed`。
    func hasData() throws -> Bool {
        let context = container.makeManualSaveContext()
        do {
            return try context.fetchCount(FetchDescriptor<Account>()) > 0
                || context.fetchCount(FetchDescriptor<AccountTransaction>()) > 0
        } catch {
            throw LocalDataResetError.resetFailed
        }
    }

    /// 删除全部账户、流水、记账偏好、分类设置和同步台账，并补回预置分类默认值。
    ///
    /// 台账一并清空、本次删除不登记墓碑：清空是本机行为，是否同时删除云端数据由调用方另行处理。
    ///
    /// - Throws: 读取或保存失败时抛出 `LocalDataResetError.resetFailed`，
    ///   此时本地数据保持清除前的状态。
    func eraseAll() throws {
        let context = container.makeManualSaveContext()
        do {
            try context.fetch(FetchDescriptor<AccountTransaction>()).forEach(context.delete)
            try context.fetch(FetchDescriptor<Account>()).forEach(context.delete)
            try context.fetch(FetchDescriptor<BookkeepingPreference>()).forEach(context.delete)
            try context.fetch(FetchDescriptor<BookkeepingCategory>()).forEach(context.delete)
            try context.fetch(FetchDescriptor<SyncLedgerEntry>()).forEach(context.delete)
            try context.saveOrRollback(tracksSyncChanges: false, beforeSave: beforeSave)
        } catch {
            context.rollback()
            throw LocalDataResetError.resetFailed
        }
        // 预置行与被删的行标识相同，放在独立保存里补回，避免同一次保存里先删后插同一唯一标识。
        try? LocalCategoryRepository(container: container).ensurePresets()
    }
}
