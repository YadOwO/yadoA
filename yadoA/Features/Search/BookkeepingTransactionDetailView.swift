import SwiftData
import SwiftUI

/// 统一收支详情外层：管理编辑、删除和保存后的查询刷新。
struct BookkeepingTransactionDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var editDraft: DiningExpenseEditDraft?
    @State private var deletionSelection: BookkeepingTransactionDetailPresentation?
    @State private var isDeleteConfirmationPresented = false
    @State private var isDeleteFailed = false
    @State private var queryRefreshToken = UUID()

    /// 各导航入口共同传入的稳定流水标识。
    let transactionID: UUID

    var body: some View {
        BookkeepingTransactionDetailQueryContent(
            transactionID: transactionID,
            onEdit: { editDraft = $0 },
            onDelete: {
                deletionSelection = $0
                isDeleteConfirmationPresented = true
            }
        )
        .id(queryRefreshToken)
        .sheet(item: $editDraft) { draft in
            NavigationStack {
                DiningExpenseQuickEditView(draft: draft) { updatedDraft in
                    try LocalExpenseRepository(container: modelContext.container).update(updatedDraft)
                    queryRefreshToken = UUID()
                }
            }
        }
        .alert(
            text("bookkeeping.delete.title"),
            isPresented: $isDeleteConfirmationPresented,
            presenting: deletionSelection
        ) { selection in
            Button(text("bookkeeping.delete.action"), role: .destructive) {
                deleteTransaction(id: selection.id)
            }
            Button(text("common.cancel"), role: .cancel) {}
        } message: { selection in
            Text(String(
                format: text("bookkeeping.delete.message"),
                locale: locale,
                selection.title,
                selection.formattedAmount,
                selection.accountName ?? ""
            ))
        }
        .alert(text("bookkeeping.delete.failed"), isPresented: $isDeleteFailed) {
            Button(text("common.close"), role: .cancel) {}
        }
    }

    /// 只有持久化成功才离开详情；失败保留当前页面和可重试入口。
    private func deleteTransaction(id: UUID) {
        do {
            try LocalExpenseRepository(container: modelContext.container).delete(id: id)
            dismiss()
        } catch {
            queryRefreshToken = UUID()
            isDeleteFailed = true
        }
    }

    /// 按当前应用语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 查询稳定流水 UUID，向所有入口提供相同的查看和纠错操作。
private struct BookkeepingTransactionDetailQueryContent: View {
    @Environment(\.calendar) private var environmentCalendar
    @Environment(\.locale) private var locale
    @Query private var transactions: [AccountTransaction]
    @Query private var accounts: [Account]

    /// 导航栈传入的稳定流水标识。
    let transactionID: UUID

    /// 由外层协调编辑 Sheet 与删除确认。
    let onEdit: (DiningExpenseEditDraft) -> Void
    let onDelete: (BookkeepingTransactionDetailPresentation) -> Void

    /// 初始化详情页的全量流水与账户快照查询。
    init(
        transactionID: UUID,
        onEdit: @escaping (DiningExpenseEditDraft) -> Void,
        onDelete: @escaping (BookkeepingTransactionDetailPresentation) -> Void
    ) {
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.transactionID = transactionID
        _transactions = Query(
            BookkeepingSearchPresentation.descriptor(transactionID: transactionID)
        )
        _accounts = Query(BookkeepingSearchPresentation.accountDescriptor())
    }

    var body: some View {
        let presentation = BookkeepingSearchPresentation.detail(
            transactionID: transactionID,
            transactions: transactions,
            accounts: accounts,
            calendar: environmentCalendar,
            locale: locale
        )

        Group {
            if let presentation {
                detailContent(presentation)
            } else {
                unavailableContent
            }
        }
        .navigationTitle(
            AccountLocalization.string(
                "bookkeeping.search.detail.title",
                locale: locale
            )
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let presentation, presentation.canEdit {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if let transaction = transactions.first(where: { $0.id == transactionID }),
                           let draft = DiningExpenseEditDraft(transaction: transaction, locale: locale) {
                            onEdit(draft)
                        }
                    } label: {
                        Text(
                            AccountLocalization.string(
                                "bookkeeping.search.detail.edit",
                                locale: locale
                            )
                        )
                    }
                    .accessibilityIdentifier("bookkeeping-detail-edit")
                }
            }
        }
    }

    /// 先展示收据摘要，再按分组提供分类、账户状态与备注。
    @ViewBuilder
    private func detailContent(
        _ presentation: BookkeepingTransactionDetailPresentation
    ) -> some View {
        List {
            Section {
                transactionSummary(presentation)
                    .listRowInsets(EdgeInsets(top: 24, leading: 20, bottom: 24, trailing: 20))
            }

            Section {
                LabeledContent(
                    AccountLocalization.string("bookkeeping.entry.type", locale: locale),
                    value: presentation.entryType.localizedTitle(locale: locale)
                )
                .accessibilityIdentifier("bookkeeping-detail-type")

                LabeledContent(
                    AccountLocalization.string(
                        "bookkeeping.search.detail.category",
                        locale: locale
                    ),
                    value: presentation.categoryTitle
                )
                .accessibilityIdentifier("bookkeeping-detail-category")
            }

            Section {
                LabeledContent(
                    AccountLocalization.string(
                        "bookkeeping.search.detail.account",
                        locale: locale
                    ),
                    value: presentation.accountName ?? accountStatusText(
                        presentation.accountState
                    )
                )
                .accessibilityIdentifier("bookkeeping-detail-account")

                LabeledContent(
                    AccountLocalization.string(
                        "bookkeeping.search.detail.account_status",
                        locale: locale
                    ),
                    value: accountStatusText(presentation.accountState)
                )
                .accessibilityIdentifier("bookkeeping-detail-account-status")
            }

            if let note = presentation.note {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(
                            AccountLocalization.string(
                                "account.detail.note",
                                locale: locale
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Text(note)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("bookkeeping-detail-note")
                }
            }
            if presentation.canEdit {
                Section {
                    Button(role: .destructive) {
                        onDelete(presentation)
                    } label: {
                        Label(AccountLocalization.string("bookkeeping.delete.action", locale: locale), systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                    .accessibilityIdentifier("bookkeeping-detail-delete")
                }
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bookkeeping-detail-content")
    }

    /// 收据式摘要突出交易名称和带收支方向的金额，同时保留字段语义供辅助功能读取。
    private func transactionSummary(
        _ presentation: BookkeepingTransactionDetailPresentation
    ) -> some View {
        VStack(spacing: 16) {
            Image(systemName: presentation.categorySymbolName)
                .font(.title2.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 60, height: 60)
                .background(Color.accentColor.opacity(0.1), in: .rect(cornerRadius: 18))
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(presentation.title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text(
                        "\(AccountLocalization.string("expense.edit.title.field", locale: locale)), \(presentation.title)"
                    ))
                    .accessibilityIdentifier("bookkeeping-detail-title")

                Text(presentation.formattedAmount)
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .accessibilityLabel(Text(
                        "\(AccountLocalization.string("bookkeeping.search.detail.amount", locale: locale)), \(presentation.formattedAmount)"
                    ))
                    .accessibilityIdentifier("bookkeeping-detail-amount")

                Text(presentation.formattedDate)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text(
                        "\(AccountLocalization.string("bookkeeping.search.detail.date", locale: locale)), \(presentation.formattedDate)"
                    ))
                    .accessibilityIdentifier("bookkeeping-detail-date")
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    /// 流水缺失、失效或损坏时的安全降级状态。
    private var unavailableContent: some View {
        ContentUnavailableView {
            Label(
                AccountLocalization.string(
                    "bookkeeping.search.detail.unavailable.title",
                    locale: locale
                ),
                systemImage: "doc.text.magnifyingglass"
            )
        } description: {
            Text(
                AccountLocalization.string(
                    "bookkeeping.search.detail.unavailable.message",
                    locale: locale
                )
            )
        }
        .accessibilityIdentifier("bookkeeping-detail-unavailable")
    }

    /// 生成账户生命周期状态的本地化标题。
    private func accountStatusText(
        _ state: BookkeepingTransactionAccountState
    ) -> String {
        state.localizedTitle(locale: locale)
    }
}

#if DEBUG
#Preview("Transaction receipt · populated") {
    if let container = try? HomeDesignPreviewData.makeContainer(),
       let transactions = try? container.mainContext.fetch(FetchDescriptor<AccountTransaction>()),
       let transaction = transactions.first {
        NavigationStack {
            BookkeepingTransactionDetailView(transactionID: transaction.id)
        }
        .modelContainer(container)
        .environment(\.locale, Locale(identifier: "zh-Hans"))
    }
}
#endif
