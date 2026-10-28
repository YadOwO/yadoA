import Foundation
import SwiftData
import Testing
@testable import yadoA

/// 使用真实 SwiftData 验证语音会话账户工具的执行、错误码与撤销。
@Suite("语音账户工具执行", .serialized)
@MainActor
struct VoiceAccountToolExecutorTests {
    private let locale = Locale(identifier: "zh-Hans")
    private let savedAt = Date(timeIntervalSince1970: 1_792_470_600) // 2026-10-20T04:30:00Z

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test("调整余额：目标余额与增减额都按执行时的余额计算，撤销后余额与流水复原")
    func adjustBalanceAndRevert() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let wallet = try makeAccount(.virtualAccount, templateID: "virtualAccount.wechat", name: "微信", balance: 500, in: container)
        let executor = makeExecutor(container)

        let target = executor.execute(.adjustBalance(id: "c1", input: VoiceAdjustBalanceInput(
            accountId: wallet.uuidString, targetBalance: "480", delta: nil, note: nil
        )))
        let delta = executor.execute(.adjustBalance(id: "c2", input: VoiceAdjustBalanceInput(
            accountId: wallet.uuidString, targetBalance: nil, delta: "-12.5", note: "对账"
        )))

        #expect(target.result.output == .balanceAdjusted(before: "500", after: "480"))
        #expect(delta.result.output == .balanceAdjusted(before: "480", after: "467.5"))
        #expect(try balance(wallet, in: container) == Decimal(string: "467.5"))
        #expect(try transactionCount(in: container) == 2)
        let change = try #require(delta.change?.accountChange)
        #expect(change.title == "微信")
        #expect(change.accountIDs == [wallet])
        #expect(change.summary.contains("467.50"))

        _ = try executor.revert([target.change, delta.change].compactMap { $0 })
        #expect(try balance(wallet, in: container) == 500)
        #expect(try transactionCount(in: container) == 0)
    }

    @Test("撤销调整余额：期间账户被停用时整轮撤销失败，余额、流水与停用状态保持不变")
    func revertAdjustBalanceFailsWhenAccountDeactivated() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let wallet = try makeAccount(.virtualAccount, templateID: "virtualAccount.wechat", name: "微信", balance: 500, in: container)
        let executor = makeExecutor(container)

        let execution = executor.execute(.adjustBalance(id: "c1", input: VoiceAdjustBalanceInput(
            accountId: wallet.uuidString, targetBalance: "0", delta: nil, note: nil
        )))
        #expect(execution.result.output == .balanceAdjusted(before: "500", after: "0"))
        // 余额为 0 后，用户在 App 里停用了这个账户
        let repository = LocalAccountRepository(container: container)
        try repository.dispose(repository.disposalExpectation(for: wallet, action: .deactivate))

        #expect(throws: BalanceAdjustmentRepositoryError.accountDeactivated(wallet)) {
            try executor.revert([execution.change].compactMap { $0 })
        }
        #expect(try balance(wallet, in: container) == 0)
        #expect(try transactionCount(in: container) == 1)
        #expect(try #require(try fetchAccount(wallet, in: container)).isActive == false)
    }

    /// 停用校验失败时，先前已在同一 context 中撤销的收支也必须回滚，不能只撤销半轮。
    @Test("撤销混合改动：余额调整账户已停用时，已撤销的收支一并回滚")
    func revertMixedTurnRollsBackWhenAdjustmentAccountDeactivated() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let wallet = try makeAccount(.virtualAccount, templateID: "virtualAccount.wechat", name: "微信", balance: 500, in: container)
        let cash = try makeAccount(.cash, balance: 100, in: container)
        let repository = LocalAccountRepository(container: container)
        try repository.setDefaultAccount(id: cash)
        let executor = makeExecutor(container)

        let adjusted = executor.execute(.adjustBalance(id: "c1", input: VoiceAdjustBalanceInput(
            accountId: wallet.uuidString, targetBalance: "0", delta: nil, note: "对账"
        )))
        #expect(adjusted.result.output == .balanceAdjusted(before: "500", after: "0"))
        let expense = executor.execute(.createTransaction(id: "c2", input: VoiceCreateTransactionInput(
            type: .expense, amount: "20", accountId: cash.uuidString, categoryId: "dining",
            date: "2026-10-20", note: "午饭", inferredFields: []
        )))
        let expenseChange = try #require(expense.change?.entryChange)
        let changes = [try #require(adjusted.change), try #require(expense.change)]
        let deactivatedAt = savedAt.addingTimeInterval(60)
        try repository.dispose(
            repository.disposalExpectation(for: wallet, action: .deactivate), now: deactivatedAt
        )

        // 倒序撤销会先删除现金支出，再因微信已停用而失败；现金余额与支出流水也应恢复。
        #expect(throws: BalanceAdjustmentRepositoryError.accountDeactivated(wallet)) {
            try executor.revert(changes)
        }
        #expect(try balance(wallet, in: container) == 0)
        #expect(try balance(cash, in: container) == 80)
        #expect(try transactionCount(in: container) == 2)
        #expect(try #require(try fetchAccount(wallet, in: container)).deactivatedAt == deactivatedAt)
        #expect(try defaultAccountID(in: container) == cash)
        let retainedExpense = try fetchTransaction(expenseChange.transactionID, in: container)
        #expect(retainedExpense.amount == 20)
        #expect(retainedExpense.note == "午饭")
    }

    @Test("调整余额：与当前相同或增减额为 0 返回 invalid_input，停用账户返回 not_editable，找不到返回 not_found")
    func adjustBalanceErrors() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let cash = try makeAccount(.cash, balance: 100, in: container)
        let inactive = try makeAccount(.cash, balance: 0, isActive: false, in: container)
        let executor = makeExecutor(container)
        func adjust(_ id: UUID, target: String? = nil, delta: String? = nil) -> VoiceToolOutput {
            executor.execute(.adjustBalance(id: "c", input: VoiceAdjustBalanceInput(
                accountId: id.uuidString, targetBalance: target, delta: delta, note: nil
            ))).result.output
        }

        #expect(adjust(cash, target: "100") == .failure(.invalidInput))
        #expect(adjust(cash, delta: "0") == .failure(.invalidInput))
        #expect(adjust(inactive, target: "10") == .failure(.notEditable))
        #expect(adjust(UUID(), target: "10") == .failure(.notFound))
        #expect(try transactionCount(in: container) == 0)
    }

    @Test("转账：两边都有时记一笔转账；只转入信用卡时只记余额调整、欠款减少；撤销后余额复原")
    func transferAndRevert() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let bank = try makeAccount(.debitCard, templateID: "debitCard.cmb", balance: 3000, in: container)
        let card = try makeAccount(.creditCard, templateID: "creditCard.huabei", balance: 800, in: container)
        let executor = makeExecutor(container)

        let both = executor.execute(.transfer(id: "c1", input: VoiceTransferInput(
            fromAccountId: bank.uuidString, toAccountId: card.uuidString, amount: "300",
            date: "2026-10-20", note: "还花呗", isAmountUncertain: false
        )))
        guard case .created = both.result.output else {
            Issue.record("转账应成功")
            return
        }
        #expect(try balance(bank, in: container) == 2700)
        #expect(try balance(card, in: container) == 500)
        // 点结果行打开转出账户，账户页两边都补笔迹
        #expect(both.change?.accountChange?.accountIDs == [bank, card])

        let oneSided = executor.execute(.transfer(id: "c2", input: VoiceTransferInput(
            fromAccountId: nil, toAccountId: card.uuidString, amount: "100",
            date: "2026-10-19", note: nil, isAmountUncertain: true
        )))
        guard case let .created(idText) = oneSided.result.output, let adjustmentID = UUID(uuidString: idText) else {
            Issue.record("单边转账应成功")
            return
        }
        #expect(try balance(card, in: container) == 400)
        let adjustment = try fetchTransaction(adjustmentID, in: container)
        #expect(try adjustment.validatedPayload() == .balanceAdjustment(before: 500, after: 400, delta: -100))
        #expect(adjustment.transactionDay == 20261019)
        #expect(try #require(oneSided.change?.accountChange?.detail).contains("待确认"))
        #expect(oneSided.change?.accountChange?.accountIDs == [card])

        _ = try executor.revert([both.change, oneSided.change].compactMap { $0 })
        #expect(try balance(bank, in: container) == 3000)
        #expect(try balance(card, in: container) == 800)
        #expect(try transactionCount(in: container) == 0)
    }

    @Test("新建账户：银行卡用机构名称，没说名称时用类型名称，没有默认账户时自动设为默认；撤销后删除并还原默认")
    func createAccountAndRevert() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let executor = makeExecutor(container)

        let bank = executor.execute(.createAccount(id: "c1", input: VoiceCreateAccountInput(
            type: "debitCard", templateId: "debitCard.cmb", name: "工资卡", balance: "3000",
            lastFourDigits: "1234", note: nil, inferredFields: []
        )))
        let custom = executor.execute(.createAccount(id: "c2", input: VoiceCreateAccountInput(
            type: "customAsset", templateId: nil, name: nil, balance: "0",
            lastFourDigits: nil, note: nil, inferredFields: [.type, .balance]
        )))
        guard case let .created(bankText) = bank.result.output, let bankID = UUID(uuidString: bankText),
              case let .created(customText) = custom.result.output, let customID = UUID(uuidString: customText)
        else {
            Issue.record("新建应成功")
            return
        }
        let bankAccount = try #require(try fetchAccount(bankID, in: container))
        let cmbName = AccountType.debitCard.templates.first { $0.id == "debitCard.cmb" }?.name(locale: locale)
        #expect(bankAccount.name == cmbName)
        #expect(bankAccount.lastFourDigits == "1234")
        #expect(bankAccount.balance == 3000)
        #expect(try #require(try fetchAccount(customID, in: container)).name == AccountType.customAsset.title(locale: locale))
        #expect(try defaultAccountID(in: container) == bankID)
        #expect(try #require(custom.change?.accountChange?.detail).contains("待确认"))
        #expect(bank.change?.accountChange?.accountIDs == [bankID])

        _ = try executor.revert([bank.change, custom.change].compactMap { $0 })
        #expect(try accountCount(in: container) == 0)
        #expect(try defaultAccountID(in: container) == nil)
    }

    @Test("撤销新建账户：期间被别处设为默认时整轮撤销失败，账户与默认账户保持不变")
    func revertCreateFailsWhenAccountBecameDefault() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let cash = try makeAccount(.cash, balance: 100, in: container)
        let repository = LocalAccountRepository(container: container)
        try repository.setDefaultAccount(id: cash)
        let executor = makeExecutor(container)

        let created = executor.execute(.createAccount(id: "c1", input: VoiceCreateAccountInput(
            type: "virtualAccount", templateId: "virtualAccount.alipay", name: nil, balance: "0",
            lastFourDigits: nil, note: nil, inferredFields: []
        )))
        guard case let .created(idText) = created.result.output, let alipay = UUID(uuidString: idText),
              case let .account(_, defaultChange)? = created.change?.accountChange?.inverse
        else {
            Issue.record("新建应成功")
            return
        }
        #expect(defaultChange == nil)
        // 另一台设备把新账户设为默认并同步回来
        try repository.setDefaultAccount(id: alipay)

        #expect(throws: AccountRepositoryError.replacementRequired(alipay)) {
            try executor.revert([created.change].compactMap { $0 })
        }
        #expect(try fetchAccount(alipay, in: container) != nil)
        #expect(try defaultAccountID(in: container) == alipay)
    }

    @Test("新建账户：类型不认识或缺少必选模板时返回 invalid_input")
    func createAccountRejectsUnknownTypeOrTemplate() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let executor = makeExecutor(container)
        func create(type: String, templateId: String?) -> VoiceToolOutput {
            executor.execute(.createAccount(id: "c", input: VoiceCreateAccountInput(
                type: type, templateId: templateId, name: nil, balance: "0",
                lastFourDigits: nil, note: nil, inferredFields: []
            ))).result.output
        }

        #expect(create(type: "futureType", templateId: nil) == .failure(.invalidInput))
        #expect(create(type: "debitCard", templateId: nil) == .failure(.invalidInput))
        #expect(try accountCount(in: container) == 0)
    }

    @Test("修改账户：恢复、改名、改备注与设为默认在一次保存中完成；撤销后全部还原")
    func updateAccountAndRevert() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let wallet = try makeAccount(
            .virtualAccount, templateID: "virtualAccount.wechat", name: "微信", balance: 0, isActive: false, in: container
        )
        let executor = makeExecutor(container)

        let execution = executor.execute(.updateAccount(id: "c1", input: VoiceUpdateAccountInput(
            accountId: wallet.uuidString,
            patch: VoiceAccountPatch(name: "零钱", note: .set("日常"), setsDefault: true, isActive: true)
        )))

        #expect(execution.result.output == .succeeded)
        let updated = try #require(try fetchAccount(wallet, in: container))
        #expect(updated.isActive)
        #expect(updated.name == "零钱")
        #expect(updated.note == "日常")
        #expect(try defaultAccountID(in: container) == wallet)
        let change = try #require(execution.change?.accountChange)
        #expect(change.summary.contains("零钱"))
        #expect(change.accountIDs == [wallet])

        _ = try executor.revert([execution.change].compactMap { $0 })
        let reverted = try #require(try fetchAccount(wallet, in: container))
        #expect(!reverted.isActive)
        #expect(reverted.name == "微信")
        #expect(reverted.note == nil)
        #expect(try defaultAccountID(in: container) == nil)
    }

    @Test("修改账户：余额不为 0 不能停用，默认账户不能直接停用，银行卡不能改名，现金不能填卡号，空修改不执行")
    func updateAccountErrors() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let cash = try makeAccount(.cash, balance: 10, in: container)
        let bank = try makeAccount(.debitCard, templateID: "debitCard.cmb", balance: 0, in: container)
        try LocalAccountRepository(container: container).setDefaultAccount(id: bank)
        let executor = makeExecutor(container)
        func update(_ id: UUID, _ patch: VoiceAccountPatch) -> VoiceToolOutput {
            executor.execute(.updateAccount(id: "c", input: VoiceUpdateAccountInput(
                accountId: id.uuidString, patch: patch
            ))).result.output
        }

        #expect(update(cash, VoiceAccountPatch(isActive: false)) == .failure(.balanceNotZero))
        #expect(update(bank, VoiceAccountPatch(isActive: false)) == .failure(.invalidInput))
        #expect(update(bank, VoiceAccountPatch(name: "工资卡")) == .failure(.invalidInput))
        #expect(update(cash, VoiceAccountPatch(lastFourDigits: .set("1234"))) == .failure(.invalidInput))
        #expect(update(cash, VoiceAccountPatch()) == .failure(.invalidInput))
        #expect(update(UUID(), VoiceAccountPatch(isActive: true)) == .failure(.notFound))
        #expect(try #require(try fetchAccount(cash, in: container)).isActive)
        #expect(try #require(try fetchAccount(bank, in: container)).isActive)
        #expect(try defaultAccountID(in: container) == bank)
    }

    @Test("撤销恢复账户：期间往里记了账、余额不为 0 时整轮撤销失败，账户、流水与默认账户保持不变")
    func revertRestoreFailsWhenBalanceChanged() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let wallet = try makeAccount(
            .virtualAccount, templateID: "virtualAccount.wechat", name: "微信", balance: 0, isActive: false, in: container
        )
        let executor = makeExecutor(container)

        let execution = executor.execute(.updateAccount(id: "c1", input: VoiceUpdateAccountInput(
            accountId: wallet.uuidString, patch: VoiceAccountPatch(isActive: true)
        )))
        #expect(try defaultAccountID(in: container) == wallet)
        // 会话还开着时，用户通过「手动记账」往恢复的账户记了一笔
        try LocalExpenseRepository(container: container).save(
            DiningExpenseDraft(accountID: wallet, amountText: "10", transactionDay: 20261020)
        )

        #expect(throws: AccountRepositoryError.nonZeroBalance(wallet)) {
            try executor.revert([execution.change].compactMap { $0 })
        }
        #expect(try #require(try fetchAccount(wallet, in: container)).isActive)
        #expect(try transactionCount(in: container) == 1)
        #expect(try defaultAccountID(in: container) == wallet)
    }

    @Test("新建、转账、调余额的备注超过 30 字时截断后写入")
    func truncatesWrittenNotes() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let cash = try makeAccount(.cash, balance: 100, in: container)
        let wallet = try makeAccount(.virtualAccount, templateID: "virtualAccount.wechat", name: "微信", balance: 50, in: container)
        let executor = makeExecutor(container)
        let note = String(repeating: "备", count: 31)
        let truncated = String(note.prefix(30))

        let created = executor.execute(.createAccount(id: "c1", input: VoiceCreateAccountInput(
            type: "customAsset", templateId: nil, name: "备用金", balance: "0",
            lastFourDigits: nil, note: note, inferredFields: []
        )))
        guard case let .created(idText) = created.result.output, let createdID = UUID(uuidString: idText) else {
            Issue.record("新建应成功")
            return
        }
        #expect(try #require(try fetchAccount(createdID, in: container)).note == truncated)

        let adjusted = executor.execute(.adjustBalance(id: "c2", input: VoiceAdjustBalanceInput(
            accountId: cash.uuidString, targetBalance: "80", delta: nil, note: note
        )))
        guard case .balanceAdjusted = adjusted.result.output else {
            Issue.record("调整余额应成功")
            return
        }
        let transferred = executor.execute(.transfer(id: "c3", input: VoiceTransferInput(
            fromAccountId: cash.uuidString, toAccountId: wallet.uuidString, amount: "10",
            date: "2026-10-20", note: note, isAmountUncertain: false
        )))
        guard case .created = transferred.result.output else {
            Issue.record("转账应成功")
            return
        }
        let notes = try ModelContext(container).fetch(FetchDescriptor<AccountTransaction>()).compactMap(\.note)
        #expect(notes.count == 2)
        #expect(notes.allSatisfy { $0 == truncated })
    }

    @Test("撤销恢复账户：期间被设为默认账户时整轮撤销失败，账户保持启用")
    func revertRestoreFailsWhenAccountBecameDefault() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let cash = try makeAccount(.cash, balance: 100, in: container)
        let wallet = try makeAccount(
            .virtualAccount, templateID: "virtualAccount.wechat", name: "微信", balance: 0, isActive: false, in: container
        )
        let repository = LocalAccountRepository(container: container)
        try repository.setDefaultAccount(id: cash)
        let executor = makeExecutor(container)

        let execution = executor.execute(.updateAccount(id: "c1", input: VoiceUpdateAccountInput(
            accountId: wallet.uuidString, patch: VoiceAccountPatch(isActive: true)
        )))
        try repository.setDefaultAccount(id: wallet)

        #expect(throws: AccountRepositoryError.replacementRequired(wallet)) {
            try executor.revert([execution.change].compactMap { $0 })
        }
        #expect(try #require(try fetchAccount(wallet, in: container)).isActive)
        #expect(try defaultAccountID(in: container) == wallet)
    }

    @Test("撤销账户改动：没换默认账户的不碰默认；换过的只在默认仍是改动后的值时改回")
    func revertKeepsDefaultChosenElsewhere() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let cash = try makeAccount(.cash, balance: 100, in: container)
        let bank = try makeAccount(.debitCard, templateID: "debitCard.cmb", balance: 0, in: container)
        let repository = LocalAccountRepository(container: container)
        try repository.setDefaultAccount(id: cash)
        let executor = makeExecutor(container)

        // 只改备注：不记录默认账户的变化；期间另一台设备把默认改成银行卡，撤销后保留
        let noted = executor.execute(.updateAccount(id: "c1", input: VoiceUpdateAccountInput(
            accountId: cash.uuidString, patch: VoiceAccountPatch(note: .set("零钱"))
        )))
        guard case let .account(_, noteDefaultChange)? = noted.change?.accountChange?.inverse else {
            Issue.record("改备注应记录账户反向变更")
            return
        }
        #expect(noteDefaultChange == nil)
        try repository.setDefaultAccount(id: bank)
        _ = try executor.revert([noted.change].compactMap { $0 })
        #expect(try #require(try fetchAccount(cash, in: container)).note == nil)
        #expect(try defaultAccountID(in: container) == bank)

        // 设为默认：记录银行卡 → 现金；期间默认又被改回银行卡，撤销不覆盖
        let defaulted = executor.execute(.updateAccount(id: "c2", input: VoiceUpdateAccountInput(
            accountId: cash.uuidString, patch: VoiceAccountPatch(setsDefault: true)
        )))
        guard case let .account(_, setDefaultChange)? = defaulted.change?.accountChange?.inverse else {
            Issue.record("设为默认应记录账户反向变更")
            return
        }
        #expect(setDefaultChange == DefaultAccountChange(before: bank, after: cash))
        try repository.setDefaultAccount(id: bank)
        _ = try executor.revert([defaulted.change].compactMap { $0 })
        #expect(try defaultAccountID(in: container) == bank)
    }

    @Test("删除账户：有流水返回 has_transactions；删除后撤销按原样插回")
    func deleteAccountAndRevert() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let cash = try makeAccount(.cash, balance: 100, in: container)
        let spare = try makeAccount(.customAsset, name: "备用金", balance: 50, note: "抽屉里", in: container)
        try LocalExpenseRepository(container: container).save(
            DiningExpenseDraft(accountID: cash, amountText: "10", transactionDay: 20261020)
        )
        let executor = makeExecutor(container)

        let blocked = executor.execute(.deleteAccount(id: "c1", input: VoiceDeleteAccountInput(accountId: cash.uuidString)))
        let deleted = executor.execute(.deleteAccount(id: "c2", input: VoiceDeleteAccountInput(accountId: spare.uuidString)))

        #expect(blocked.result.output == .failure(.hasTransactions))
        #expect(deleted.result.output == .succeeded)
        #expect(try fetchAccount(spare, in: container) == nil)
        // 账户已删除，结果行没有详情可打开
        #expect(deleted.change?.accountChange?.accountIDs == [])

        _ = try executor.revert([deleted.change].compactMap { $0 })
        let restored = try #require(try fetchAccount(spare, in: container))
        #expect(restored.name == "备用金")
        #expect(restored.note == "抽屉里")
        #expect(restored.balance == 50)
        #expect(restored.createdAt == savedAt)
    }

    @Test("同一轮先新建账户、再转入、再记账，撤销时倒序执行，全部还原")
    func revertsMixedTurnInReverseOrder() throws {
        let container = try AccountDataContainer.inMemory().modelContainer
        let cash = try makeAccount(.cash, balance: 1000, in: container)
        let executor = makeExecutor(container)

        let created = executor.execute(.createAccount(id: "c1", input: VoiceCreateAccountInput(
            type: "virtualAccount", templateId: "virtualAccount.alipay", name: nil, balance: "0",
            lastFourDigits: nil, note: nil, inferredFields: []
        )))
        guard case let .created(idText) = created.result.output else {
            Issue.record("新建应成功")
            return
        }
        let transfer = executor.execute(.transfer(id: "c2", input: VoiceTransferInput(
            fromAccountId: cash.uuidString, toAccountId: idText, amount: "200",
            date: "2026-10-20", note: nil, isAmountUncertain: false
        )))
        let expense = executor.execute(.createTransaction(id: "c3", input: VoiceCreateTransactionInput(
            type: .expense, amount: "20", accountId: idText, categoryId: "dining",
            date: "2026-10-20", note: "午饭", inferredFields: []
        )))
        let changes = [created, transfer, expense].compactMap(\.change)
        #expect(changes.count == 3)

        _ = try executor.revert(changes)
        #expect(try accountCount(in: container) == 1)
        #expect(try balance(cash, in: container) == 1000)
        #expect(try transactionCount(in: container) == 0)
    }

    @Test("结果提示先说收支流水，再逐句说明账户改动")
    func summaryIncludesAccountChanges() {
        let entry = VoiceChange.entry(VoiceEntryChange(
            kind: .created, transactionID: UUID(), transactionDay: 20261020, row: nil, accountName: nil, label: "午饭",
            formattedAmount: "¥28.00", inferredFields: [], inverse: .delete(UUID()), highlight: nil
        ))
        let transfer = VoiceChange.account(VoiceAccountChange(
            accountIDs: [UUID(), UUID()], actionText: "转账", title: "招行 → 微信", symbolName: "arrow.left.arrow.right", formattedAmount: "¥500.00",
            detail: nil, summary: "已从招行转 ¥500.00 到微信", inverse: .removeTransfer(UUID())
        ))

        let mixed = VoiceSessionSummary.text(for: [transfer, entry], locale: locale)
        #expect(mixed.hasPrefix("已记 1 笔"))
        #expect(mixed.hasSuffix("已从招行转 ¥500.00 到微信"))
        #expect(VoiceSessionSummary.text(for: [transfer], locale: locale) == "已从招行转 ¥500.00 到微信")
    }

    @Test("本轮改动过的账户：合并各条账户改动涉及的账户，跳过收支与删除的账户，已撤销的轮次为空")
    func turnCollectsChangedAccounts() {
        let bank = UUID()
        let wallet = UUID()
        func accountChange(_ accountIDs: [UUID]) -> VoiceChange {
            .account(VoiceAccountChange(
                accountIDs: accountIDs, actionText: "", title: "", symbolName: "", formattedAmount: nil,
                detail: nil, summary: "", inverse: .removeBalanceAdjustment(UUID())
            ))
        }
        let entry = VoiceChange.entry(VoiceEntryChange(
            kind: .created, transactionID: UUID(), transactionDay: 20261020, row: nil, accountName: nil, label: "午饭",
            formattedAmount: "¥28.00", inferredFields: [], inverse: .delete(UUID()), highlight: nil
        ))
        var turn = VoiceSession.Turn(userText: "从招行转 500 到微信，微信余额改成 800", eventStartIndex: 0)
        turn.changes = [accountChange([bank, wallet]), accountChange([wallet]), accountChange([]), entry]

        #expect(turn.changedAccountIDs == [bank, wallet])

        turn.isUndone = true
        #expect(turn.changedAccountIDs.isEmpty)
    }

    // MARK: - 辅助

    private func makeExecutor(_ container: ModelContainer) -> VoiceToolExecutor {
        VoiceToolExecutor(container: container, locale: locale, calendar: calendar, now: { savedAt })
    }

    private func makeAccount(
        _ type: AccountType,
        templateID: String? = nil,
        name: String? = nil,
        balance: Decimal,
        isActive: Bool = true,
        note: String? = nil,
        in container: ModelContainer
    ) throws -> UUID {
        let account = Account(
            id: UUID(), typeRawValue: type.rawValue, templateID: templateID, name: name ?? type.title(locale: locale),
            note: note, lastFourDigits: nil, balance: balance, currencyCode: "CNY",
            createdAt: savedAt, updatedAt: savedAt, deactivatedAt: isActive ? nil : savedAt
        )
        let context = ModelContext(container)
        context.insert(account)
        try context.save()
        return account.id
    }

    private func fetchAccount(_ id: UUID, in container: ModelContainer) throws -> Account? {
        try ModelContext(container).fetch(FetchDescriptor<Account>()).first { $0.id == id }
    }

    private func balance(_ id: UUID, in container: ModelContainer) throws -> Decimal {
        try #require(try fetchAccount(id, in: container)).balance
    }

    private func fetchTransaction(_ id: UUID, in container: ModelContainer) throws -> AccountTransaction {
        try #require(ModelContext(container).fetch(FetchDescriptor<AccountTransaction>()).first { $0.id == id })
    }

    private func transactionCount(in container: ModelContainer) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<AccountTransaction>())
    }

    private func accountCount(in container: ModelContainer) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<Account>())
    }

    private func defaultAccountID(in container: ModelContainer) throws -> UUID? {
        try ModelContext(container).canonicalBookkeepingPreference()?.defaultAccountID
    }
}

private extension VoiceChange {
    /// 账户相关的改动；收支流水的改动为 `nil`。
    var accountChange: VoiceAccountChange? {
        if case let .account(change) = self { return change }
        return nil
    }
}
