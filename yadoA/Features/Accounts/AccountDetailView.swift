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

/// 从当前 SwiftData 状态解析稳定 UUID 并展示基础账户详情。
struct AccountDetailView: View {
    @Environment(\.locale) private var locale
    @Query private var accounts: [Account]
    @Query private var transactions: [ExpenseTransaction]

    /// 导航栈传入的稳定账户标识。
    let accountID: UUID

    /// 创建仅查询目标 UUID 的详情页，避免持有导航发生时的模型快照。
    init(accountID: UUID) {
        let targetAccountID = accountID
        self.accountID = targetAccountID
        _accounts = Query(
            filter: #Predicate<Account> { account in
                account.id == targetAccountID
            }
        )
        _transactions = Query(
            ExpenseHistoryPresentation.descriptor(accountID: targetAccountID)
        )
    }

    var body: some View {
        Group {
            if let account = AccountDetailPresentationFactory.account(id: accountID, in: accounts) {
                detailContent(
                    AccountDetailPresentationFactory.detail(for: account, locale: locale)
                )
            } else {
                unavailableContent
            }
        }
        .navigationTitle(AccountLocalization.string("account.detail.title", locale: locale))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 当前账户的只读基础信息与账户范围内流水，不提供新增操作入口。
    private func detailContent(_ presentation: AccountDetailPresentation) -> some View {
        List {
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
                LabeledContent(presentation.amountLabel) {
                    Text(presentation.formattedAmount)
                        .font(.body.monospacedDigit())
                        .accessibilityIdentifier("account-detail-amount")
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(presentation.amountAccessibilityLabel)
            }

            Section {
                if transactions.isEmpty {
                    Text(
                        AccountLocalization.string(
                            "account.detail.history.empty",
                            locale: locale
                        )
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("account-detail-expense-history-empty")
                } else {
                    ForEach(transactions, id: \.id) { transaction in
                        ExpenseHistoryRow(
                            presentation: ExpenseHistoryPresentation.row(
                                for: transaction,
                                locale: locale
                            )
                        )
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

/// 账户详情中的单条餐饮支出，支持大字体下自动切换为纵向金额布局。
private struct ExpenseHistoryRow: View {
    /// 已完成本地化与负向金额格式化的流水展示数据。
    let presentation: ExpenseHistoryRowPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    category
                    Spacer(minLength: 8)
                    amount
                }

                VStack(alignment: .leading, spacing: 4) {
                    category
                    amount
                }
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
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("account-detail-expense-\(presentation.id.uuidString)")
    }

    /// 固定餐饮分类，不依赖颜色表达支出类型。
    private var category: some View {
        Text(presentation.categoryTitle)
            .font(.headline)
    }

    /// 已带负号的本地化 CNY 支出金额。
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
        for: [Account.self, ExpenseTransaction.self],
        inMemory: true
    )
}
