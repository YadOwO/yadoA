import Foundation
import SwiftData

/// 首页、搜索和账户详情共享的流水稳定展示顺序。
enum AccountTransactionOrdering {
    /// 业务日倒序、保存时间倒序、UUID 升序的 SwiftData 排序描述符。
    static var sortDescriptors: [SortDescriptor<AccountTransaction>] {
        [
            SortDescriptor(\AccountTransaction.transactionDay, order: .reverse),
            SortDescriptor(\AccountTransaction.savedAt, order: .reverse),
            SortDescriptor(\AccountTransaction.id, order: .forward)
        ]
    }

    /// 最新业务日优先；同日按保存时间倒序，时间相同时按 UUID 字符串升序。
    nonisolated static func newestFirst(
        _ lhs: AccountTransaction,
        _ rhs: AccountTransaction
    ) -> Bool {
        if lhs.transactionDay != rhs.transactionDay {
            return lhs.transactionDay > rhs.transactionDay
        }
        if lhs.savedAt != rhs.savedAt {
            return lhs.savedAt > rhs.savedAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// 返回符合稳定顺序的元素；输入已有序时原样返回，避免对 SwiftData 有序快照重复排序。
    ///
    /// - Parameters:
    ///   - items: 流水或携带流水的投影元素。
    ///   - transaction: 从元素中取出原始流水的访问器。
    /// - Returns: 按 `newestFirst` 排列的元素。
    static func sorted<T>(
        _ items: [T],
        by transaction: (T) -> AccountTransaction
    ) -> [T] {
        guard items.count > 1 else { return items }
        for index in 1..<items.count
        where newestFirst(transaction(items[index]), transaction(items[index - 1])) {
            return items.sorted { newestFirst(transaction($0), transaction($1)) }
        }
        return items
    }
}
