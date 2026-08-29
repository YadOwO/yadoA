import SwiftData
import SwiftUI

/// 通过稳定流水 UUID 展示单笔记账的只读详情。
struct BookkeepingTransactionDetailView: View {
    @Environment(\.calendar) private var environmentCalendar
    @Environment(\.locale) private var locale
    @State private var isEditNoticePresented = false
    @Query private var transactions: [AccountTransaction]
    @Query private var accounts: [Account]

    /// 导航栈传入的稳定流水标识。
    let transactionID: UUID

    /// 初始化详情页的全量流水与账户快照查询。
    init(transactionID: UUID) {
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
                        isEditNoticePresented = true
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
        .alert(
            AccountLocalization.string(
                "bookkeeping.search.detail.edit_notice.title",
                locale: locale
            ),
            isPresented: $isEditNoticePresented
        ) {
            Button(
                AccountLocalization.string("common.close", locale: locale),
                role: .cancel
            ) {}
        } message: {
            Text(
                AccountLocalization.string(
                    "bookkeeping.search.detail.edit_notice.message",
                    locale: locale
                )
            )
        }
    }

    /// 展示详情字段和账户生命周期状态。
    @ViewBuilder
    private func detailContent(
        _ presentation: BookkeepingTransactionDetailPresentation
    ) -> some View {
        Form {
            Section {
                LabeledContent(
                    AccountLocalization.string(
                        "bookkeeping.search.detail.category",
                        locale: locale
                    ),
                    value: presentation.categoryTitle
                )
                .accessibilityIdentifier("bookkeeping-detail-category")

                LabeledContent(
                    AccountLocalization.string(
                        "bookkeeping.search.detail.amount",
                        locale: locale
                    ),
                    value: presentation.formattedAmount
                )
                .accessibilityIdentifier("bookkeeping-detail-amount")

                LabeledContent(
                    AccountLocalization.string(
                        "bookkeeping.search.detail.date",
                        locale: locale
                    ),
                    value: presentation.formattedDate
                )
                .accessibilityIdentifier("bookkeeping-detail-date")
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
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bookkeeping-detail-content")
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
