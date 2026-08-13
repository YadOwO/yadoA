import Foundation
import SwiftData
import SwiftUI

/// 与 SwiftUI 渲染解耦的账户详情展示数据。
struct AccountDetailPresentation: Equatable {
    /// 当前展示账户的稳定标识。
    let id: UUID

    /// 当前语言环境下的账户展示名称。
    let name: String

    /// 本地化账户类型。
    let typeTitle: String

    /// 已知模板对应的当前本地化机构名称。
    let institution: String?

    /// 已清理的可选卡号后缀。
    let lastFourDigits: String?

    /// 已清理的可选备注。
    let note: String?

    /// 使用持久货币代码格式化后的金额。
    let formattedAmount: String

    /// 余额、金额或债务的本地化语义标签。
    let amountLabel: String

    /// 同时包含金额语义和值的无障碍播报文本。
    let amountAccessibilityLabel: String

    /// 与列表一致的品牌图片或类型降级图标。
    let icon: AccountIconPresentation
}

/// 账户详情的稳定 UUID 解析与展示转换边界。
enum AccountDetailPresentationFactory {
    /// 在当前持久化查询结果中精确解析 UUID；缺失时不降级到其他账户。
    static func account(id: UUID, in accounts: [Account]) -> Account? {
        accounts.first { $0.id == id }
    }

    /// 复用列表展示结果，确保名称、图标和金额语义保持一致。
    static func detail(for account: Account, locale: Locale = .current) -> AccountDetailPresentation {
        let row = AccountListPresentation.row(for: account, locale: locale)
        let accountType = account.accountType
        let template = AccountListPresentation.template(
            id: account.templateID,
            accountType: accountType
        )

        return AccountDetailPresentation(
            id: account.id,
            name: row.name,
            typeTitle: accountType?.title(locale: locale)
                ?? AccountLocalization.string("account.type.unknown.title", locale: locale),
            institution: template?.name(locale: locale),
            lastFourDigits: account.lastFourDigits,
            note: account.note,
            formattedAmount: row.formattedAmount,
            amountLabel: row.amountLabel,
            amountAccessibilityLabel: row.amountAccessibilityLabel,
            icon: row.icon
        )
    }
}

/// 账户详情外层负责余额调整 Sheet 与查询刷新生命周期。
struct AccountDetailView: View {
    @Environment(\.locale) private var locale
    @Environment(\.modelContext) private var modelContext
    @State private var adjustmentSeed: BalanceAdjustmentSheetSeed?
    @State private var editSeed: AccountEditSheetSeed?
    @State private var queryRefreshToken = UUID()

    /// 导航栈传入的稳定账户标识。
    let accountID: UUID

    var body: some View {
        AccountDetailQueryContent(
            accountID: accountID,
            onAdjustBalance: { accountID, currentBalance in
                adjustmentSeed = BalanceAdjustmentSheetSeed(
                    accountID: accountID,
                    currentBalance: currentBalance
                )
            },
            onEditAccount: { account in
                editSeed = AccountEditSheetSeed(account: account)
            }
        )
        .id(queryRefreshToken)
        .navigationTitle(AccountLocalization.string("account.detail.title", locale: locale))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $adjustmentSeed) { seed in
            NavigationStack {
                BalanceAdjustmentView(
                    accountID: seed.accountID,
                    currentBalance: seed.currentBalance,
                    save: { draft in
                        let repository = LocalBalanceAdjustmentRepository(
                            container: modelContext.container
                        )
                        return try repository.save(draft)
                    },
                    onSaved: {
                        adjustmentSeed = nil
                        queryRefreshToken = UUID()
                    }
                )
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $editSeed) { seed in
            NavigationStack {
                AccountEditView(
                    account: seed.account,
                    save: { draft in
                        let repository = LocalAccountRepository(
                            container: modelContext.container
                        )
                        try repository.update(draft)
                    },
                    onSaved: {
                        editSeed = nil
                        queryRefreshToken = UUID()
                    }
                )
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}

/// 通过独立查询子视图始终从 SwiftData 重新解析账户与其流水。
private struct AccountDetailQueryContent: View {
    @Environment(\.locale) private var locale
    @Query private var accounts: [Account]
    @Query private var transactions: [AccountTransaction]

    /// 当前详情页对应的稳定账户 UUID。
    let accountID: UUID

    /// 点击余额整行时回传原始账户余额，不从格式化文本反解析。
    let onAdjustBalance: (UUID, Decimal) -> Void

    /// 点击详情页编辑入口时回传当前账户模型。
    let onEditAccount: (Account) -> Void

    /// 创建仅查询目标 UUID 的详情内容。
    init(
        accountID: UUID,
        onAdjustBalance: @escaping (UUID, Decimal) -> Void,
        onEditAccount: @escaping (Account) -> Void
    ) {
        let targetAccountID = accountID
        self.accountID = targetAccountID
        self.onAdjustBalance = onAdjustBalance
        self.onEditAccount = onEditAccount
        _accounts = Query(
            filter: #Predicate<Account> { account in
                account.id == targetAccountID
            }
        )
        _transactions = Query(
            AccountTransactionHistoryPresentation.descriptor(accountID: targetAccountID)
        )
    }

    var body: some View {
        Group {
            if let account = AccountDetailPresentationFactory.account(id: accountID, in: accounts) {
                detailContent(
                    account: account,
                    presentation: AccountDetailPresentationFactory.detail(
                        for: account,
                        locale: locale
                    )
                )
            } else {
                unavailableContent
            }
        }
    }

    /// 当前账户的基础信息、可调整余额入口与账户范围内流水。
    private func detailContent(
        account: Account,
        presentation: AccountDetailPresentation
    ) -> some View {
        let historyRows = transactions.compactMap { transaction in
            AccountTransactionHistoryPresentation.row(
                for: transaction,
                locale: locale
            )
        }

        return List {
            Section {
                HStack(spacing: 12) {
                    AccountIconView(presentation: presentation.icon)
                    Text(presentation.name)
                        .font(.headline)
                        .accessibilityIdentifier("account-detail-name")
                }
                .padding(.vertical, 4)
            }

            Section {
                LabeledContent(
                    AccountLocalization.string("account.detail.type", locale: locale),
                    value: presentation.typeTitle
                )
                .accessibilityIdentifier("account-detail-type")

                if let institution = presentation.institution {
                    LabeledContent(
                        AccountLocalization.string("account.detail.institution", locale: locale),
                        value: institution
                    )
                    .accessibilityIdentifier("account-detail-institution")
                }

                if let lastFourDigits = presentation.lastFourDigits {
                    LabeledContent(
                        AccountLocalization.string("account.detail.last_four_digits", locale: locale),
                        value: AccountLocalization.formatted(
                            "account.detail.masked_suffix_format",
                            value: lastFourDigits,
                            locale: locale
                        )
                    )
                    .accessibilityIdentifier("account-detail-last-four-digits")
                }

                if let note = presentation.note {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AccountLocalization.string("account.detail.note", locale: locale))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(note)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("account-detail-note")
                }
            }

            Section {
                Button {
                    onAdjustBalance(account.id, account.balance)
                } label: {
                    HStack(spacing: 12) {
                        Text(presentation.amountLabel)
                        Spacer(minLength: 8)
                        Text(presentation.formattedAmount)
                            .font(.body.monospacedDigit())
                            .accessibilityIdentifier("account-detail-amount")
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(presentation.amountAccessibilityLabel)
                .accessibilityHint(
                    AccountLocalization.string(
                        "account.detail.balance.adjust_action",
                        locale: locale
                    )
                )
                .accessibilityIdentifier("account-detail-adjust-balance")
            }

            Section {
                if historyRows.isEmpty {
                    Text(
                        AccountLocalization.string(
                            "account.detail.history.empty",
                            locale: locale
                        )
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("account-detail-transaction-history-empty")
                } else {
                    ForEach(historyRows) { presentation in
                        AccountTransactionHistoryRow(presentation: presentation)
                    }
                }
            } header: {
                Text(
                    AccountLocalization.string(
                        "account.detail.history.title",
                        locale: locale
                    )
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    onEditAccount(account)
                } label: {
                    Label(
                        AccountLocalization.string("account.detail.edit", locale: locale),
                        systemImage: "pencil"
                    )
                }
                .accessibilityIdentifier("account-detail-edit")
            }
        }
    }

    /// 过期或已不存在 UUID 的安全空状态。
    private var unavailableContent: some View {
        ContentUnavailableView {
            Label(
                AccountLocalization.string("account.detail.unavailable.title", locale: locale),
                systemImage: "questionmark.circle"
            )
        } description: {
            Text(AccountLocalization.string("account.detail.unavailable.message", locale: locale))
        }
        .accessibilityIdentifier("account-detail-unavailable")
    }
}

/// 每次打开余额调整 Sheet 时固定使用的账户与余额快照。
private struct BalanceAdjustmentSheetSeed: Identifiable {
    /// Sheet 实例标识，确保重新打开时创建新草稿 UUID。
    let id = UUID()

    /// 被调整账户的稳定 UUID。
    let accountID: UUID

    /// 打开 Sheet 时用于预填的账户总余额。
    let currentBalance: Decimal
}

/// 每次打开账户资料编辑页时固定使用的账户 UUID 快照。
private struct AccountEditSheetSeed: Identifiable {
    /// 被编辑账户的当前模型对象。
    let account: Account

    /// `sheet(item:)` 所需的稳定标识。
    var id: UUID { account.id }
}

/// 账户详情中的单条类型化流水，支持大字体下自动切换为纵向金额布局。
private struct AccountTransactionHistoryRow: View {
    /// 已完成类型分流、本地化和金额格式化的流水展示数据。
    let presentation: AccountTransactionHistoryRowPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    title
                    Spacer(minLength: 8)
                    amount
                }

                VStack(alignment: .leading, spacing: 4) {
                    title
                    amount
                }
            }

            if let balanceTransition = presentation.balanceTransition {
                Text(balanceTransition)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(presentation.formattedDate)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let note = presentation.note {
                Text(note)
                    .font(.subheadline)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityIdentifier("account-detail-transaction-\(presentation.id.uuidString)")
    }

    /// 餐饮或余额调整标题，不依赖颜色表达流水类型。
    private var title: some View {
        Text(presentation.title)
            .font(.headline)
    }

    /// 已带明确正负方向的本地化 CNY 金额。
    private var amount: some View {
        Text(presentation.formattedAmount)
            .font(.body.monospacedDigit())
    }
}

#Preview("Account unavailable") {
    NavigationStack {
        AccountDetailView(accountID: UUID())
    }
    .modelContainer(
        for: [Account.self, AccountTransaction.self],
        inMemory: true
    )
}
