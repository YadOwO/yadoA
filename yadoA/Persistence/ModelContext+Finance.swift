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

    /// 按稳定 UUID 读取用户自己管理的账户；「不关联账户」视为不存在。
    ///
    /// 改名、停用、删除、恢复、调余额这类账户操作用它取账户，让「不关联账户」不会被这些操作改动。
    /// - Parameter id: 账户 UUID。
    /// - Returns: 找到的账户；不存在或是「不关联账户」时为 `nil`。
    func managedAccount(id: UUID) throws -> Account? {
        guard id != Account.unlinkedID else { return nil }
        return try account(id: id)
    }

    /// 读取「不关联账户」，本机还没有时插入一个；不保存，由调用方和这次写入一起保存。
    ///
    /// 同步或导入带来的副本如果被停用过，在这里恢复启用，保证收支始终能记到它上面。
    /// - Parameters:
    ///   - locale: 新建时预填名称使用的语言环境。
    ///   - now: 新建时的创建时间。
    /// - Returns: 当前 context 里的「不关联账户」。
    /// - Throws: 读取失败时抛出。
    func unlinkedAccount(locale: Locale = .current, now: Date = .now) throws -> Account {
        if let existing = try account(id: Account.unlinkedID) {
            if !existing.isActive { existing.deactivatedAt = nil }
            return existing
        }
        let account = Account.makeUnlinked(locale: locale, now: now)
        insert(account)
        return account
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

    /// 登记同步台账、执行保存前故障点并显式保存；任一步失败都回滚本 context 的全部未保存变更。
    ///
    /// 这是所有业务写入唯一的保存入口：同步台账在这里自动登记，与业务修改一起提交或回滚。
    /// 新增写入路径不要直接调用 `save()`，否则修改不会被同步。
    ///
    /// - Parameters:
    ///   - tracksSyncChanges: 是否把本次修改登记到同步台账；应用服务端数据、清空台账时传 `false`。
    ///   - beforeSave: 内存修改完成后、显式保存前执行的故障点。
    /// - Throws: 登记、故障点或保存失败时原样抛出错误。
    func saveOrRollback(
        tracksSyncChanges: Bool = true,
        beforeSave: () throws -> Void = {}
    ) throws {
        var recordedCount = 0
        do {
            if tracksSyncChanges {
                recordedCount = try SyncChangeTracker.recordLocalChanges(in: self)
            }
            try beforeSave()
            try save()
        } catch {
            rollback()
            throw error
        }
        if recordedCount > 0 {
            // 同步引擎监听它，防抖后上传
            NotificationCenter.default.post(name: .syncLedgerDidRecordLocalChanges, object: nil)
        }
    }
}

extension Notification.Name {
    /// 有本地修改被登记到同步台账并已保存。
    static let syncLedgerDidRecordLocalChanges = Notification.Name("yadoA.syncLedgerDidRecordLocalChanges")
}
