import Foundation
import SwiftData

extension VoiceToolExecutor {
    // MARK: - 账户

    func adjustBalance(_ input: VoiceAdjustBalanceInput) -> (VoiceToolOutput, VoiceAccountChange?) {
        let context = container.makeManualSaveContext()
        guard let accountID = UUID(uuidString: input.accountId), let account = try? context.account(id: accountID) else {
            return (.failure(.notFound), nil)
        }
        let before = account.balance
        // 契约保证目标余额与增减额恰好一个；增减额加到执行时的余额上，信用卡、负债为欠款的增减
        let target: Decimal? = switch (input.targetBalance, input.delta) {
        case let (targetText?, nil):
            Self.signedAmount(from: targetText)
        case let (nil, deltaText?):
            Self.signedAmount(from: deltaText).flatMap { $0 == 0 ? nil : before.exactlyAdding($0) }
        default:
            nil
        }
        guard let target else { return (.failure(.invalidInput), nil) }

        let id = UUID()
        let after: Decimal
        switch saveBalanceAdjustment(id: id, accountID: accountID, target: target, transactionDay: nil, note: input.note) {
        case let .success(balance): after = balance
        case let .failure(code): return (.failure(code), nil)
        }
        let name = displayName(of: account)
        let change = VoiceAccountChange(
            accountIDs: [accountID],
            actionText: text("voice.account.action.adjustBalance"),
            title: name,
            symbolName: symbolName(of: account),
            formattedAmount: formattedAmount(after),
            detail: AccountLocalization.formatted("voice.account.balanceBefore", value: formattedAmount(before), locale: locale),
            summary: String(
                format: text("voice.summary.balanceAdjusted"), locale: locale,
                name, amountLabel(of: account), formattedAmount(after)
            ),
            inverse: .removeBalanceAdjustment(id)
        )
        return (.balanceAdjusted(before: Self.amountString(before), after: Self.amountString(after)), change)
    }

    func transfer(_ input: VoiceTransferInput) -> (VoiceToolOutput, VoiceAccountChange?) {
        let context = container.makeManualSaveContext()
        /// 读取一边账户：没选时为 `nil`，选了却找不到时失败。
        func side(_ idText: String?) -> Result<Account?, VoiceToolErrorCode> {
            guard let idText else { return .success(nil) }
            guard let id = UUID(uuidString: idText), let account = try? context.account(id: id) else {
                return .failure(.notFound)
            }
            return .success(account)
        }
        let from: Account?
        let to: Account?
        switch (side(input.fromAccountId), side(input.toAccountId)) {
        case let (.success(fromAccount), .success(toAccount)):
            from = fromAccount
            to = toAccount
        case let (.failure(code), _), let (_, .failure(code)):
            return (.failure(code), nil)
        }
        guard let amount = Self.amount(from: input.amount), let transactionDay = Self.transactionDay(from: input.date) else {
            return (.failure(.invalidInput), nil)
        }
        let id = UUID()
        let formattedTransferAmount = formattedAmount(amount)
        let uncertainty = input.isAmountUncertain ? inferredText([text("voice.inferred.amount")]) : nil

        switch (from, to) {
        case let (from?, to?):
            guard from.id != to.id else { return (.failure(.invalidInput), nil) }
            let draft = TransferDraft(
                id: id, fromAccountID: from.id, toAccountID: to.id, amountText: Self.amountString(amount),
                transactionDay: transactionDay, note: Self.writtenNote(input.note)
            )
            do {
                try LocalTransferRepository(container: container, beforeSave: beforeSave).save(draft, savedAt: now())
            } catch {
                return (.failure(Self.errorCode(for: error)), nil)
            }
            let fromName = displayName(of: from)
            let toName = displayName(of: to)
            let change = VoiceAccountChange(
                accountIDs: [from.id, to.id],
                actionText: text("voice.account.action.transfer"),
                title: String(format: text("voice.account.transferTitle"), locale: locale, fromName, toName),
                symbolName: "arrow.left.arrow.right",
                formattedAmount: formattedTransferAmount,
                detail: Self.detail([dateText(transactionDay), uncertainty]),
                summary: String(
                    format: text("voice.summary.transferred"), locale: locale,
                    fromName, formattedTransferAmount, toName
                ),
                inverse: .removeTransfer(id)
            )
            return (.created(id: id.uuidString), change)
        case let (account?, nil), let (nil, account?):
            // 只有一边账户：只给它记一笔余额调整，方向与转账相同，例如只转入信用卡时欠款减少
            let isOutgoing = from != nil
            guard let type = account.accountType,
                  let target = try? LocalExpenseRepository.updatedBalance(
                      account.balance, by: amount,
                      effect: type.expenseBalanceEffect, entryType: isOutgoing ? .expense : .income
                  )
            else { return (.failure(.invalidInput), nil) }
            let after: Decimal
            switch saveBalanceAdjustment(
                id: id, accountID: account.id, target: target, transactionDay: transactionDay, note: input.note
            ) {
            case let .success(balance): after = balance
            case let .failure(code): return (.failure(code), nil)
            }
            let name = displayName(of: account)
            let change = VoiceAccountChange(
                accountIDs: [account.id],
                actionText: text(isOutgoing ? "voice.account.action.transferOut" : "voice.account.action.transferIn"),
                title: name,
                symbolName: symbolName(of: account),
                formattedAmount: formattedTransferAmount,
                detail: Self.detail([
                    AccountLocalization.formatted("voice.account.balanceAfter", value: formattedAmount(after), locale: locale),
                    dateText(transactionDay),
                    uncertainty,
                ]),
                summary: String(
                    format: text(isOutgoing ? "voice.summary.transferredOut" : "voice.summary.transferredIn"),
                    locale: locale, name, formattedTransferAmount
                ),
                inverse: .removeBalanceAdjustment(id)
            )
            return (.created(id: id.uuidString), change)
        case (nil, nil):
            return (.failure(.invalidInput), nil)
        }
    }

    func createAccount(_ input: VoiceCreateAccountInput) -> (VoiceToolOutput, VoiceAccountChange?) {
        guard let type = AccountType(rawValue: input.type), let balance = Self.nonNegativeAmount(from: input.balance) else {
            return (.failure(.invalidInput), nil)
        }
        var template: AccountTemplate?
        if type.requiresTemplateSelection {
            guard let matched = type.templates.first(where: { $0.id == input.templateId }) else {
                return (.failure(.invalidInput), nil)
            }
            template = matched
        }
        // 银行卡、信用卡在 App 里固定显示机构名称，不采用模型给的名称；没有模板的类型用类型名称兜底
        let requestedName = input.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (type.showsEditableName ? requestedName.flatMap { $0.isEmpty ? nil : $0 } : nil)
            ?? template?.name(locale: locale)
            ?? type.title(locale: locale)
        let id = UUID()
        let draft = AccountDraft(
            id: id, accountType: type, template: template, name: name, note: Self.writtenNote(input.note),
            lastFourDigits: type.showsLastFourDigits ? input.lastFourDigits ?? "" : "",
            amountText: Self.amountString(balance), locale: locale
        )
        let defaultBefore = storedDefaultAccountID()
        do {
            // 金额字符串使用英文句点，按 POSIX 解析，不受界面语言的小数分隔符影响
            try accountRepository.save(draft, locale: Self.contractLocale, now: now())
        } catch {
            return (.failure(Self.errorCode(for: error)), nil)
        }
        let inferredNames = input.inferredFields.map { field in
            switch field {
            case .type: text("voice.inferred.accountType")
            case .balance: text("voice.inferred.balance")
            }
        }
        let change = VoiceAccountChange(
            accountIDs: [id],
            actionText: text("voice.account.action.create"),
            title: name,
            symbolName: template?.symbolName ?? type.symbolName,
            formattedAmount: formattedAmount(balance),
            detail: Self.detail([type.title(locale: locale), inferredText(inferredNames)]),
            summary: AccountLocalization.formatted("voice.summary.accountCreated", value: name, locale: locale),
            inverse: .account(.remove(accountID: id), defaultChange: defaultChange(since: defaultBefore))
        )
        return (.created(id: id.uuidString), change)
    }

    func updateAccount(_ input: VoiceUpdateAccountInput) -> (VoiceToolOutput, VoiceAccountChange?) {
        let context = container.makeManualSaveContext()
        guard let id = UUID(uuidString: input.accountId), let account = try? context.account(id: id) else {
            return (.failure(.notFound), nil)
        }
        let patch = input.patch
        var change = AccountChange(
            restores: patch.isActive == true,
            setsDefault: patch.setsDefault,
            deactivates: patch.isActive == false
        )
        if patch.name != nil || patch.note != nil || patch.lastFourDigits != nil {
            var profile = AccountEditDraft(account: account)
            if let name = patch.name {
                // 银行卡、信用卡在 App 里固定显示机构名称，编辑页也不能改名
                guard account.accountType?.showsEditableName ?? true else { return (.failure(.invalidInput), nil) }
                profile.name = name
            }
            switch patch.note {
            case let .set(note): profile.note = String(note.prefix(VoiceSessionLimits.maxWrittenNoteLength))
            case .clear: profile.note = ""
            case nil: break
            }
            if let lastFourDigits = patch.lastFourDigits {
                guard account.accountType?.showsLastFourDigits == true else { return (.failure(.invalidInput), nil) }
                switch lastFourDigits {
                case let .set(digits): profile.lastFourDigits = digits
                case .clear: profile.lastFourDigits = ""
                }
            }
            change.profile = profile
        }
        guard change != AccountChange() else { return (.failure(.invalidInput), nil) }

        let snapshot = AccountSnapshot(account: account)
        let defaultBefore = storedDefaultAccountID()
        do {
            try accountRepository.apply(change, toAccount: id, now: now())
        } catch {
            return (.failure(Self.errorCode(for: error)), nil)
        }
        let name = patch.name.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? displayName(of: account)
        // 按执行顺序逐句说明，例如「已恢复账户：工行卡；已把工行卡设为默认记账账户」
        var sentences: [String] = []
        if change.restores { sentences.append(AccountLocalization.formatted("voice.summary.accountRestored", value: name, locale: locale)) }
        if change.profile != nil { sentences.append(AccountLocalization.formatted("voice.summary.accountUpdated", value: name, locale: locale)) }
        if change.setsDefault { sentences.append(AccountLocalization.formatted("voice.summary.accountSetDefault", value: name, locale: locale)) }
        if change.deactivates { sentences.append(AccountLocalization.formatted("voice.summary.accountDeactivated", value: name, locale: locale)) }
        let actionKey = if change.deactivates {
            "voice.account.action.deactivate"
        } else if change.restores {
            "voice.account.action.restore"
        } else if change.profile == nil {
            "voice.account.action.setDefault"
        } else {
            "voice.change.updated"
        }
        let result = VoiceAccountChange(
            accountIDs: [id],
            actionText: text(actionKey),
            title: name,
            symbolName: symbolName(of: account),
            formattedAmount: nil,
            detail: nil,
            summary: sentences.joined(separator: text("voice.summary.separator")),
            inverse: .account(.restore(snapshot), defaultChange: defaultChange(since: defaultBefore))
        )
        return (.succeeded, result)
    }

    func deleteAccount(_ input: VoiceDeleteAccountInput) -> (VoiceToolOutput, VoiceAccountChange?) {
        let context = container.makeManualSaveContext()
        guard let id = UUID(uuidString: input.accountId), let account = try? context.account(id: id) else {
            return (.failure(.notFound), nil)
        }
        let snapshot = AccountSnapshot(account: account)
        let defaultBefore = storedDefaultAccountID()
        do {
            // 不提交接替账户：要删的是默认账户时仓库会拒绝，服务端也保证不会这样调用
            let repository = accountRepository
            try repository.dispose(repository.disposalExpectation(for: id, action: .delete), now: now())
        } catch {
            return (.failure(Self.errorCode(for: error)), nil)
        }
        let name = displayName(of: account)
        let change = VoiceAccountChange(
            accountIDs: [],
            actionText: text("voice.change.deleted"),
            title: name,
            symbolName: symbolName(of: account),
            formattedAmount: nil,
            detail: nil,
            summary: AccountLocalization.formatted("voice.summary.accountDeleted", value: name, locale: locale),
            inverse: .account(.reinsert(snapshot), defaultChange: defaultChange(since: defaultBefore))
        )
        return (.succeeded, change)
    }

    /// 把账户余额调到目标值，并记一笔余额调整流水。
    ///
    /// - Parameters:
    ///   - id: 新流水的 UUID。
    ///   - accountID: 账户 UUID。
    ///   - target: 调整后的余额；信用卡、负债为欠款。
    ///   - transactionDay: 记账日；为空时取今天。
    ///   - note: 调整原因。
    /// - Returns: 调整后的余额；与当前余额相同时为 `invalid_input`。
    private func saveBalanceAdjustment(
        id: UUID,
        accountID: UUID,
        target: Decimal,
        transactionDay: Int?,
        note: String?
    ) -> Result<Decimal, VoiceToolErrorCode> {
        let draft = BalanceAdjustmentDraft(
            id: id, accountID: accountID, amountText: Self.amountString(target.magnitude),
            sign: target < 0 ? .negative : .positive, note: Self.writtenNote(note)
        )
        do {
            let repository = LocalBalanceAdjustmentRepository(container: container, beforeSave: beforeSave)
            switch try repository.save(draft, now: now(), calendar: calendar, transactionDay: transactionDay) {
            case let .saved(balance): return .success(balance)
            case .unchanged: return .failure(.invalidInput)
            }
        } catch {
            return .failure(Self.errorCode(for: error))
        }
    }

    /// 偏好中记录的默认记账账户，不论是否仍然有效。
    private func storedDefaultAccountID() -> UUID? {
        let context = container.makeManualSaveContext()
        return (try? context.canonicalBookkeepingPreference())?.defaultAccountID
    }

    /// 对比改动前后偏好中记录的默认记账账户；没有变化时为 `nil`，撤销时不碰默认账户。
    func defaultChange(since before: UUID?) -> DefaultAccountChange? {
        let after = storedDefaultAccountID()
        return after == before ? nil : DefaultAccountChange(before: before, after: after)
    }

    /// 写入前把备注截到契约上限。服务端应已截断，这里再防一层。
    static func writtenNote(_ note: String?) -> String {
        String((note ?? "").prefix(VoiceSessionLimits.maxWrittenNoteLength))
    }

    /// 账户在账户页显示的名称：银行卡、信用卡显示机构名称。
    func displayName(of account: Account) -> String {
        guard account.accountType?.showsEditableName == false, let template = template(of: account) else {
            return account.name
        }
        return template.name(locale: locale)
    }

    /// 账户的图标：优先模板图标，其次类型图标。
    func symbolName(of account: Account) -> String {
        template(of: account)?.symbolName ?? account.accountType?.symbolName ?? "questionmark.circle.fill"
    }

    /// 与账户类型匹配的当前模板；模板已不存在时为 `nil`。
    private func template(of account: Account) -> AccountTemplate? {
        AccountListPresentation.template(id: account.templateID, accountType: account.accountType)
    }

    /// 金额的称呼：余额、欠款或金额，随账户类型而定。
    private func amountLabel(of account: Account) -> String {
        account.accountType?.amountLabel(locale: locale) ?? text("account.amount.balance")
    }

    /// 记账日不是今天时的日期文字，例如「9月28日」；今年的只写月日，其他年份带上年份。
    private func dateText(_ transactionDay: Int) -> String? {
        guard transactionDay != today,
              let date = TransactionDay.date(from: transactionDay, calendar: calendar, locale: locale)
        else { return nil }
        let template = transactionDay / 10_000 == today / 10_000 ? "MMMd" : "yMMMd"
        return BookkeepingDateFormatting.formatter(template: template, locale: locale, calendar: calendar).string(from: date)
    }

    /// 待确认字段的说明，例如「待确认：账户类型、余额」；没有时为 `nil`。
    func inferredText(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        let formatter = ListFormatter()
        formatter.locale = locale
        return AccountLocalization.formatted(
            "voice.change.inferred", value: formatter.string(from: names) ?? names.joined(separator: ", "), locale: locale
        )
    }

    /// 当前语言下的文案。
    func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }

    /// 用「 · 」连接非空的说明；全部为空时为 `nil`。
    static func detail(_ parts: [String?]) -> String? {
        let present = parts.compactMap { $0 }
        return present.isEmpty ? nil : present.joined(separator: " · ")
    }
}
