import Foundation
import SwiftData

extension ModelContainer {
    /// 创建一个关闭自动保存的新鲜 context，供单次读写命令独占使用。
    func makeManualSaveContext() -> ModelContext {
        let context = ModelContext(self)
        context.autosaveEnabled = false
        return context
    }
}

/// 各本地仓库共用的定向读取与显式保存边界。
extension ModelContext {
    /// 按稳定 UUID 读取账户。
    func account(id: UUID) throws -> Account? {
        let accountID = id
        var descriptor = FetchDescriptor<Account>(
            predicate: #Predicate<Account> { account in
                account.id == accountID
            }
        )
        descriptor.fetchLimit = 1
        return try fetch(descriptor).first
    }

    /// 按稳定 UUID 读取任意类型的账户流水。
    func transaction(id: UUID) throws -> AccountTransaction? {
        let transactionID = id
        var descriptor = FetchDescriptor<AccountTransaction>(
            predicate: #Predicate<AccountTransaction> { transaction in
                transaction.id == transactionID
            }
        )
        descriptor.fetchLimit = 1
        return try fetch(descriptor).first
    }

    /// 跨全部流水类型判断 UUID 是否已存在，避免实例化无须读取的完整模型。
    func containsTransaction(id: UUID) throws -> Bool {
        let transactionID = id
        let descriptor = FetchDescriptor<AccountTransaction>(
            predicate: #Predicate<AccountTransaction> { transaction in
                transaction.id == transactionID
            }
        )
        return try fetchCount(descriptor) > 0
    }

    /// 读取固定 singleton 记账偏好，忽略非 canonical 的偏好记录。
    func canonicalBookkeepingPreference() throws -> BookkeepingPreference? {
        let singletonID = BookkeepingPreference.singletonID
        var descriptor = FetchDescriptor<BookkeepingPreference>(
            predicate: #Predicate<BookkeepingPreference> { preference in
                preference.id == singletonID
            }
        )
        descriptor.fetchLimit = 1
        return try fetch(descriptor).first
    }

    /// 执行保存前故障点并显式保存；任一步失败都回滚本 context 的全部未保存变更。
    ///
    /// - Parameter beforeSave: 内存修改完成后、显式保存前执行的故障点。
    /// - Throws: 故障点或保存失败时原样抛出错误。
    func saveOrRollback(beforeSave: () throws -> Void = {}) throws {
        do {
            try beforeSave()
            try save()
        } catch {
            rollback()
            throw error
        }
    }
}
