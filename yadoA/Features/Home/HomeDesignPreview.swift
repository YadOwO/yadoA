#if DEBUG
import SwiftData
import SwiftUI

/// 首页设计专用的内存数据，避免预览读取或改写真实账本。
@MainActor
enum HomeDesignPreviewData {
    /// 创建包含多日收支的隔离容器；空状态保持相同 schema。
    ///
    /// - Parameters:
    ///   - isEmpty: 是否省略示例账户和流水，以检查首次使用状态。
    ///   - locale: 示例账户名称使用的语言环境，分类名称由正式展示层本地化。
    ///   - now: 决定示例数据所在月份的日期，便于截图时固定时间。
    /// - Returns: 只在内存中保存数据的 SwiftData 容器。
    /// - Throws: 容器初始化、示例流水校验或保存失败时抛出错误。
    static func makeContainer(
        isEmpty: Bool = false,
        locale: Locale = Locale(identifier: "zh-Hans"),
        now: Date = .now
    ) throws -> ModelContainer {
        let container = try AccountDataContainer.inMemory().modelContainer
        guard !isEmpty else { return container }

        let calendar = Calendar(identifier: .gregorian)
        guard let month = HomeMonth.from(date: now, calendar: calendar) else {
            return container
        }

        let context = ModelContext(container)
        context.autosaveEnabled = false
        let accountID = UUID()
        context.insert(
            Account(
                id: accountID,
                typeRawValue: AccountType.cash.rawValue,
                templateID: nil,
                name: AccountType.cash.title(locale: locale),
                note: nil,
                lastFourDigits: nil,
                balance: 8_640,
                currencyCode: "CNY",
                createdAt: now,
                updatedAt: now
            )
        )

        // 品牌名称是模拟用户录入的备注；界面分类继续使用原生本地化资源。
        let expenses: [(day: Int, category: ExpenseCategory, amount: Decimal, note: String)] = [
            (28, .dining, 32, "Blue Bottle"),
            (28, .transportation, 6, ""),
            (28, .dining, 86, ""),
            (27, .shopping, 268, "MUJI"),
            (27, .entertainment, 11, "Apple Music"),
            (22, .dailyNecessities, Decimal(768) / 10, "")
        ]

        for (index, expense) in expenses.enumerated() {
            context.insert(
                try AccountTransaction.validatingExpense(
                    id: UUID(),
                    accountID: accountID,
                    category: expense.category,
                    amount: expense.amount,
                    transactionDay: month.year * 10_000 + month.month * 100 + expense.day,
                    note: expense.note,
                    savedAt: now.addingTimeInterval(-Double(index))
                )
            )
        }

        context.insert(
            try AccountTransaction.validatingIncome(
                id: UUID(),
                accountID: accountID,
                category: .salary,
                amount: 12_800,
                transactionDay: month.year * 10_000 + month.month * 100 + 25,
                savedAt: now
            )
        )

        if let previousMonth = month.adding(months: -1, calendar: calendar) {
            context.insert(
                try AccountTransaction.validatingExpense(
                    id: UUID(),
                    accountID: accountID,
                    category: .clothing,
                    amount: 299,
                    transactionDay: previousMonth.year * 10_000 + previousMonth.month * 100 + 18,
                    note: "UNIQLO",
                    savedAt: now
                )
            )
        }

        try context.save()
        return container
    }
}

#Preview("首页 · 中文浅色") {
    let locale = Locale(identifier: "zh-Hans")
    ContentView()
        .modelContainer(try! HomeDesignPreviewData.makeContainer(locale: locale))
        .environment(\.locale, locale)
        .preferredColorScheme(.light)
}

#Preview("首页 · 中文深色") {
    let locale = Locale(identifier: "zh-Hans")
    ContentView()
        .modelContainer(try! HomeDesignPreviewData.makeContainer(locale: locale))
        .environment(\.locale, locale)
        .preferredColorScheme(.dark)
}

#Preview("Home · English · Large Type") {
    let locale = Locale(identifier: "en")
    ContentView()
        .modelContainer(try! HomeDesignPreviewData.makeContainer(locale: locale))
        .environment(\.locale, locale)
        .environment(\.dynamicTypeSize, .accessibility1)
        .preferredColorScheme(.light)
}

#Preview("首页 · 空状态") {
    ContentView()
        .modelContainer(try! HomeDesignPreviewData.makeContainer(isEmpty: true))
        .environment(\.locale, Locale(identifier: "zh-Hans"))
        .preferredColorScheme(.light)
}
#endif
