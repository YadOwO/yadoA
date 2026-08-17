import Foundation
import SwiftData
import SwiftUI

/// 与 SwiftUI 渲染解耦的账户行展示数据，便于验证本地化和未知值降级。
struct AccountRowPresentation: Identifiable, Equatable {
    /// 持久账户的稳定标识。
    let id: UUID

    /// 已知模板使用当前语言标签，其他情况保留持久化账户名称。
    let name: String

    /// 本地化账户类型及可选掩码后缀。
    let detail: String

    /// 使用账户自身货币代码格式化后的金额。
    let formattedAmount: String

    /// 明确表达余额、金额或债务含义的可见标签。
    let amountLabel: String

    /// 同时包含金融语义与金额的无障碍播报文本。
    let amountAccessibilityLabel: String

    /// 品牌图片或类型降级图标。
    let icon: AccountIconPresentation
}

/// 账户列表顶部资产汇总卡片的展示数据。
struct AccountSummaryPresentation: Equatable {
    /// 所有资产账户余额减去所有负债账户余额后的净资产。
    let netAssets: Decimal

    /// 非负债类型账户的余额总和。
    let assets: Decimal

    /// 信用卡和负债类型账户的债务总和。
    let liabilities: Decimal

    /// 当前语言环境下格式化后的净资产。
    let formattedNetAssets: String

    /// 当前语言环境下格式化后的资产总额。
    let formattedAssets: String

    /// 当前语言环境下格式化后的负债总额。
    let formattedLiabilities: String

    /// 包含三项汇总和金额的完整播报文本。
    let accessibilityLabel: String

    /// 从账户列表生成资产、负债和净资产汇总。
    ///
    /// 未知账户类型按资产处理，以避免损坏或未来类型的余额从总览中无提示消失。
    static func summary(
        for accounts: [Account],
        locale: Locale = .current
    ) -> AccountSummaryPresentation {
        var assets = Decimal.zero
        var liabilities = Decimal.zero

        for account in accounts {
            if account.accountType?.expenseBalanceEffect == .increaseDebt {
                liabilities += account.balance
            } else {
                assets += account.balance
            }
        }

        let netAssets = assets - liabilities
        let formattedNetAssets = AccountListPresentation.currencyAmount(
            netAssets,
            currencyCode: "CNY",
            locale: locale
        )
        let formattedAssets = AccountListPresentation.currencyAmount(
            assets,
            currencyCode: "CNY",
            locale: locale
        )
        let formattedLiabilities = AccountListPresentation.currencyAmount(
            liabilities,
            currencyCode: "CNY",
            locale: locale
        )
        let accessibilityLabel = String(
            format: AccountLocalization.string(
                "account.summary.accessibility_format",
                locale: locale
            ),
            locale: locale,
            AccountLocalization.string("account.summary.net_assets", locale: locale),
            formattedNetAssets,
            AccountLocalization.string("account.summary.assets", locale: locale),
            formattedAssets,
            AccountLocalization.string("account.summary.liabilities", locale: locale),
            formattedLiabilities
        )

        return AccountSummaryPresentation(
            netAssets: netAssets,
            assets: assets,
            liabilities: liabilities,
            formattedNetAssets: formattedNetAssets,
            formattedAssets: formattedAssets,
            formattedLiabilities: formattedLiabilities,
            accessibilityLabel: accessibilityLabel
        )
    }
}

/// 账户列表查询结果的确定性排序与展示转换边界。
enum AccountListPresentation {
    /// 最新更新时间优先；时间相同时按 UUID 字符串升序稳定排列。
    static func sorted(_ accounts: [Account]) -> [Account] {
        accounts.sorted(by: AccountOrdering.newestFirst)
    }

    /// 将持久模型安全转换为当前语言环境的行展示数据。
    static func row(for account: Account, locale: Locale = .current) -> AccountRowPresentation {
        let accountType = account.accountType
        let template = template(id: account.templateID, accountType: accountType)
        let typeTitle = accountType?.title(locale: locale)
            ?? AccountLocalization.string("account.type.unknown.title", locale: locale)
        let amountLabel = accountType?.amountLabel(locale: locale)
            ?? AccountLocalization.string("account.amount.value", locale: locale)
        let formattedAmount = currencyAmount(
            account.balance,
            currencyCode: account.currencyCode,
            locale: locale
        )
        let detail: String
        if let suffix = account.lastFourDigits {
            detail = String(
                format: AccountLocalization.string("account.list.type_suffix_format", locale: locale),
                locale: locale,
                typeTitle,
                suffix
            )
        } else {
            detail = typeTitle
        }
        let accessibilityLabel = String(
            format: AccountLocalization.string("account.list.amount_accessibility_format", locale: locale),
            locale: locale,
            amountLabel,
            formattedAmount
        )

        return AccountRowPresentation(
            id: account.id,
            name: template?.name(locale: locale) ?? account.name,
            detail: detail,
            formattedAmount: formattedAmount,
            amountLabel: amountLabel,
            amountAccessibilityLabel: accessibilityLabel,
            icon: AccountIconPresentation(
                brandImageName: template?.brandImageName,
                symbolName: template?.symbolName ?? accountType?.symbolName ?? "questionmark.circle.fill",
                tint: accountType?.tint ?? .secondary
            )
        )
    }

    /// 仅接受与持久账户类型一致的当前静态模板，避免过期或损坏 ID 误配品牌。
    static func template(id: String?, accountType: AccountType?) -> AccountTemplate? {
        guard let id, let accountType else { return nil }
        return accountType.templates.first { $0.id == id }
    }

    /// 使用持久化 ISO 货币代码与当前语言环境格式化精确金额。
    fileprivate static func currencyAmount(
        _ amount: Decimal,
        currencyCode: String,
        locale: Locale
    ) -> String {
        amount.formatted(
            .currency(code: currencyCode)
                .locale(locale)
        )
    }
}

/// 将账户数量映射为空/非空状态下唯一主要添加入口的位置。
enum AccountListState {
    /// 空状态是否展示内嵌添加入口。
    static func showsInlineAdd(accountCount: Int) -> Bool { accountCount == 0 }

    /// 非空状态是否展示导航栏添加入口。
    static func showsToolbarAdd(accountCount: Int) -> Bool { accountCount > 0 }

}

/// 应用根账户列表，根据 SwiftData 查询结果切换空状态与列表状态。
struct AccountListView: View {
    @Environment(\.locale) private var locale
    @Environment(\.modelContext) private var modelContext
    @Query private var queriedAccounts: [Account]
    @State private var isPresentingCreation = false

    var body: some View {
        let accounts = AccountListPresentation.sorted(queriedAccounts)

        NavigationStack {
            Group {
                if AccountListState.showsInlineAdd(accountCount: accounts.count) {
                    emptyContent
                } else {
                    accountList(accounts)
                }
            }
            .navigationTitle(AccountLocalization.string("account.list.title", locale: locale))
            .toolbar {
                if AccountListState.showsToolbarAdd(accountCount: accounts.count) {
                    ToolbarItem(placement: .primaryAction) {
                        addButton(identifier: "account-list-toolbar-add")
                    }
                }
            }
        }
        .sheet(isPresented: $isPresentingCreation) {
            AccountCreationView { draft in
                // 独占写入 context 的失败回滚不会影响 SwiftUI 环境中的其他修改。
                let repository = LocalAccountRepository(container: modelContext.container)
                try repository.save(draft, locale: locale)
            }
        }
    }

    /// 干净存储唯一的主要添加入口。
    private var emptyContent: some View {
        ContentUnavailableView {
            Label(
                AccountLocalization.string("account.list.empty.title", locale: locale),
                systemImage: "tray"
            )
        } description: {
            Text(AccountLocalization.string("account.list.empty.message", locale: locale))
        } actions: {
            addButton(identifier: "account-list-empty-add")
        }
    }

    /// 非空状态下的独立汇总卡片和账户列表；添加入口只保留在导航栏尾部。
    private func accountList(_ accounts: [Account]) -> some View {
        let summary = AccountSummaryPresentation.summary(for: accounts, locale: locale)

        return ScrollView {
            LazyVStack(spacing: 0) {
                AccountSummaryCard(presentation: summary)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                ForEach(accounts) { account in
                    let presentation = AccountListPresentation.row(for: account, locale: locale)
                    NavigationLink(value: account.id) {
                        AccountListRow(presentation: presentation)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("account-list-row-\(account.id.uuidString)")

                    Divider()
                        .padding(.leading, 16)
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationDestination(for: UUID.self) { accountID in
            AccountDetailView(accountID: accountID)
        }
    }

    /// 构造具有稳定自动化标识的主要添加按钮。
    private func addButton(identifier: String) -> some View {
        Button {
            isPresentingCreation = true
        } label: {
            Label(
                AccountLocalization.string("account.list.add", locale: locale),
                systemImage: "plus"
            )
        }
        .accessibilityIdentifier(identifier)
    }
}

/// 账户列表顶部的资产汇总卡片，突出净资产并并列展示资产和负债。
private struct AccountSummaryCard: View {
    @Environment(\.locale) private var locale

    let presentation: AccountSummaryPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(
                    AccountLocalization.string(
                        "account.summary.net_assets",
                        locale: locale
                    )
                )
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

                Text(presentation.formattedNetAssets)
                    .font(.largeTitle.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }

            HStack(alignment: .top, spacing: 16) {
                AccountSummaryMetric(
                    title: AccountLocalization.string("account.summary.assets", locale: locale),
                    amount: presentation.formattedAssets
                )

                Divider()
                    .frame(height: 34)

                AccountSummaryMetric(
                    title: AccountLocalization.string(
                        "account.summary.liabilities",
                        locale: locale
                    ),
                    amount: presentation.formattedLiabilities
                )
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityIdentifier("account-list-summary-card")
    }
}

/// 汇总卡片中资产或负债的次级金额指标。
private struct AccountSummaryMetric: View {
    let title: String
    let amount: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(amount)
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 支持动态字体换行、且不依赖颜色表达金额语义的共享账户行。
struct AccountListRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let presentation: AccountRowPresentation

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                identityContent
                amountContent
            }
            .padding(.vertical, 6)
        } else {
            HStack(alignment: .center, spacing: 12) {
                identityContent
                Spacer(minLength: 12)
                amountContent
            }
            .padding(.vertical, 4)
        }
    }

    /// 图标、名称和账户类型信息。
    private var identityContent: some View {
        HStack(alignment: .center, spacing: 12) {
            AccountIconView(presentation: presentation.icon)

            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.name)
                    .font(.headline)
                Text(presentation.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 同时可见表达金融语义并完整播报金额的内容。
    private var amountContent: some View {
        VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
            Text(presentation.amountLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(presentation.formattedAmount)
                .font(.body.monospacedDigit())
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.amountAccessibilityLabel)
        .accessibilityIdentifier("account-list-amount-\(presentation.id.uuidString)")
    }
}

#Preview {
    AccountListView()
        .modelContainer(
            for: [Account.self, AccountTransaction.self],
            inMemory: true
        )
}
