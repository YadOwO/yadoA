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

    /// 账户是否仍处于启用状态。
    let isActive: Bool

    /// 是否是当前唯一默认记账账户。
    let isDefault: Bool
}

/// 账户详情的稳定 UUID 解析与展示转换边界。
enum AccountDetailPresentationFactory {
    /// 在当前持久化查询结果中精确解析 UUID；缺失时不降级到其他账户。
    static func account(id: UUID, in accounts: [Account]) -> Account? {
        accounts.first { $0.id == id }
    }

    /// 复用列表展示结果，确保名称、图标和金额语义保持一致。
    static func detail(
        for account: Account,
        locale: Locale = .current,
        defaultAccountID: UUID? = nil
    ) -> AccountDetailPresentation {
        let row = AccountListPresentation.row(
            for: account,
            locale: locale,
            isDefault: account.id == defaultAccountID
        )
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
            icon: row.icon,
            isActive: account.isActive,
            isDefault: row.isDefault
        )
    }
}

/// 账户详情外层负责余额调整、转账 Sheet 与查询刷新生命周期。
struct AccountDetailView: View {
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.modelContext) private var modelContext
    @State private var adjustmentSeed: BalanceAdjustmentSheetSeed?
    @State private var transferDraft: TransferDraft?
    @State private var pendingTransferDeletion: UUID?
    @State private var isTransferDeleteFailed = false
    @State private var editSeed: AccountEditSheetSeed?
    @State private var queryRefreshToken = UUID()
    @State private var isDefaultActionFailed = false
    @State private var isRestoreActionFailed = false
    @State private var isLifecyclePlanLoadFailed = false
    @State private var isLifecycleStateChanged = false
    @State private var lifecyclePlan: AccountDisposalPlan?

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
            onTransfer: { accountID in
                transferDraft = TransferDraft(
                    fromAccountID: accountID,
                    transactionDay: TransactionDay.encode(.now, calendar: calendar)
                )
            },
            onDeleteTransfer: { transactionID in
                pendingTransferDeletion = transactionID
            },
            onEditAccount: { account in
                editSeed = AccountEditSheetSeed(draft: AccountEditDraft(account: account))
            },
            onSetDefault: { accountID in
                do {
                    try LocalAccountRepository(container: modelContext.container)
                        .setDefaultAccount(id: accountID)
                    queryRefreshToken = UUID()
                } catch {
                    isDefaultActionFailed = true
                }
            },
            onRestore: { accountID in
                do {
                    try LocalAccountRepository(container: modelContext.container)
                        .restore(id: accountID)
                    queryRefreshToken = UUID()
                } catch {
                    isRestoreActionFailed = true
                }
            },
            onManageLifecycle: { accountID in
                do {
                    lifecyclePlan = try LocalAccountRepository(container: modelContext.container)
                        .disposalPlan(for: accountID)
                } catch {
                    lifecyclePlan = nil
                    isLifecyclePlanLoadFailed = true
                }
            }
        )
        .id(queryRefreshToken)
        .navigationTitle(AccountLocalization.string("account.detail.title", locale: locale))
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            AccountLocalization.string("account.default.save_error", locale: locale),
            isPresented: $isDefaultActionFailed
        ) {
            Button(AccountLocalization.string("common.close", locale: locale), role: .cancel) {}
        }
        .alert(
            AccountLocalization.string("account.lifecycle.restore_error", locale: locale),
            isPresented: $isRestoreActionFailed
        ) {
            Button(AccountLocalization.string("common.close", locale: locale), role: .cancel) {}
        }
        .alert(
            AccountLocalization.string("account.lifecycle.state_changed", locale: locale),
            isPresented: $isLifecycleStateChanged
        ) {
            Button(AccountLocalization.string("common.close", locale: locale), role: .cancel) {}
        }
        .alert(
            AccountLocalization.string("account.lifecycle.plan_error", locale: locale),
            isPresented: $isLifecyclePlanLoadFailed
        ) {
            Button(AccountLocalization.string("common.close", locale: locale), role: .cancel) {}
        }
        .alert(
            AccountLocalization.string("account.transfer.delete_failed", locale: locale),
            isPresented: $isTransferDeleteFailed
        ) {
            Button(AccountLocalization.string("common.close", locale: locale), role: .cancel) {}
        }
        // 删除转账会同时改动两个账户的余额，先确认一次。
        .confirmationDialog(
            AccountLocalization.string("account.transfer.delete_confirm", locale: locale),
            isPresented: Binding(
                get: { pendingTransferDeletion != nil },
                set: { if !$0 { pendingTransferDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingTransferDeletion
        ) { transactionID in
            Button(AccountLocalization.string("account.transfer.delete", locale: locale), role: .destructive) {
                deleteTransfer(id: transactionID)
            }
            Button(AccountLocalization.string("common.cancel", locale: locale), role: .cancel) {}
        }
        .sheet(item: $transferDraft) { draft in
            NavigationStack {
                TransferView(
                    draft: draft,
                    save: { draft in
                        try LocalTransferRepository(container: modelContext.container).save(draft)
                    },
                    onSaved: {
                        transferDraft = nil
                        queryRefreshToken = UUID()
                    }
                )
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
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
                    draft: seed.draft,
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
        .sheet(item: $lifecyclePlan) { plan in
            NavigationStack {
                AccountLifecycleSheet(
                    plan: plan,
                    save: { expectation in
                        try LocalAccountRepository(container: modelContext.container)
                            .dispose(expectation)
                    },
                    onSaved: {
                        lifecyclePlan = nil
                        queryRefreshToken = UUID()
                    },
                    onNeedsRefresh: {
                        lifecyclePlan = nil
                        queryRefreshToken = UUID()
                        isLifecycleStateChanged = true
                    }
                )
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .paperPage()
    }

    /// 删除一笔转账并刷新详情；失败时提示，余额保持不变。
    ///
    /// - Parameter id: 要删除的转账流水 UUID。
    private func deleteTransfer(id: UUID) {
        do {
            try LocalTransferRepository(container: modelContext.container).delete(id: id)
            queryRefreshToken = UUID()
        } catch {
            isTransferDeleteFailed = true
        }
    }
}

/// 通过独立查询子视图始终从 SwiftData 重新解析账户与其流水。
private struct AccountDetailQueryContent: View {
    @Environment(\.locale) private var locale
    @Query private var accounts: [Account]
    /// 全部账户，用于转账对方账户的名称和判断是否有可转入的账户。
    @Query private var allAccounts: [Account]
    @Query private var preferences: [BookkeepingPreference]
    @Query private var transactions: [AccountTransaction]
    @Query private var categories: [BookkeepingCategory]

    /// 当前详情页对应的稳定账户 UUID。
    let accountID: UUID

    /// 点击调整余额时回传原始账户余额，不从格式化文本反解析。
    let onAdjustBalance: (UUID, Decimal) -> Void

    /// 点击转账时回传当前账户，作为默认的转出账户。
    let onTransfer: (UUID) -> Void

    /// 左滑删除一笔转账时回传流水 UUID，由外层确认后删除。
    let onDeleteTransfer: (UUID) -> Void

    /// 点击详情页编辑入口时回传当前账户模型。
    let onEditAccount: (Account) -> Void

    /// 合格账户点击默认操作后的回调。
    let onSetDefault: (UUID) -> Void

    /// 停用账户点击恢复后的回调。
    let onRestore: (UUID) -> Void

    /// 启用账户打开删除/停用确认流程的回调。
    let onManageLifecycle: (UUID) -> Void

    /// 创建仅查询目标 UUID 的详情内容。
    init(
        accountID: UUID,
        onAdjustBalance: @escaping (UUID, Decimal) -> Void,
        onTransfer: @escaping (UUID) -> Void,
        onDeleteTransfer: @escaping (UUID) -> Void,
        onEditAccount: @escaping (Account) -> Void,
        onSetDefault: @escaping (UUID) -> Void,
        onRestore: @escaping (UUID) -> Void,
        onManageLifecycle: @escaping (UUID) -> Void
    ) {
        let targetAccountID = accountID
        self.accountID = targetAccountID
        self.onAdjustBalance = onAdjustBalance
        self.onTransfer = onTransfer
        self.onDeleteTransfer = onDeleteTransfer
        self.onEditAccount = onEditAccount
        self.onSetDefault = onSetDefault
        self.onRestore = onRestore
        self.onManageLifecycle = onManageLifecycle
        _preferences = Query()
        _categories = Query()
        _allAccounts = Query()
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
        let defaultAccountID = BookkeepingPreference.resolvedAccountID(
            preference: preferences.first { $0.id == BookkeepingPreference.singletonID },
            accounts: accounts
        )
        Group {
            if let account = AccountDetailPresentationFactory.account(id: accountID, in: accounts) {
                detailContent(
                    account: account,
                    presentation: AccountDetailPresentationFactory.detail(
                        for: account,
                        locale: locale,
                        defaultAccountID: defaultAccountID
                    )
                )
            } else {
                unavailableContent
            }
        }
    }

    /// 首屏是写有账户身份、余额和资料的卡片，下面按日分组列出流水（含转入本账户的转账）。
    private func detailContent(
        account: Account,
        presentation: AccountDetailPresentation
    ) -> some View {
        let days = AccountTransactionHistoryPresentation.days(
            for: transactions,
            accountID: account.id,
            accountNames: Dictionary(allAccounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }),
            locale: locale,
            catalog: BookkeepingCategoryCatalog(categories: categories)
        )

        return List {
            Section {
                accountSummary(account: account, presentation: presentation)
                    // 方框画在内容自己的背景上；画成系统行底会被行的圆角裁掉四个角。
                    .listRowInsets(EdgeInsets(top: 8, leading: 2, bottom: 8, trailing: 2))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if !presentation.isActive {
                Section {
                    Button {
                        onRestore(account.id)
                    } label: {
                        Label(
                            AccountLocalization.string("account.lifecycle.restore", locale: locale),
                            systemImage: "arrow.uturn.backward"
                        )
                    }
                    .ledgerRow(seed: 35, showsRule: false)
                    .accessibilityIdentifier("account-detail-restore")
                }
            }

            if days.isEmpty {
                Section {
                    Text(
                        AccountLocalization.string(
                            "account.detail.history.empty",
                            locale: locale
                        )
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .ledgerRow(seed: 36, showsRule: false)
                    .accessibilityIdentifier("account-detail-transaction-history-empty")
                } header: {
                    historyHeading
                        .ledgerHeadingRule(seed: 37)
                }
            } else {
                ForEach(days) { day in
                    Section {
                        ForEach(day.rows) { row in
                            historyRow(row, canDeleteTransfer: presentation.isActive)
                                .ledgerRow(
                                    seed: row.id.handDrawnSeed,
                                    showsRule: row.id != day.rows.last?.id
                                )
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 14) {
                            // 「流水」标题只出现一次，压在第一天的日期上方。
                            if day.id == days.first?.id {
                                historyHeading
                            }
                            AccountHistoryDayHeader(day: day)
                        }
                        .textCase(nil)
                        .listRowInsets(EdgeInsets(top: 0, leading: 2, bottom: 2, trailing: 2))
                    }
                }
            }
        }
        .listSectionSpacing(18)
        .listStyle(.insetGrouped)
        .toolbar {
            if presentation.isActive {
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
            if presentation.isActive,
               account.isEligibleForDefault,
               !presentation.isDefault
            {
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        onSetDefault(account.id)
                    } label: {
                        Label(
                            AccountLocalization.string("account.default.set", locale: locale),
                            systemImage: "star"
                        )
                    }
                    .accessibilityIdentifier("account-detail-set-default")
                }
            }
            if presentation.isActive {
                // 没有流水的账户可以直接删除；记过账的只能停用，菜单按实际会发生的操作命名。
                let canDelete = transactions.isEmpty
                ToolbarItem(placement: .secondaryAction) {
                    Button(role: canDelete ? .destructive : nil) {
                        onManageLifecycle(account.id)
                    } label: {
                        Label(
                            AccountLocalization.string(
                                canDelete ? "account.lifecycle.delete_account" : "account.lifecycle.deactivate",
                                locale: locale
                            ),
                            systemImage: canDelete ? "trash" : "pause.circle"
                        )
                    }
                    .accessibilityIdentifier("account-detail-lifecycle")
                }
            }
        }
    }

    /// 流水区域的衬线标题。
    private var historyHeading: some View {
        Text(AccountLocalization.string("account.detail.history.title", locale: locale))
            .font(.system(.callout, design: .serif, weight: .medium))
            // 分组标题里的 `.primary` 会被系统解析成灰色，这里指定墨色本身。
            .foregroundStyle(Color.primary)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }

    /// 一行流水：收支可进入记账详情；转账在启用账户里可以左滑删除。
    @ViewBuilder
    private func historyRow(
        _ row: AccountTransactionHistoryRowPresentation,
        canDeleteTransfer: Bool
    ) -> some View {
        if row.canOpenBookkeepingDetail {
            // 详情也会出现在设置和账户管理的导航栈中，直接目标无需依赖 Tab 路由注册。
            NavigationLink {
                BookkeepingTransactionDetailView(transactionID: row.id)
            } label: {
                AccountTransactionHistoryRow(presentation: row)
            }
            .navigationLinkIndicatorVisibility(.hidden)
            .accessibilityIdentifier("account-transaction-detail-\(row.id.uuidString)")
        } else if row.isTransfer, canDeleteTransfer {
            AccountTransactionHistoryRow(presentation: row)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        onDeleteTransfer(row.id)
                    } label: {
                        Label(
                            AccountLocalization.string("account.transfer.delete", locale: locale),
                            systemImage: "trash"
                        )
                    }
                }
                .accessibilityAction(named: AccountLocalization.string("account.transfer.delete", locale: locale)) {
                    onDeleteTransfer(row.id)
                }
        } else {
            AccountTransactionHistoryRow(presentation: row)
        }
    }

    /// 能否从本账户发起转账：本账户可记账，且至少还有一个可转入的启用账户。
    private func canTransfer(from account: Account) -> Bool {
        account.supportsBookkeeping
            && TransferView.transferableAccounts(allAccounts).contains { $0.id != account.id }
    }

    /// 一张手绘方框里写完账户的身份、余额、操作和资料；停用或不支持记账的账户不显示操作栏。
    private func accountSummary(
        account: Account,
        presentation: AccountDetailPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 12) {
                AccountIconView(presentation: presentation.icon)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.opacity(0.08), in: HandDrawnBlob(seed: presentation.id.handDrawnSeed))

                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.name)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("account-detail-name")
                    if presentation.isDefault {
                        Text(AccountLocalization.string("account.default.badge", locale: locale))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                            .accessibilityIdentifier("account-default-badge-\(presentation.id.uuidString)")
                    }
                    if !presentation.isActive {
                        Text(AccountLocalization.string("account.detail.deactivated_message", locale: locale))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(presentation.amountLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(presentation.formattedAmount)
                    .font(.system(.largeTitle, design: .serif, weight: .medium).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .accessibilityLabel(presentation.amountAccessibilityLabel)
                    .accessibilityIdentifier("account-detail-amount")
            }

            // 操作栏自带上下两道细线，同时把余额和下面的资料隔开；没有操作栏时只画一道。
            if presentation.isActive && account.supportsBookkeeping {
                AccountDetailActionBar(
                    canTransfer: canTransfer(from: account),
                    onTransfer: { onTransfer(account.id) },
                    onAdjustBalance: { onAdjustBalance(account.id, account.balance) }
                )
            } else {
                HandDrawnRule(seed: 29)
                    .stroke(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                    .frame(height: 3)
                    .accessibilityHidden(true)
            }

            // 资料直接写在卡片下半部分，不再需要展开。
            VStack(spacing: 12) {
                LedgerField(
                    title: AccountLocalization.string("account.detail.type", locale: locale),
                    value: presentation.typeTitle
                )
                .accessibilityIdentifier("account-detail-type")

                if let institution = presentation.institution {
                    LedgerField(
                        title: AccountLocalization.string("account.detail.institution", locale: locale),
                        value: institution
                    )
                    .accessibilityIdentifier("account-detail-institution")
                }

                if let lastFourDigits = presentation.lastFourDigits {
                    LedgerField(
                        title: AccountLocalization.string("account.detail.last_four_digits", locale: locale),
                        value: AccountLocalization.formatted(
                            "account.detail.masked_suffix_format",
                            value: lastFourDigits,
                            locale: locale
                        )
                    )
                    .accessibilityIdentifier("account-detail-last-four-digits")
                }

                if let note = presentation.note {
                    LedgerField(
                        title: AccountLocalization.string("account.detail.note", locale: locale),
                        value: note
                    )
                    .accessibilityIdentifier("account-detail-note")
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            HandDrawnBox(cornerRadius: 22, seed: 23)
                .stroke(
                    Color.primary.opacity(0.85),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                )
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

/// 账户卡片里余额下方的操作栏：转账和调整余额并排，像账页上的两个手写栏目，中间一道竖线隔开。
///
/// 只有一个账户时没有可转入的地方，只显示调整余额。
private struct AccountDetailActionBar: View {
    @Environment(\.locale) private var locale

    /// 是否有可转入的其他账户。
    let canTransfer: Bool

    /// 打开转账表单。
    let onTransfer: () -> Void

    /// 打开余额调整表单。
    let onAdjustBalance: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            rule(seed: 31)
            HStack(spacing: 0) {
                if canTransfer {
                    action(
                        titleKey: "account.transfer.title",
                        symbol: "arrow.left.arrow.right",
                        identifier: "account-detail-transfer",
                        perform: onTransfer
                    )
                    HandDrawnRule(seed: 32)
                        .stroke(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                        // 横线画好再转成竖线；布局仍按横向尺寸占位，正好当两个操作之间的间隔。
                        .frame(width: 24, height: 3)
                        .rotationEffect(.degrees(90))
                        .accessibilityHidden(true)
                }
                action(
                    titleKey: "account.balance_adjustment.title",
                    symbol: "plusminus",
                    identifier: "account-detail-adjust-balance",
                    perform: onAdjustBalance
                )
            }
            rule(seed: 33)
        }
    }

    /// 一个操作：图标和文字居中，整块都可点。
    private func action(
        titleKey: String,
        symbol: String,
        identifier: String,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Label(AccountLocalization.string(titleKey, locale: locale), systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    /// 操作栏上下的淡色手绘细线。
    private func rule(seed: UInt64) -> some View {
        HandDrawnRule(seed: seed)
            .stroke(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            .frame(height: 3)
            .accessibilityHidden(true)
    }
}

/// 账户流水按日分组的日期标题：日期和星期，下面压一条与首页一致的墨线。
private struct AccountHistoryDayHeader: View {
    /// 当前日期组。
    let day: AccountTransactionHistoryDayPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(day.formattedDate)
                    .font(.system(.callout, design: .serif, weight: .medium))
                    .foregroundStyle(Color.primary)
                Text(day.formattedWeekday)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HandDrawnRule(seed: UInt64(truncatingIfNeeded: day.transactionDay))
                .stroke(Color.primary.opacity(0.6), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                .frame(height: 3)
                .accessibilityHidden(true)
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("account-detail-day-\(day.transactionDay)")
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
    /// 被编辑账户的资料值类型快照。
    let draft: AccountEditDraft

    /// `sheet(item:)` 所需的稳定标识。
    var id: UUID { draft.id }
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
                    .font(.system(.subheadline, design: .serif).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // 日期已写在所在日期组的标题里，行内不再重复。
            if let note = presentation.note {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityIdentifier("account-detail-transaction-\(presentation.id.uuidString)")
    }

    /// 收支、转账或余额调整标题，不依赖颜色表达流水类型。
    private var title: some View {
        Text(presentation.title)
            .font(.headline)
    }

    /// 已带明确正负方向的本地化 CNY 金额。
    private var amount: some View {
        Text(presentation.formattedAmount)
            .font(.system(.body, design: .serif).monospacedDigit())
    }
}

#Preview("Account unavailable") {
    NavigationStack {
        AccountDetailView(accountID: UUID())
    }
    .modelContainer(
        for: [Account.self, AccountTransaction.self, BookkeepingPreference.self],
        inMemory: true
    )
}

#if DEBUG
#Preview("Account details · populated") {
    if let container = try? HomeDesignPreviewData.makeContainer(),
       let accounts = try? container.mainContext.fetch(FetchDescriptor<Account>()),
       let account = accounts.first {
        NavigationStack {
            AccountDetailView(accountID: account.id)
        }
        .modelContainer(container)
        .environment(\.locale, Locale(identifier: "zh-Hans"))
    }
}
#endif
