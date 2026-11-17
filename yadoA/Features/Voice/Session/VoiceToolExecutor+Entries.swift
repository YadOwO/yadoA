import Foundation
import SwiftData

extension VoiceToolExecutor {
    // MARK: - 写入

    var repository: LocalExpenseRepository {
        LocalExpenseRepository(container: container, beforeSave: beforeSave)
    }

    var accountRepository: LocalAccountRepository {
        LocalAccountRepository(container: container, beforeSave: beforeSave)
    }

    func create(_ input: VoiceCreateTransactionInput) -> (VoiceToolOutput, VoiceEntryChange?) {
        guard let accountID = UUID(uuidString: input.accountId),
              let amount = Self.amount(from: input.amount),
              let transactionDay = Self.transactionDay(from: input.date)
        else { return (.failure(.invalidInput), nil) }

        let snapshot = BookkeepingEntrySnapshot(
            id: UUID(),
            accountID: accountID,
            entryType: BookkeepingEntryType(input.type),
            categoryKey: input.categoryId,
            amount: amount,
            transactionDay: transactionDay,
            note: input.note.map { String($0.prefix(VoiceSessionLimits.maxWrittenNoteLength)) },
            savedAt: now()
        )
        do {
            try repository.apply([.insert(snapshot)])
        } catch {
            return (.failure(Self.errorCode(for: error)), nil)
        }
        let change = makeChange(
            kind: .created,
            snapshot: snapshot,
            inferredFields: input.inferredFields,
            inverse: .delete(snapshot.id),
            highlight: .added(id: snapshot.id, transactionDay: snapshot.transactionDay)
        )
        return (.created(id: snapshot.id.uuidString), change)
    }

    func update(_ input: VoiceUpdateTransactionInput) -> (VoiceToolOutput, VoiceEntryChange?) {
        let target: EditableTarget
        switch editableTarget(id: input.id) {
        case let .success(found): target = found
        case let .failure(code): return (.failure(code), nil)
        }
        let previous = target.snapshot
        var updated = previous
        let patch = input.patch
        if let type = patch.type {
            updated.entryType = BookkeepingEntryType(type)
        }
        if let categoryKey = patch.categoryId {
            updated.categoryKey = categoryKey
        }
        if let amountText = patch.amount {
            guard let amount = Self.amount(from: amountText) else { return (.failure(.invalidInput), nil) }
            updated.amount = amount
        }
        if let accountText = patch.accountId {
            guard let accountID = UUID(uuidString: accountText) else { return (.failure(.invalidInput), nil) }
            updated.accountID = accountID
        }
        if let date = patch.date {
            guard let transactionDay = Self.transactionDay(from: date) else { return (.failure(.invalidInput), nil) }
            updated.transactionDay = transactionDay
        }
        switch patch.note {
        case let .set(note): updated.note = String(note.prefix(VoiceSessionLimits.maxWrittenNoteLength))
        case .clear: updated.note = nil
        case nil: break
        }

        do {
            try repository.apply([.replace(updated)])
        } catch {
            return (.failure(Self.errorCode(for: error)), nil)
        }
        let change = makeChange(
            kind: .updated,
            snapshot: updated,
            inferredFields: [],
            inverse: .replace(previous),
            highlight: .updated(id: updated.id, transactionDay: updated.transactionDay, previous: target.row)
        )
        return (.succeeded, change)
    }

    func delete(_ input: VoiceDeleteTransactionInput) -> (VoiceToolOutput, VoiceEntryChange?) {
        let target: EditableTarget
        switch editableTarget(id: input.id) {
        case let .success(found): target = found
        case let .failure(code): return (.failure(code), nil)
        }
        do {
            try repository.apply([.delete(target.snapshot.id)])
        } catch {
            return (.failure(Self.errorCode(for: error)), nil)
        }
        let deletedRow = target.deletedRow
        let change = VoiceEntryChange(
            kind: .deleted,
            transactionID: target.snapshot.id,
            transactionDay: target.snapshot.transactionDay,
            row: deletedRow?.row,
            accountName: target.accountName,
            label: label(for: target.snapshot, catalog: target.catalog),
            formattedAmount: formattedAmount(target.snapshot.amount),
            inferredFields: [],
            inverse: .insert(target.snapshot),
            highlight: deletedRow.map(VoiceEntryHighlight.deleted)
        )
        return (.succeeded, change)
    }

    /// 修改、删除前读取到的目标流水。
    private struct EditableTarget {
        /// 修改、删除前的完整快照。
        let snapshot: BookkeepingEntrySnapshot

        /// 修改前的首页行。
        let row: HomeOverviewRowPresentation?

        /// 删除前的首页残影快照。
        let deletedRow: HomeOverviewDeletedRow?

        /// 所属账户名称。
        let accountName: String?

        /// 读取时的分类目录。
        let catalog: BookkeepingCategoryCatalog
    }

    /// 读取要修改或删除的流水，并确认它可以编辑：必须是收支流水，且所属账户仍启用。
    private func editableTarget(id: String) -> Result<EditableTarget, VoiceToolErrorCode> {
        guard let transactionID = UUID(uuidString: id) else { return .failure(.notFound) }
        let context = container.makeManualSaveContext()
        guard let transaction = try? context.transaction(id: transactionID) else { return .failure(.notFound) }
        guard let snapshot = BookkeepingEntrySnapshot(transaction: transaction),
              let account = try? context.account(id: transaction.accountID),
              account.isActive
        else { return .failure(.notEditable) }
        let catalog = Self.catalog(in: context)
        return .success(EditableTarget(
            snapshot: snapshot,
            row: HomeOverviewPresentation.row(for: transaction, locale: locale, calendar: calendar, catalog: catalog),
            deletedRow: HomeOverviewPresentation.deletedRow(
                for: transaction, locale: locale, calendar: calendar, catalog: catalog
            ),
            accountName: account.name,
            catalog: catalog
        ))
    }

    /// 写入成功后重新读取流水，生成结果展示用的变更记录。
    ///
    /// - Parameters:
    ///   - kind: 变更类型。
    ///   - snapshot: 写入后的流水快照。
    ///   - inferredFields: 新增时由 AI 推断的字段。
    ///   - inverse: 撤销本次变更的反向操作。
    ///   - highlight: 首页提示。
    func makeChange(
        kind: VoiceEntryChange.Kind,
        snapshot: BookkeepingEntrySnapshot,
        inferredFields: [VoiceInferredField],
        inverse: BookkeepingEntryMutation,
        highlight: VoiceEntryHighlight
    ) -> VoiceEntryChange {
        let context = container.makeManualSaveContext()
        let catalog = Self.catalog(in: context)
        let transaction = try? context.transaction(id: snapshot.id)
        let row = transaction.flatMap {
            HomeOverviewPresentation.row(for: $0, locale: locale, calendar: calendar, catalog: catalog)
        }
        return VoiceEntryChange(
            kind: kind,
            transactionID: snapshot.id,
            transactionDay: snapshot.transactionDay,
            row: row,
            accountName: (try? context.account(id: snapshot.accountID))?.name,
            label: label(for: snapshot, catalog: catalog),
            formattedAmount: formattedAmount(snapshot.amount),
            inferredFields: inferredFields,
            inverse: inverse,
            highlight: highlight
        )
    }

    /// 结果提示里称呼一笔流水的文字：与列表主行一致，优先备注，没有时用分类名称。
    func label(for snapshot: BookkeepingEntrySnapshot, catalog: BookkeepingCategoryCatalog) -> String {
        BookkeepingEntryLines(
            note: snapshot.note,
            categoryTitle: catalog.resolvedItem(direction: snapshot.entryType, key: snapshot.categoryKey).title(locale: locale)
        ).title
    }

    /// 本地化 CNY 金额；负数（例如透支后的余额）带负号。
    func formattedAmount(_ amount: Decimal) -> String {
        amount.formattedCurrency(locale: locale)
    }
}
