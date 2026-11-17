import Foundation
import SwiftData

extension VoiceToolExecutor {
    // MARK: - 查询

    func search(_ input: VoiceSearchTransactionsInput) -> VoiceToolOutput {
        let context = container.makeManualSaveContext()
        let matches: [BookkeepingEntrySnapshot]
        switch matchingEntries(input.filter, in: context) {
        case let .success(entries): matches = entries
        case let .failure(code): return .failure(code)
        }
        let activeAccountIDs = Self.activeAccountIDs(in: context)
        let items = matches.prefix(max(1, min(input.limit, 20))).map { entry in
            VoiceTransactionItem(
                id: entry.id.uuidString,
                date: Self.dateString(from: entry.transactionDay),
                type: VoiceEntryType(entry.entryType),
                amount: Self.amountString(entry.amount),
                categoryId: entry.categoryKey,
                accountId: entry.accountID.uuidString,
                // 备注常是商家或用途，提供给模型识别「打车那笔」
                note: entry.note.map { String($0.prefix(VoiceSessionLimits.maxResultNoteLength)) },
                isEditable: activeAccountIDs.contains(entry.accountID),
                recurringRuleId: entry.recurringRuleID?.uuidString
            )
        }
        return .searchResult(total: matches.count, items: Array(items))
    }

    func summarize(_ input: VoiceSummarizeTransactionsInput) -> VoiceToolOutput {
        let context = container.makeManualSaveContext()
        let matches: [BookkeepingEntrySnapshot]
        switch matchingEntries(input.filter, in: context) {
        case let .success(entries): matches = entries
        case let .failure(code): return .failure(code)
        }
        var expenseTotal = Decimal.zero
        var incomeTotal = Decimal.zero
        for entry in matches {
            switch entry.entryType {
            case .expense: expenseTotal += entry.amount
            case .income: incomeTotal += entry.amount
            }
        }
        return .summary(
            count: matches.count,
            expenseTotal: Self.amountString(expenseTotal),
            incomeTotal: Self.amountString(incomeTotal)
        )
    }

    /// 今天的收支概况。
    ///
    /// - Returns: 今天的笔数和支出合计；读取失败时按没有记账处理。
    func todaySummary() -> VoiceTodaySummary {
        let todayString = Self.dateString(from: today)
        let context = container.makeManualSaveContext()
        let entries = (try? matchingEntries(VoiceTransactionFilter(dateFrom: todayString, dateTo: todayString), in: context).get()) ?? []
        return VoiceTodaySummary(
            entryCount: entries.count,
            formattedExpense: formattedAmount(Self.total(of: entries, type: .expense))
        )
    }

    /// 按汇总条件在本机算出展示用的结果：合计、分布和与上一期的差额；不请求模型。
    ///
    /// - Parameter filter: 模型给出的汇总条件。
    /// - Returns: 展示内容；条件格式不合法时为 `nil`。
    func queryInsight(for filter: VoiceTransactionFilter) -> AIChatInsight? {
        let context = container.makeManualSaveContext()
        guard let entries = try? matchingEntries(filter, in: context).get() else { return nil }
        // 没指定收支时优先看支出，只有收入时才看收入
        let direction: BookkeepingEntryType = filter.type.map { BookkeepingEntryType($0) }
            ?? (entries.isEmpty || entries.contains { $0.entryType == .expense } ? .expense : .income)
        let total = Self.total(of: entries, type: direction)
        let income = filter.type == nil && direction == .expense ? Self.total(of: entries, type: .income) : 0
        let matched = entries.filter { $0.entryType == direction }
        let requestedFrom = filter.dateFrom.flatMap(Self.transactionDay(from:))
        let requestedTo = filter.dateTo.flatMap(Self.transactionDay(from:))
        let range = AIChatInsightBuilder.clampedRange(
            from: requestedFrom,
            to: requestedTo,
            entryDays: matched.map(\.transactionDay),
            today: today
        )

        var comparison: AIChatInsight.Comparison?
        // 只有明确给了时间范围才有“上一期”，否则全部流水都在这个范围里
        if let requestedFrom, let requestedTo, requestedFrom <= requestedTo, let range,
           let previous = AIChatInsightBuilder.previousRange(
               of: range, requested: requestedFrom...requestedTo, calendar: calendar, locale: locale
           ) {
            var previousFilter = filter
            previousFilter.dateFrom = Self.dateString(from: previous.lowerBound)
            previousFilter.dateTo = Self.dateString(from: previous.upperBound)
            let previousTotal = Self.total(
                of: (try? matchingEntries(previousFilter, in: context).get()) ?? [],
                type: direction
            )
            if previousTotal > 0, previousTotal != total {
                comparison = AIChatInsight.Comparison(
                    isLess: total < previousTotal,
                    formattedDelta: formattedAmount(abs(total - previousTotal))
                )
            }
        }

        var titleParts: [String] = []
        if let range, let rangeText = AIChatInsightBuilder.rangeText(range, calendar: calendar, locale: locale) {
            titleParts.append(rangeText)
        }
        if let categoryKeys = filter.categoryIds, categoryKeys.count == 1 {
            titleParts.append(
                Self.catalog(in: context).resolvedItem(direction: direction, key: categoryKeys[0]).title(locale: locale)
            )
        }
        titleParts.append(String(
            format: text("voice.chat.insight.count"), locale: locale, matched.count
        ))
        return AIChatInsight(
            title: titleParts.joined(separator: " · "),
            formattedTotal: formattedAmount(total),
            formattedIncome: income > 0 ? formattedAmount(income) : nil,
            comparison: comparison,
            buckets: range.map {
                AIChatInsightBuilder.buckets(
                    entries: matched.map { (day: $0.transactionDay, amount: $0.amount) },
                    range: $0,
                    calendar: calendar,
                    locale: locale,
                    format: formattedAmount
                )
            } ?? []
        )
    }

    /// 某个收支方向的合计。
    static func total(of entries: [BookkeepingEntrySnapshot], type: BookkeepingEntryType) -> Decimal {
        entries.filter { $0.entryType == type }.reduce(Decimal.zero) { $0 + $1.amount }
    }

    /// 按条件筛选收支流水，按记账日倒序。
    ///
    /// 条件格式不合法和本地读取失败要分开报给模型：前者让模型改参数重试，后者改参数也没用。
    ///
    /// - Parameters:
    ///   - filter: 模型给出的筛选条件。
    ///   - context: 本次工具调用使用的 context。
    /// - Returns: 命中的流水；条件格式不合法时为 `.invalidInput`，读取失败时为 `.failed`。
    private func matchingEntries(
        _ filter: VoiceTransactionFilter,
        in context: ModelContext
    ) -> Result<[BookkeepingEntrySnapshot], VoiceToolErrorCode> {
        let dayFrom = filter.dateFrom.map(Self.transactionDay(from:))
        let dayTo = filter.dateTo.map(Self.transactionDay(from:))
        let amountMin = filter.amountMin.map(Self.nonNegativeAmount(from:))
        let amountMax = filter.amountMax.map(Self.nonNegativeAmount(from:))
        // 外层 Optional 表示是否给了条件，内层为 nil 表示条件格式不合法
        if dayFrom == .some(nil) || dayTo == .some(nil) || amountMin == .some(nil) || amountMax == .some(nil) {
            return .failure(.invalidInput)
        }
        let lowerDay = dayFrom.flatMap { $0 } ?? Int.min
        let upperDay = dayTo.flatMap { $0 } ?? Int.max
        let accountIDs = filter.accountIds.map { Set($0.compactMap(UUID.init(uuidString:))) }
        let categoryKeys = filter.categoryIds.map(Set.init)
        let entryType = filter.type.map { BookkeepingEntryType($0) }
        let keyword = filter.keyword?.trimmingCharacters(in: .whitespacesAndNewlines)

        var descriptor = FetchDescriptor<AccountTransaction>(
            predicate: #Predicate<AccountTransaction> { transaction in
                transaction.transactionDay >= lowerDay && transaction.transactionDay <= upperDay
            }
        )
        descriptor.sortBy = AccountTransactionOrdering.sortDescriptors
        guard let transactions = try? context.fetch(descriptor) else { return .failure(.failed) }
        let catalog = Self.catalog(in: context)

        return .success(transactions.compactMap(BookkeepingEntrySnapshot.init(transaction:)).filter { entry in
            if let entryType, entry.entryType != entryType { return false }
            if let categoryKeys, !categoryKeys.contains(entry.categoryKey) { return false }
            if let accountIDs, !accountIDs.contains(entry.accountID) { return false }
            if let minimum = amountMin.flatMap({ $0 }), entry.amount < minimum { return false }
            if let maximum = amountMax.flatMap({ $0 }), entry.amount > maximum { return false }
            // 与页面搜索一致：关键词命中备注或分类名称都算，没写备注的流水也能按分类名找到
            if let keyword, !keyword.isEmpty {
                let categoryTitle = catalog.resolvedItem(direction: entry.entryType, key: entry.categoryKey).title(locale: locale)
                guard entry.note?.localizedCaseInsensitiveContains(keyword) == true
                    || categoryTitle.localizedCaseInsensitiveContains(keyword)
                else { return false }
            }
            return true
        })
    }
}
