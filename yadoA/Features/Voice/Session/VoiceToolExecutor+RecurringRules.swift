import Foundation
import SwiftData

extension VoiceToolExecutor {
    // MARK: - 周期记账

    /// 周期记账仓库，与其他仓库共用保存前故障点。
    private var recurringRepository: LocalRecurringRuleRepository {
        LocalRecurringRuleRepository(container: container, beforeSave: beforeSave)
    }

    /// 今天的 `YYYYMMDD`：新建、修改时下一期不能早于它，到了它的当场记入。
    var today: Int {
        TransactionDay.encode(now(), calendar: calendar)
    }

    func searchRecurringRules(_ input: VoiceSearchRecurringRulesInput) -> VoiceToolOutput {
        let context = container.makeManualSaveContext()
        guard let rules = try? context.fetch(FetchDescriptor<RecurringRule>()),
              let accounts = try? context.fetch(FetchDescriptor<Account>())
        else { return .failure(.failed) }
        let catalog = Self.catalog(in: context)
        let filter = input.filter
        let entryType = filter.type.map { BookkeepingEntryType($0) }
        let categoryKeys = filter.categoryIds.map(Set.init)
        let accountIDs = filter.accountIds.map { Set($0.compactMap(UUID.init(uuidString:))) }
        let statuses = filter.statuses.map(Set.init)
        let keyword = filter.keyword?.trimmingCharacters(in: .whitespacesAndNewlines)

        // 与周期记账列表同样的顺序：正常的按下一期从近到远，其次是暂停的，已结束的放最后
        let sorted = RecurringRuleListPresentation.sorted(rules, accounts: accounts, catalog: catalog)
        let items = sorted.compactMap { rule -> VoiceRecurringRuleItem? in
            guard let item = recurringItem(for: rule, accounts: accounts, catalog: catalog) else { return nil }
            if let entryType, rule.entryType != entryType { return nil }
            if let categoryKeys, !categoryKeys.contains(rule.categoryKey) { return nil }
            if let accountIDs, !accountIDs.contains(rule.accountID) { return nil }
            if let statuses, !statuses.contains(item.status) { return nil }
            // 与流水查询一致：关键词命中备注或分类名称都算
            if let keyword, !keyword.isEmpty, let ruleType = rule.entryType {
                let categoryTitle = catalog.resolvedItem(direction: ruleType, key: rule.categoryKey).title(locale: locale)
                guard rule.note?.localizedCaseInsensitiveContains(keyword) == true
                    || categoryTitle.localizedCaseInsensitiveContains(keyword)
                else { return nil }
            }
            return item
        }
        return .recurringRuleSearchResult(total: items.count, items: Array(items.prefix(max(1, min(input.limit, 20)))))
    }

    func createRecurringRule(_ input: VoiceCreateRecurringRuleInput) -> (VoiceToolOutput, [VoiceChange]) {
        guard let accountID = UUID(uuidString: input.accountId),
              let amount = Self.amount(from: input.amount),
              let nextDueDay = Self.transactionDay(from: input.nextDueDate),
              // 与编辑页一致，下一期只能是今天及以后；补记过去的账由 create_transaction 负责
              nextDueDay >= today,
              let endDay = Self.endDay(from: input.endDate)
        else { return (.failure(.invalidInput), []) }

        let id = UUID()
        let repository = recurringRepository
        do {
            try repository.save(
                RecurringRuleInput(
                    id: id,
                    accountID: accountID,
                    entryType: BookkeepingEntryType(input.type),
                    categoryKey: input.categoryId,
                    amount: amount,
                    note: Self.writtenNote(input.note),
                    frequency: RecurringFrequency(input.frequency),
                    nextDueDay: nextDueDay,
                    endDay: endDay
                ),
                now: now()
            )
        } catch {
            return (.failure(Self.errorCode(for: error)), [])
        }
        // 与编辑页保存后一致：第一期是今天的当场记入
        let recorded = repository.generateDue(ruleID: id, today: today, now: now())
        return recurringSaved(
            ruleID: id,
            recorded: recorded,
            inferredFields: input.inferredFields,
            inverse: .remove(ruleID: id)
        ) { presentation in
            (
                actionText: text("voice.recurring.action.create"),
                summary: String(
                    format: text("voice.summary.recurringCreated"), locale: locale,
                    presentation.label, presentation.frequencyText ?? "", presentation.formattedAmount
                )
            )
        }
    }

    func updateRecurringRule(_ input: VoiceUpdateRecurringRuleInput) -> (VoiceToolOutput, [VoiceChange]) {
        let context = container.makeManualSaveContext()
        guard let id = UUID(uuidString: input.ruleId), let rule = try? context.recurringRule(id: id) else {
            return (.failure(.notFound), [])
        }
        guard let change = Self.recurringRuleChange(from: input.patch, today: today), !change.isEmpty else {
            return (.failure(.invalidInput), [])
        }
        let snapshot = RecurringRuleSnapshot(rule: rule)
        let repository = recurringRepository
        do {
            try repository.update(id: id, change: change, today: today, now: now())
        } catch {
            return (.failure(Self.errorCode(for: error)), [])
        }
        // 下一期改到今天，或恢复后今天正好到期的，当场记入
        let recorded = repository.generateDue(ruleID: id, today: today, now: now())
        return recurringSaved(
            ruleID: id,
            recorded: recorded,
            inferredFields: [],
            inverse: .restore(snapshot)
        ) { presentation in
            let name = presentation.label
            // 按执行顺序逐句说明，例如「已恢复周期记账：房租；已修改周期记账：房租」
            var sentences: [String] = []
            if change.isPaused == false {
                sentences.append(AccountLocalization.formatted("voice.summary.recurringResumed", value: name, locale: locale))
            }
            if change.changesContent {
                sentences.append(AccountLocalization.formatted("voice.summary.recurringUpdated", value: name, locale: locale))
            }
            if change.isPaused == true {
                sentences.append(AccountLocalization.formatted("voice.summary.recurringPaused", value: name, locale: locale))
            }
            let actionKey = switch change.isPaused {
            case true?: "voice.recurring.action.pause"
            case false?: "voice.recurring.action.resume"
            case nil: "voice.change.updated"
            }
            return (actionText: text(actionKey), summary: sentences.joined(separator: text("voice.summary.separator")))
        }
    }

    func deleteRecurringRule(_ input: VoiceDeleteRecurringRuleInput) -> (VoiceToolOutput, VoiceRecurringChange?) {
        let context = container.makeManualSaveContext()
        guard let id = UUID(uuidString: input.ruleId), let rule = try? context.recurringRule(id: id) else {
            return (.failure(.notFound), nil)
        }
        let snapshot = RecurringRuleSnapshot(rule: rule)
        let presentation = recurringPresentation(
            of: rule,
            accounts: (try? context.fetch(FetchDescriptor<Account>())) ?? [],
            catalog: Self.catalog(in: context)
        )
        do {
            try recurringRepository.delete(id: id)
        } catch {
            return (.failure(Self.errorCode(for: error)), nil)
        }
        let change = VoiceRecurringChange(
            ruleID: nil,
            actionText: text("voice.change.deleted"),
            title: presentation.label,
            symbolName: presentation.symbolName,
            formattedAmount: presentation.formattedAmount,
            // 删除规则不动已记入的流水，行上说清楚，免得以为账也一起删了
            detail: Self.detail([presentation.frequencyText, text("voice.recurring.entriesKept")]),
            summary: AccountLocalization.formatted("voice.summary.recurringDeleted", value: presentation.label, locale: locale),
            inverse: .reinsert(snapshot)
        )
        return (.succeeded, change)
    }

    /// 新建或修改成功后重新读取规则，生成回传结果、规则的改动记录，以及当场记入的各期流水的改动记录。
    ///
    /// - Parameters:
    ///   - ruleID: 规则 UUID。
    ///   - recorded: 当场记入的各期流水。
    ///   - inferredFields: 新建时由 AI 推断的字段。
    ///   - inverse: 撤销规则改动的反向变更；当场记入的流水各自撤销。
    ///   - describe: 按保存后的规则生成行首动作和结果提示。
    /// - Returns: 回传结果，以及按「规则 → 各期流水」排列的改动。
    private func recurringSaved(
        ruleID: UUID,
        recorded: [RecurringGeneratedEntry],
        inferredFields: [VoiceInferredField],
        inverse: RecurringRuleRevert,
        describe: (RecurringRulePresentation) -> (actionText: String, summary: String)
    ) -> (VoiceToolOutput, [VoiceChange]) {
        let context = container.makeManualSaveContext()
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        let catalog = Self.catalog(in: context)
        // 刚保存成功的规则读不回来只会是存储出错
        guard let rule = try? context.recurringRule(id: ruleID),
              let item = recurringItem(for: rule, accounts: accounts, catalog: catalog)
        else { return (.failure(.failed), []) }

        let presentation = recurringPresentation(of: rule, accounts: accounts, catalog: catalog)
        let description = describe(presentation)
        let ruleChange = VoiceRecurringChange(
            ruleID: ruleID,
            actionText: description.actionText,
            title: presentation.label,
            symbolName: presentation.symbolName,
            formattedAmount: presentation.formattedAmount,
            detail: recurringDetail(presentation, inferredFields: inferredFields),
            summary: description.summary,
            inverse: inverse
        )
        // 当场记入的各期是普通流水：结果里与手动记的一样可以定位，撤销时逐笔删除
        let entryChanges = recorded.compactMap { generated -> VoiceChange? in
            guard let transaction = try? context.transaction(id: generated.id),
                  let snapshot = BookkeepingEntrySnapshot(transaction: transaction)
            else { return nil }
            return .entry(makeChange(
                kind: .created,
                snapshot: snapshot,
                inferredFields: [],
                inverse: .delete(snapshot.id),
                highlight: .added(id: snapshot.id, transactionDay: snapshot.transactionDay)
            ))
        }
        let output = VoiceToolOutput.recurringRuleSaved(
            id: ruleID.uuidString,
            status: item.status,
            nextDueDate: item.nextDueDate,
            recordedTransactionIds: recorded.map(\.id.uuidString)
        )
        return (output, [.recurring(ruleChange)] + entryChanges)
    }

    /// 规则在结果里的展示内容，按执行时的语言生成。
    private struct RecurringRulePresentation {
        /// 称呼规则的文字：备注，没有备注时为分类名称。
        let label: String

        /// 分类图标。
        let symbolName: String

        /// 不带正负号的每期金额。
        let formattedAmount: String

        /// 频率名称，例如「每月」；频率不认识时为 `nil`。
        let frequencyText: String?

        /// 规则状态。
        let status: RecurringRuleStatus

        /// 下一期的 `YYYYMMDD`。
        let nextDueDay: Int

        /// 记入账户在账户页显示的名称；账户不存在时为 `nil`。
        let accountName: String?
    }

    /// 读取规则的展示内容。
    private func recurringPresentation(
        of rule: RecurringRule,
        accounts: [Account],
        catalog: BookkeepingCategoryCatalog
    ) -> RecurringRulePresentation {
        let category = rule.entryType.map { catalog.resolvedItem(direction: $0, key: rule.categoryKey) }
        return RecurringRulePresentation(
            label: BookkeepingEntryLines(
                note: rule.note,
                categoryTitle: category?.title(locale: locale) ?? text("recurring.title")
            ).title,
            symbolName: category?.symbolName ?? "repeat",
            formattedAmount: formattedAmount(rule.amount),
            frequencyText: rule.frequency.map { text($0.titleKey) },
            status: RecurringRuleListPresentation.status(of: rule, accounts: accounts, catalog: catalog),
            nextDueDay: rule.nextDueDay,
            accountName: accounts.first { $0.id == rule.accountID }.map { displayName(of: $0) }
        )
    }

    /// 规则行的说明：频率、下一期或不会记入的原因、账户和待确认字段，例如「每月 · 下次 12月1日 · 招行」。
    private func recurringDetail(_ presentation: RecurringRulePresentation, inferredFields: [VoiceInferredField]) -> String? {
        let schedule: String? = switch presentation.status {
        case .active:
            TransactionDay.date(from: presentation.nextDueDay, calendar: calendar, locale: locale).map { date in
                AccountLocalization.formatted(
                    "recurring.row.next",
                    value: BookkeepingDateFormatting.shortDate(date, locale: locale, calendar: calendar),
                    locale: locale
                )
            }
        case .paused: text("recurring.status.paused")
        case .finished: text("recurring.status.finished")
        case .unavailable: text("recurring.status.unavailable")
        }
        return Self.detail([
            presentation.frequencyText,
            schedule,
            presentation.accountName,
            inferredText(inferredFields.map { text("voice.inferred.\($0.rawValue)") }),
        ])
    }

    /// 查询结果中的一条规则；方向或频率不认识的规则来自更新的版本，这一版既不能展示也不能修改，返回 `nil`。
    private func recurringItem(
        for rule: RecurringRule,
        accounts: [Account],
        catalog: BookkeepingCategoryCatalog
    ) -> VoiceRecurringRuleItem? {
        guard let entryType = rule.entryType, let frequency = rule.frequency else { return nil }
        return VoiceRecurringRuleItem(
            id: rule.id.uuidString,
            type: VoiceEntryType(entryType),
            amount: Self.amountString(rule.amount),
            categoryId: rule.categoryKey,
            accountId: rule.accountID.uuidString,
            note: rule.note.map { String($0.prefix(VoiceSessionLimits.maxResultNoteLength)) },
            frequency: VoiceRecurringFrequency(frequency),
            nextDueDate: Self.dateString(from: rule.nextDueDay),
            endDate: rule.endDay.map { Self.dateString(from: $0) },
            status: VoiceRecurringRuleStatus(
                RecurringRuleListPresentation.status(of: rule, accounts: accounts, catalog: catalog)
            )
        )
    }

    /// 把契约的修改字段转为仓库的修改内容。
    ///
    /// - Parameters:
    ///   - patch: 契约的修改字段。
    ///   - today: 今天的 `YYYYMMDD`。
    /// - Returns: 修改内容；金额、账户、日期格式不对，或下一期早于今天时为 `nil`。
    private static func recurringRuleChange(from patch: VoiceRecurringRulePatch, today: Int) -> RecurringRuleChange? {
        var change = RecurringRuleChange()
        change.entryType = patch.type.map { BookkeepingEntryType($0) }
        change.categoryKey = patch.categoryId
        if let amountText = patch.amount {
            guard let amount = Self.amount(from: amountText) else { return nil }
            change.amount = amount
        }
        if let accountText = patch.accountId {
            guard let accountID = UUID(uuidString: accountText) else { return nil }
            change.accountID = accountID
        }
        switch patch.note {
        case let .set(note): change.note = .set(String(note.prefix(VoiceSessionLimits.maxWrittenNoteLength)))
        case .clear: change.note = .clear
        case nil: break
        }
        change.frequency = patch.frequency.map { RecurringFrequency($0) }
        if let date = patch.nextDueDate {
            guard let day = Self.transactionDay(from: date), day >= today else { return nil }
            change.nextDueDay = day
        }
        switch patch.endDate {
        case let .set(date):
            guard let day = Self.transactionDay(from: date) else { return nil }
            change.endDay = .set(day)
        case .clear:
            change.endDay = .clear
        case nil:
            break
        }
        change.isPaused = patch.isPaused
        return change
    }

    /// 解析新建时可空的结束日期。
    ///
    /// - Parameter date: 契约的 `YYYY-MM-DD`；`nil` 表示一直重复。
    /// - Returns: 外层为 `nil` 表示格式不对；内层为 `nil` 表示一直重复。
    private static func endDay(from date: String?) -> Int?? {
        guard let date else { return .some(nil) }
        return Self.transactionDay(from: date).map { .some($0) }
    }
}
