import Foundation
import SwiftData

extension VoiceToolExecutor {
    // MARK: - 订阅

    /// 订阅仓库，与其他仓库共用保存前故障点。
    private var subscriptionRepository: LocalUserSubscriptionRepository {
        LocalUserSubscriptionRepository(container: container, beforeSave: beforeSave)
    }

    /// 自动记账当场记入用的周期记账仓库。
    private var subscriptionRuleRepository: LocalRecurringRuleRepository {
        LocalRecurringRuleRepository(container: container, beforeSave: beforeSave)
    }

    func searchSubscriptions(_ input: VoiceSearchSubscriptionsInput) -> VoiceToolOutput {
        let context = container.makeManualSaveContext()
        guard let subscriptions = try? context.fetch(FetchDescriptor<UserSubscription>()),
              let rules = try? context.fetch(FetchDescriptor<RecurringRule>())
        else { return .failure(.failed) }
        let today = today
        let existingRuleIDs = Set(rules.map(\.id))
        let filter = input.filter
        let categories = filter.categories.map { Set($0.map(\.rawValue)) }
        let statuses = filter.statuses.map(Set.init)
        let keyword = filter.keyword?.trimmingCharacters(in: .whitespacesAndNewlines)

        // 与订阅列表同样的顺序：订阅中、试用中的按下次扣费从近到远，其次是已取消的，已到期的放最后
        let matched = UserSubscriptionListPresentation.sorted(subscriptions, today: today).filter { subscription in
            if let categories, !categories.contains(subscription.category.rawValue) { return false }
            if let statuses, !statuses.contains(VoiceSubscriptionPhase(subscription.phase(today: today))) { return false }
            if let keyword, !keyword.isEmpty {
                guard subscription.name.localizedCaseInsensitiveContains(keyword)
                    || subscription.note?.localizedCaseInsensitiveContains(keyword) == true
                else { return false }
            }
            return true
        }
        // 合计与订阅页顶部一致：只算订阅中的，年付、季付、周付都折算
        let yearlyTotal = matched.reduce(Decimal.zero) { total, subscription in
            guard subscription.phase(today: today).isCharging, let frequency = subscription.frequency else { return total }
            return total + UserSubscriptionSchedule.yearlyAmount(subscription.amount, frequency: frequency)
        }
        let items = matched.prefix(max(1, min(input.limit, 20))).map { subscription in
            subscriptionItem(for: subscription, today: today, existingRuleIDs: existingRuleIDs)
        }
        return .subscriptionSearchResult(
            total: matched.count,
            monthlyTotal: Self.centsString(yearlyTotal / 12),
            yearlyTotal: Self.centsString(yearlyTotal),
            items: Array(items)
        )
    }

    func createSubscription(_ input: VoiceCreateSubscriptionInput) -> (VoiceToolOutput, [VoiceChange]) {
        let today = today
        let frequency = RecurringFrequency(input.frequency)
        guard UserSubscriptionSchedule.cycles.contains(frequency),
              input.status != .cancelled,
              let amount = Self.amount(from: input.amount, fractionDigits: amountFractionDigits),
              let chargeDay = Self.transactionDay(from: input.nextChargeDate),
              // 与编辑页一致，下次扣费只能是今天及以后
              chargeDay >= today
        else { return (.failure(.invalidInput), []) }

        let category = UserSubscriptionCategory(input.category)
        var bookkeeping: UserSubscriptionBookkeeping?
        if let setting = input.bookkeeping {
            guard let accountID = UUID(uuidString: setting.accountId) else { return (.failure(.invalidInput), []) }
            let catalog = Self.catalog(in: container.makeManualSaveContext())
            bookkeeping = UserSubscriptionBookkeeping(
                accountID: accountID,
                categoryKey: setting.categoryId ?? category.defaultExpenseCategoryKey(in: catalog)
            )
        }

        let id = UUID()
        let ruleID: UUID?
        do {
            ruleID = try subscriptionRepository.save(
                UserSubscriptionInput(
                    id: id,
                    name: String(input.name.prefix(LocalUserSubscriptionRepository.nameLengthLimit)),
                    amount: amount,
                    frequency: frequency,
                    chargeDay: chargeDay,
                    category: category,
                    channel: UserSubscriptionChannel(input.channel),
                    status: UserSubscriptionStatus(input.status),
                    accessEndDay: nil,
                    reminderDaysBefore: input.reminderDaysBefore,
                    note: Self.writtenNote(input.note),
                    bookkeeping: bookkeeping,
                    deletesRuleWhenUnlinking: false
                ),
                today: today,
                now: now()
            )
        } catch {
            return (.failure(Self.errorCode(for: error)), [])
        }
        let inverse = UserSubscriptionRevert(
            subscriptionID: id,
            previous: nil,
            previousRules: ruleID.map { [UserSubscriptionRevert.RuleState(id: $0, snapshot: nil)] } ?? []
        )
        return subscriptionSaved(
            id: id,
            ruleID: ruleID,
            inferredFields: input.inferredFields,
            inverse: inverse
        ) { presentation in
            (
                actionText: text("voice.subscription.action.create"),
                summary: String(
                    format: text("voice.summary.subscriptionCreated"), locale: locale,
                    presentation.name, presentation.frequencyText ?? "", presentation.formattedAmount
                )
            )
        }
    }

    func updateSubscription(_ input: VoiceUpdateSubscriptionInput) -> (VoiceToolOutput, [VoiceChange]) {
        let context = container.makeManualSaveContext()
        guard let id = UUID(uuidString: input.subscriptionId), let subscription = try? context.userSubscription(id: id) else {
            return (.failure(.notFound), [])
        }
        // 状态、周期、分类或扣费渠道来自更新的版本：这一版存不回去，保存会把它们悄悄改掉
        guard let currentStatus = subscription.status,
              let currentFrequency = subscription.frequency,
              !subscription.isFromNewerVersion
        else {
            return (.failure(.notEditable), [])
        }
        let today = today
        let currentRule = try? subscription.recurringRuleID.flatMap { try context.recurringRule(id: $0) }
        guard let change = subscriptionChange(
            from: input.patch,
            subscription: subscription,
            status: currentStatus,
            frequency: currentFrequency,
            currentRule: currentRule,
            catalog: Self.catalog(in: context),
            today: today
        ) else { return (.failure(.invalidInput), []) }

        let repository = subscriptionRepository
        guard let revertPoint = try? repository.revertPoint(
            subscriptionID: id,
            ruleIDs: [subscription.recurringRuleID].compactMap { $0 }
        ) else { return (.failure(.failed), []) }
        let ruleID: UUID?
        do {
            ruleID = try repository.save(change.input, today: today, now: now())
        } catch {
            return (.failure(Self.errorCode(for: error)), [])
        }
        // 这次新建了规则：撤销时一起删掉
        var previousRules = revertPoint.previousRules
        if let ruleID, !previousRules.contains(where: { $0.id == ruleID }) {
            previousRules.append(UserSubscriptionRevert.RuleState(id: ruleID, snapshot: nil))
        }
        let inverse = UserSubscriptionRevert(
            subscriptionID: id,
            previous: revertPoint.previous,
            previousRules: previousRules
        )
        let hadBookkeeping = currentRule != nil
        return subscriptionSaved(id: id, ruleID: ruleID, inferredFields: [], inverse: inverse) { presentation in
            let name = presentation.name
            // 按发生的事逐句说明，例如「已取消订阅：Netflix；已关闭 Netflix 的自动记账」
            var sentences: [String] = []
            let wasCancelled = currentStatus == .cancelled
            let isCancelled = change.input.status == .cancelled
            if isCancelled, !wasCancelled {
                sentences.append(AccountLocalization.formatted("voice.summary.subscriptionCancelled", value: name, locale: locale))
            } else if wasCancelled, !isCancelled {
                sentences.append(AccountLocalization.formatted("voice.summary.subscriptionResumed", value: name, locale: locale))
            }
            if change.changesContent {
                sentences.append(AccountLocalization.formatted("voice.summary.subscriptionUpdated", value: name, locale: locale))
            }
            if ruleID != nil, !hadBookkeeping {
                sentences.append(AccountLocalization.formatted("voice.summary.subscriptionBookkeepingOn", value: name, locale: locale))
            } else if ruleID == nil, hadBookkeeping {
                sentences.append(AccountLocalization.formatted("voice.summary.subscriptionBookkeepingOff", value: name, locale: locale))
            }
            if sentences.isEmpty {
                sentences.append(AccountLocalization.formatted("voice.summary.subscriptionUpdated", value: name, locale: locale))
            }
            let actionKey: String
            if isCancelled, !wasCancelled {
                actionKey = "voice.subscription.action.cancel"
            } else if wasCancelled, !isCancelled {
                actionKey = "voice.recurring.action.resume"
            } else {
                actionKey = "voice.change.updated"
            }
            return (actionText: text(actionKey), summary: sentences.joined(separator: text("voice.summary.separator")))
        }
    }

    func deleteSubscription(_ input: VoiceDeleteSubscriptionInput) -> (VoiceToolOutput, [VoiceChange]) {
        let context = container.makeManualSaveContext()
        guard let id = UUID(uuidString: input.subscriptionId), let subscription = try? context.userSubscription(id: id) else {
            return (.failure(.notFound), [])
        }
        let repository = subscriptionRepository
        let currentRule = try? subscription.recurringRuleID.flatMap { try context.recurringRule(id: $0) }
        guard let inverse = try? repository.revertPoint(
            subscriptionID: id,
            ruleIDs: [subscription.recurringRuleID].compactMap { $0 }
        ) else { return (.failure(.failed), []) }
        let presentation = subscriptionPresentation(of: subscription, hasAutoBookkeeping: currentRule != nil)
        do {
            try repository.delete(id: id, deletesRule: !input.keepsRecurringRule)
        } catch {
            return (.failure(Self.errorCode(for: error)), [])
        }
        let change = VoiceSubscriptionChange(
            subscriptionID: nil,
            actionText: text("voice.change.deleted"),
            title: presentation.name,
            symbolName: presentation.symbolName,
            formattedAmount: presentation.formattedAmount,
            // 打开过自动记账的，已记入的流水不动，行上说清楚
            detail: Self.detail([presentation.frequencyText, currentRule == nil ? nil : text("voice.recurring.entriesKept")]),
            summary: AccountLocalization.formatted(
                currentRule == nil ? "voice.summary.subscriptionDeleted" : "voice.summary.subscriptionDeletedEntriesKept",
                value: presentation.name,
                locale: locale
            ),
            hasReminder: false,
            inverse: inverse
        )
        return (.succeeded, [.subscription(change)])
    }

    // MARK: - 修改内容

    /// 把契约的修改字段并到订阅当前的内容上，得到交给仓库保存的完整提交。
    private struct SubscriptionChange {
        /// 交给仓库保存的完整内容。
        let input: UserSubscriptionInput

        /// 除状态和自动记账开关以外，是否改了别的内容（名称、金额、周期、扣费日、分类、渠道、提醒、备注、记账账户或分类）。
        let changesContent: Bool
    }

    /// 合并修改字段。
    ///
    /// 没给扣费日时沿用编辑页显示的那天，仓库据此保留原来的排期起始日；
    /// 改成已取消、没说能用到哪天时，与编辑页一样取下次扣费的前一天。
    ///
    /// - Returns: 完整提交；金额、日期、提醒天数不合法，周期不是订阅可选的，或已取消的订阅要新打开自动记账时为 `nil`。
    private func subscriptionChange(
        from patch: VoiceSubscriptionPatch,
        subscription: UserSubscription,
        status currentStatus: UserSubscriptionStatus,
        frequency currentFrequency: RecurringFrequency,
        currentRule: RecurringRule?,
        catalog: BookkeepingCategoryCatalog,
        today: Int
    ) -> SubscriptionChange? {
        var changesContent = false

        var amount = subscription.amount
        if let text = patch.amount {
            guard let value = Self.amount(from: text, fractionDigits: amountFractionDigits) else { return nil }
            amount = value
            changesContent = true
        }
        var frequency = currentFrequency
        if let value = patch.frequency {
            frequency = RecurringFrequency(value)
            guard UserSubscriptionSchedule.cycles.contains(frequency) else { return nil }
            changesContent = true
        }
        let status = patch.status.map(UserSubscriptionStatus.init) ?? currentStatus

        var chargeDay = subscription.displayedChargeDay(today: today)
        if let date = patch.nextChargeDate {
            guard let day = Self.transactionDay(from: date), day >= today else { return nil }
            chargeDay = day
            changesContent = true
        }

        var accessEndDay: Int?
        if status == .cancelled {
            if let date = patch.accessEndDate {
                guard let day = Self.transactionDay(from: date) else { return nil }
                accessEndDay = day
            } else if currentStatus == .cancelled {
                accessEndDay = subscription.accessEndDay
            } else {
                accessEndDay = UserSubscriptionSchedule.defaultAccessEndDay(beforeChargeDay: chargeDay, calendar: calendar)
            }
        } else if patch.accessEndDate != nil {
            return nil
        }

        var reminderDaysBefore = subscription.reminderDaysBefore
        switch patch.reminderDaysBefore {
        case let .set(days):
            guard UserSubscriptionReminderOption.validRange.contains(days) else { return nil }
            reminderDaysBefore = days
            changesContent = true
        case .clear:
            reminderDaysBefore = nil
            changesContent = true
        case nil:
            break
        }

        var note = subscription.note ?? ""
        switch patch.note {
        case let .set(text):
            note = Self.writtenNote(text)
            changesContent = true
        case .clear:
            note = ""
            changesContent = true
        case nil:
            break
        }

        let category = patch.category.map(UserSubscriptionCategory.init) ?? subscription.category
        if patch.name != nil || patch.category != nil || patch.channel != nil {
            changesContent = true
        }

        // 自动记账：没提就沿用规则现在的账户和分类，仓库据此让规则跟着订阅改
        var bookkeeping = currentRule.map { UserSubscriptionBookkeeping(accountID: $0.accountID, categoryKey: $0.categoryKey) }
        var deletesRule = false
        switch patch.bookkeeping {
        case .clear:
            bookkeeping = nil
            deletesRule = patch.keepsRecurringRule != true
        case let .set(setting):
            // 与编辑页一致：已取消的订阅不能新打开自动记账
            if currentRule == nil, status == .cancelled { return nil }
            var accountID = bookkeeping?.accountID
            if let text = setting.accountId {
                guard let parsed = UUID(uuidString: text) else { return nil }
                accountID = parsed
            }
            guard let accountID else { return nil }
            let categoryKey = setting.categoryId ?? bookkeeping?.categoryKey ?? category.defaultExpenseCategoryKey(in: catalog)
            if currentRule != nil {
                changesContent = true
            }
            bookkeeping = UserSubscriptionBookkeeping(accountID: accountID, categoryKey: categoryKey)
        case nil:
            break
        }

        return SubscriptionChange(
            input: UserSubscriptionInput(
                id: subscription.id,
                name: patch.name.map { String($0.prefix(LocalUserSubscriptionRepository.nameLengthLimit)) } ?? subscription.name,
                amount: amount,
                frequency: frequency,
                chargeDay: chargeDay,
                category: category,
                channel: patch.channel.map(UserSubscriptionChannel.init) ?? subscription.channel,
                status: status,
                accessEndDay: accessEndDay,
                reminderDaysBefore: reminderDaysBefore,
                note: note,
                bookkeeping: bookkeeping,
                deletesRuleWhenUnlinking: deletesRule
            ),
            changesContent: changesContent
        )
    }

    // MARK: - 结果

    /// 新建或修改成功后重新读取订阅，生成回传结果、订阅的改动记录，以及自动记账当场记入的各期流水的改动记录。
    ///
    /// - Parameters:
    ///   - id: 订阅 UUID。
    ///   - ruleID: 保存后订阅管的规则；不自动记账时为 `nil`。
    ///   - inferredFields: 新建时由 AI 推断的字段。
    ///   - inverse: 撤销订阅改动的反向变更；当场记入的流水各自撤销。
    ///   - describe: 按保存后的订阅生成行首动作和结果提示。
    /// - Returns: 回传结果，以及按「订阅 → 各期流水」排列的改动。
    private func subscriptionSaved(
        id: UUID,
        ruleID: UUID?,
        inferredFields: [VoiceSubscriptionInferredField],
        inverse: UserSubscriptionRevert,
        describe: (SubscriptionPresentation) -> (actionText: String, summary: String)
    ) -> (VoiceToolOutput, [VoiceChange]) {
        let today = today
        // 与编辑页保存后一致：下次扣费是今天的当场记入
        let recorded = ruleID.map { subscriptionRuleRepository.generateDue(ruleID: $0, today: today, now: now()) } ?? []
        let context = container.makeManualSaveContext()
        // 刚保存成功的订阅读不回来只会是存储出错
        guard let subscription = try? context.userSubscription(id: id) else { return (.failure(.failed), []) }

        let presentation = subscriptionPresentation(of: subscription, hasAutoBookkeeping: ruleID != nil)
        let description = describe(presentation)
        let phase = subscription.phase(today: today)
        let subscriptionChange = VoiceSubscriptionChange(
            subscriptionID: id,
            actionText: description.actionText,
            title: presentation.name,
            symbolName: presentation.symbolName,
            formattedAmount: presentation.formattedAmount,
            detail: Self.detail([
                presentation.subtitle,
                ruleID == nil ? nil : text("subscription.row.auto_bookkeeping"),
                inferredText(inferredFields.map { text("voice.inferred.\($0.rawValue)") }),
            ]),
            summary: description.summary,
            hasReminder: subscription.reminderDaysBefore != nil && phase.upcomingChargeDay != nil,
            inverse: inverse
        )
        // 当场记入的各期是普通流水：结果里与手动记的一样可以定位，撤销时逐笔删除
        let entryChanges = recorded.compactMap { generated -> VoiceChange? in
            guard let transaction = try? context.transaction(id: generated.id),
                  let snapshot = BookkeepingEntrySnapshot(transaction: transaction, ledgerCurrencyCode: currencyCode)
            else { return nil }
            return .entry(makeChange(
                kind: .created,
                snapshot: snapshot,
                inferredFields: [],
                inverse: .delete(snapshot.id),
                highlight: .added(id: snapshot.id, transactionDay: snapshot.transactionDay)
            ))
        }
        let output = VoiceToolOutput.subscriptionSaved(
            id: id.uuidString,
            status: VoiceSubscriptionPhase(phase),
            nextChargeDate: phase.upcomingChargeDay.map(Self.dateString(from:)),
            recurringRuleId: ruleID?.uuidString,
            recordedTransactionIds: recorded.map(\.id.uuidString)
        )
        return (output, [.subscription(subscriptionChange)] + entryChanges)
    }

    /// 订阅在结果里的展示内容，按执行时的语言生成。
    private struct SubscriptionPresentation {
        /// 订阅名称。
        let name: String

        /// 分类图标。
        let symbolName: String

        /// 不带正负号的每期金额。
        let formattedAmount: String

        /// 周期名称，例如「每月」；周期不认识时为 `nil`。
        let frequencyText: String?

        /// 与订阅列表副行相同的说明：周期、下次扣费日和扣费渠道，或试用、取消的状态。
        let subtitle: String?
    }

    /// 读取订阅的展示内容。
    private func subscriptionPresentation(of subscription: UserSubscription, hasAutoBookkeeping: Bool) -> SubscriptionPresentation {
        let subtitle = UserSubscriptionListPresentation.subtitle(
            for: subscription,
            phase: subscription.phase(today: today),
            locale: locale,
            calendar: calendar
        )
        return SubscriptionPresentation(
            name: subscription.name,
            symbolName: subscription.category.symbolName,
            formattedAmount: formattedAmount(subscription.amount),
            frequencyText: subscription.frequency.map { text($0.titleKey) },
            subtitle: subtitle.isEmpty ? nil : subtitle
        )
    }

    /// 查询结果中的一条订阅。
    private func subscriptionItem(
        for subscription: UserSubscription,
        today: Int,
        existingRuleIDs: Set<UUID>
    ) -> VoiceSubscriptionItem {
        let phase = subscription.phase(today: today)
        let accessEndDay: Int? = switch phase {
        case .cancelled, .expired: subscription.accessEndDay
        case .active, .trial, .unknown: nil
        }
        return VoiceSubscriptionItem(
            id: subscription.id.uuidString,
            name: String(subscription.name.prefix(LocalUserSubscriptionRepository.nameLengthLimit)),
            amount: Self.amountString(subscription.amount),
            frequency: subscription.frequency.map(VoiceRecurringFrequency.init),
            category: VoiceSubscriptionCategory(subscription.category),
            channel: VoiceSubscriptionChannel(subscription.channel),
            status: VoiceSubscriptionPhase(phase),
            nextChargeDate: phase.upcomingChargeDay.map(Self.dateString(from:)),
            accessEndDate: accessEndDay.map(Self.dateString(from:)),
            // 契约只接受 0～30；同步来的超出范围的值不发
            reminderDaysBefore: subscription.reminderDaysBefore.flatMap {
                UserSubscriptionReminderOption.validRange.contains($0) ? $0 : nil
            },
            note: subscription.note.map { String($0.prefix(VoiceSessionLimits.maxResultNoteLength)) },
            // 规则已被删掉的不算打开了自动记账，与订阅列表一致
            recurringRuleId: subscription.recurringRuleID.flatMap { existingRuleIDs.contains($0) ? $0.uuidString : nil }
        )
    }

    /// 把折算出的金额四舍五入到分，转成契约的十进制字符串。
    private static func centsString(_ amount: Decimal) -> String {
        var value = amount
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .plain)
        return amountString(rounded)
    }
}

extension UserSubscriptionCategory {
    /// 由契约的订阅分类转换。
    init(_ category: VoiceSubscriptionCategory) {
        self = UserSubscriptionCategory(rawValue: category.rawValue) ?? .other
    }
}

extension VoiceSubscriptionCategory {
    /// 由本地订阅分类转换。
    init(_ category: UserSubscriptionCategory) {
        self = VoiceSubscriptionCategory(rawValue: category.rawValue) ?? .other
    }
}

extension UserSubscriptionChannel {
    /// 由契约的扣费渠道转换。
    init(_ channel: VoiceSubscriptionChannel) {
        self = UserSubscriptionChannel(rawValue: channel.rawValue) ?? .other
    }
}

extension VoiceSubscriptionChannel {
    /// 由本地扣费渠道转换。
    init(_ channel: UserSubscriptionChannel) {
        self = VoiceSubscriptionChannel(rawValue: channel.rawValue) ?? .other
    }
}

extension UserSubscriptionStatus {
    /// 由契约的订阅状态转换。
    init(_ status: VoiceSubscriptionStatus) {
        switch status {
        case .active: self = .active
        case .trial: self = .trial
        case .cancelled: self = .cancelled
        }
    }
}

extension VoiceSubscriptionPhase {
    /// 由订阅在今天的实际状态转换。
    init(_ phase: UserSubscriptionPhase) {
        switch phase {
        case .active: self = .active
        case .trial: self = .trial
        case .cancelled: self = .cancelled
        case .expired: self = .expired
        case .unknown: self = .unknown
        }
    }
}
