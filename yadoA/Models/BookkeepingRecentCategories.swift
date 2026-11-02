import Foundation
import SwiftData

/// 两个收支方向最近一笔流水用的分类，新建记账时据此预选，不用每次都从分类面板选。
///
/// 直接从流水推导、不单独存储：语音记的账、同步下来的账和恢复的备份都算数，换设备也不会丢；
/// 周期记账自动记入的不算，否则每次自动记完房租，下一笔手动记账都会预选房租。
struct BookkeepingRecentCategories: Equatable, Sendable {
    /// 最近一笔支出的分类 key；没有支出或该分类已不可用时为 `nil`。
    let expenseKey: String?

    /// 最近一笔收入的分类 key；没有收入或该分类已不可用时为 `nil`。
    let incomeKey: String?

    /// 从本地数据解析最近使用的分类。
    ///
    /// “最近”按保存时间而不是记账日判断：补记上个月的账也算刚用过这个分类。
    ///
    /// - Parameter context: 用来读取流水和分类的上下文。
    /// - Returns: 两个方向各自最近使用、当前仍可选的分类。
    static func resolve(in context: ModelContext) -> BookkeepingRecentCategories {
        let categories = (try? context.fetch(FetchDescriptor<BookkeepingCategory>())) ?? []
        let catalog = BookkeepingCategoryCatalog(categories: categories)
        return BookkeepingRecentCategories(
            expenseKey: latestKey(type: .expense, direction: .expense, catalog: catalog, in: context),
            incomeKey: latestKey(type: .income, direction: .income, catalog: catalog, in: context)
        )
    }

    /// 读取某类流水最近一笔的分类；分类已不在记账面板里时不预选，让用户重新选择。
    ///
    /// - Parameters:
    ///   - type: 流水类型。
    ///   - direction: 流水类型对应的收支方向。
    ///   - catalog: 判断分类是否可用的分类目录。
    ///   - context: 用来读取流水的上下文。
    /// - Returns: 可以预选的分类 key。
    private static func latestKey(
        type: AccountTransactionType,
        direction: BookkeepingEntryType,
        catalog: BookkeepingCategoryCatalog,
        in context: ModelContext
    ) -> String? {
        let typeRawValue = type.rawValue
        var descriptor = FetchDescriptor<AccountTransaction>(
            predicate: #Predicate<AccountTransaction> { transaction in
                transaction.typeRawValue == typeRawValue && transaction.recurringRuleID == nil
            },
            sortBy: [SortDescriptor(\.savedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let key = (try? context.fetch(descriptor))?.first?.categoryRawValue,
              catalog.items(for: direction).contains(where: { $0.key == key })
        else { return nil }
        return key
    }
}
