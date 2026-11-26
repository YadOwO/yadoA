import Foundation
import SwiftData
import SwiftUI

/// 应用根账户列表，根据 SwiftData 查询结果切换空状态与列表状态。
struct AccountListView: View {
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 语音记账共享状态；预览中没有注入时为 nil。
    @Environment(VoiceBookkeepingState.self) private var voice: VoiceBookkeepingState?
    @Query private var queriedAccounts: [Account]
    @Query private var preferences: [BookkeepingPreference]
    /// 汇总卡片里净资产走势的材料；在数据变化后汇总一次，账户页不再读全部流水。
    @Environment(BalanceHistoryStore.self) private var balanceHistory
    /// 数据联动状态：芽豆有物的物品估值；预览中没有注入时为 nil。
    @Environment(DataLinkStore.self) private var dataLinks: DataLinkStore?
    /// 全局登录状态；读它是为了登录和退出登录时重绘估值。预览中没有注入时为 nil。
    @Environment(AuthStore.self) private var authStore: AuthStore?
    /// 隐私政策同意状态；读它是为了允许或禁止联网时重绘估值。预览中没有注入时为 nil。
    @Environment(PrivacyAgreementStore.self) private var privacyAgreement: PrivacyAgreementStore?
    @State private var isPresentingCreation = false
    @State private var isPresentingManagement = false
    @State private var isPresentingDeactivated = false
    /// 正在填写的转账；为空时不显示转账表单。
    @State private var transferDraft: TransferDraft?
    /// 账户列表当前是否显示在屏幕上；切到别的 Tab 或进入详情时不播放语音改动提示。
    @State private var isVisible = false
    /// 正在播放的语音改动提示；到期后清除。
    @State private var voiceMark: AccountListVoiceMark?
    /// 用户确认过「确实多还了」、不再提示欠款为负的账户，逗号分隔的 UUID。
    @AppStorage(NegativeDebtHint.dismissedStorageKey) private var dismissedNegativeDebtIDs = ""
    /// 云同步生命周期；刚启动、引擎还没建好或预览里没有注入时为 nil。
    @Environment(SyncLifecycle.self) private var syncLifecycle: SyncLifecycle?
    /// 备份提醒用的流水样本：按保存时间升序最多 20 笔，条数即 min(总数, 20)，第一笔就是最早的一笔；记账后自动刷新。
    @Query(BackupReminderPolicy.transactionSampleDescriptor) private var backupReminderSample: [AccountTransaction]
    /// 上次备份时间戳；导出流程写入后卡片随之消失。
    @AppStorage(BackupReminderStore.lastExportedAtKey) private var lastExportedAt: Double?
    /// 提醒暂缓截止时间戳；点「以后再说」后写入。
    @AppStorage(BackupReminderStore.snoozedUntilKey) private var backupSnoozedUntil: Double?

    /// 语音改动提示从出现到笔迹淡出所需的总时长，之后清除标记。
    private static let voiceMarkLifetime: Duration = .milliseconds(4000)

    var body: some View {
        let order = AccountDisplayOrder(preferences: preferences)
        let accounts = AccountListPresentation.sorted(queriedAccounts, order: order)

        Group {
            if AccountListState.showsInlineAdd(accountCount: accounts.count) {
                emptyContent
            } else {
                accountList(accounts, sections: order.sections(accounts))
            }
        }
        .navigationTitle(AccountLocalization.string("account.list.title", locale: locale))
        // 和记账、图表、「我的」三个一级页面一样用居中的小标题，不用大标题。
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 添加账户是这一页最常要找的操作：有账户时右上角直接放「＋」，一点就打开；没有账户时添加按钮在页面中间。
            if AccountListState.showsToolbarAdd(accountCount: accounts.count) {
                ToolbarItem(placement: .primaryAction) {
                    addButton(identifier: "account-list-toolbar-add")
                }
            }
            // 转账和账户管理收进「更多」菜单，右上角最多两个按钮。至少两个可记账账户才有转账的意义。
            ToolbarItem(placement: .primaryAction) {
                moreMenu(showsTransfer: TransferView.transferableAccounts(queriedAccounts, order: order).count >= 2)
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .refreshesBalanceHistory()
        // 出现时刷新一次物品估值；5 分钟内不重复拉由 store 负责
        .task { await refreshItemValuation() }
        // 用户正看着账户页时语音改了账户：在这些账户的名称和金额下补一道笔迹，并把第一个滚到可见处
        .onChange(of: voice?.session?.latestTurn?.outcome) { _, outcome in
            guard isVisible, outcome != .processing, let turn = voice?.session?.latestTurn else { return }
            let accountIDs = turn.changedAccountIDs
            guard !accountIDs.isEmpty else { return }
            showVoiceMark(AccountListVoiceMark(accountIDs: accountIDs))
        }
        .sheet(isPresented: $isPresentingCreation) {
            AccountCreationView { draft in
                // 独占写入 context 的失败回滚不会影响 SwiftUI 环境中的其他修改。
                let repository = LocalAccountRepository(container: modelContext.container)
                try repository.save(draft, locale: locale)
            }
        }
        .sheet(isPresented: $isPresentingManagement) {
            NavigationStack {
                AccountManagementView()
            }
        }
        .sheet(isPresented: $isPresentingDeactivated) {
            NavigationStack {
                DeactivatedAccountListView()
            }
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
                    }
                )
            }
            .presentationDragIndicator(.visible)
        }
        .paperPage()
    }

    /// 物品估值的数据来源：已登录并且允许联网时才是联动状态，否则为 nil，账户页就不出现估值。
    ///
    /// 在这里读登录和联网状态，它们变化时账户页会重绘。
    private var valuationStore: DataLinkStore? {
        guard authStore?.isAuthenticated ?? true, privacyAgreement?.allowsNetwork ?? true else { return nil }
        return dataLinks
    }

    /// 刷新联动列表和物品估值；下拉刷新和页面出现都走这里，不允许联网或没登录时 store 什么都不发。
    private func refreshItemValuation() async {
        await dataLinks?.refreshLinks()
        await dataLinks?.refreshItemValueIfStale()
    }

    /// 播放一次语音改动提示，到期后只清除这一次，不影响之后的新提示。
    private func showVoiceMark(_ mark: AccountListVoiceMark) {
        voiceMark = mark
        Task {
            try? await Task.sleep(for: Self.voiceMarkLifetime)
            if voiceMark == mark {
                voiceMark = nil
            }
        }
    }

    /// 是否在列表顶部显示备份提醒卡片，判断规则见 `BackupReminderPolicy`。
    ///
    /// 取不到同步生命周期（刚启动、引擎还没建好）时按已开同步处理，不显示，避免开了同步的用户看到卡片一闪。
    private var showsBackupReminder: Bool {
        BackupReminderPolicy(
            now: .now,
            isSyncEnabled: syncLifecycle?.state.isEnabled ?? true,
            transactionCount: backupReminderSample.count,
            earliestTransactionSavedAt: backupReminderSample.first?.savedAt,
            lastBackupAt: BackupReminderStore.date(fromStored: lastExportedAt),
            snoozedUntil: BackupReminderStore.date(fromStored: backupSnoozedUntil)
        ).showsReminder
    }

    /// 从账户列表发起转账时预选的转出账户：有默认记账账户时用它，否则先不选。
    private var defaultTransferSourceID: UUID? {
        BookkeepingPreference.resolvedAccountID(
            preference: BookkeepingPreference.canonical(in: preferences),
            accounts: queriedAccounts
        )
    }

    /// 右上角的「更多」菜单：可以转账时提供转账，始终提供账户管理。
    ///
    /// 系统菜单不保留菜单项的 identifier，UI 测试按菜单项标题查找。
    /// - Parameter showsTransfer: 是否提供转账；可记账账户不足两个时没有转账的意义。
    private func moreMenu(showsTransfer: Bool) -> some View {
        Menu {
            if showsTransfer {
                Button {
                    transferDraft = TransferDraft(
                        fromAccountID: defaultTransferSourceID,
                        transactionDay: TransactionDay.encode(.now, calendar: calendar)
                    )
                } label: {
                    Label(
                        AccountLocalization.string("account.transfer.title", locale: locale),
                        systemImage: "arrow.left.arrow.right"
                    )
                }
                .accessibilityIdentifier("account-list-transfer")
            }
            Button {
                isPresentingManagement = true
            } label: {
                Label(
                    AccountLocalization.string("account.management.title", locale: locale),
                    systemImage: "gearshape"
                )
            }
            .accessibilityIdentifier("account-list-management")
        } label: {
            Label(
                AccountLocalization.string("account.list.more", locale: locale),
                systemImage: moreSymbolName
            )
        }
        .accessibilityIdentifier("account-list-more")
    }

    /// 「更多」按钮的图标：iOS 26 起导航栏按钮自带圆形玻璃底，用不带圆圈的省略号；更早的系统用带圆圈的样式。
    private var moreSymbolName: String {
        if #available(iOS 26, *) {
            return "ellipsis"
        }
        return "ellipsis.circle"
    }

    /// 干净存储唯一的主要添加入口。
    private var emptyContent: some View {
        ContentUnavailableView {
            // 与首页、账单空状态一致的排版，图标换成手绘卡片。
            Label {
                Text(AccountLocalization.string("account.list.empty.title", locale: locale))
            } icon: {
                HandDrawnCardIllustration()
            }
        } description: {
            Text(AccountLocalization.string("account.list.empty.message", locale: locale))
        } actions: {
            VStack(spacing: 12) {
                addButton(identifier: "account-list-empty-add")
                if queriedAccounts.contains(where: { !$0.isActive && !$0.isUnlinked }) {
                    Button {
                        isPresentingDeactivated = true
                    } label: {
                        Label(
                            AccountLocalization.string("account.deactivated.title", locale: locale),
                            systemImage: "archivebox"
                        )
                    }
                    .accessibilityIdentifier("account-list-empty-deactivated")
                }
            }
        }
    }

    /// 非空状态下使用原生 SwiftUI List 展示账户；汇总是手绘方框，账户按分类分段直接写在纸面上。
    ///
    /// - Parameters:
    ///   - accounts: 按统一顺序排好的启用账户。
    ///   - sections: 同一批账户按分类分好的组。
    private func accountList(_ accounts: [Account], sections: [AccountTypeSection]) -> some View {
        // 估值只在「计入净资产」打开时加进资产；走势不含它
        let netWorthValuation = valuationStore?.netWorthValuation
        let summary = AccountSummaryPresentation.summary(
            for: accounts,
            additionalAssets: netWorthValuation ?? 0,
            locale: locale
        )
        let defaultAccountID = BookkeepingPreference.resolvedAccountID(
            preference: BookkeepingPreference.canonical(in: preferences),
            accounts: accounts
        )
        let negativeDebtAccounts = NegativeDebtHint.accounts(
            in: accounts,
            dismissedIDs: NegativeDebtHint.dismissedIDs(from: dismissedNegativeDebtIDs)
        )

        return ScrollViewReader { proxy in
            List {
                // 没开云同步、账本有一定量记录又很久没备份时，提醒导出备份；点「以后再说」暂缓 30 天
                if showsBackupReminder {
                    BackupReminderCard(
                        container: modelContext.container,
                        onLater: { BackupReminderStore.snooze(from: .now) }
                    )
                    .listRowInsets(EdgeInsets(top: 12, leading: 2, bottom: 0, trailing: 2))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                summaryCard(
                    summary,
                    trend: netWorthTrend(of: accounts),
                    trendFootnote: netWorthValuation == nil
                        ? nil
                        : AccountLocalization.string("dataLink.trend.excludes_item_value", locale: locale)
                )
                    .listRowInsets(
                        EdgeInsets(top: 12, leading: 2, bottom: 8, trailing: 2)
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                // 有欠款填成了负数时，净资产会偏高；紧跟在汇总下面提示，点一下打开第一个这样的账户去改。
                // 两栏时打开的账户会在对应的账户行上标出，提示本身不标
                if let firstNegativeDebt = negativeDebtAccounts.first {
                    TabRouteLink(value: AccountsRoute.detail(firstNegativeDebt.id), marksSelection: false) {
                        NegativeDebtListHint(
                            names: negativeDebtAccounts.map { AccountListPresentation.row(for: $0, locale: locale).name }
                        )
                    }
                    .navigationLinkIndicatorVisibility(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 2, bottom: 8, trailing: 2))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("account-list-negative-debt-hint")
                }

                ForEach(sections) { section in
                    Section {
                        ForEach(section.accounts) { account in
                            let presentation = AccountListPresentation.row(
                                for: account,
                                locale: locale,
                                isDefault: account.id == defaultAccountID
                            )
                            // 两栏时换掉右栏；行距紧，选中底色往外扩一点
                            TabRouteLink(value: AccountsRoute.detail(account.id), selectionOutset: 6) {
                                AccountListRow(
                                    presentation: presentation,
                                    voiceMarkToken: voiceMark.flatMap { $0.accountIDs.contains(account.id) ? $0.token : nil }
                                )
                                // 列表里的按钮会把标签染成强调色，原来的 NavigationLink 是主文字色
                                .foregroundStyle(Color.primary)
                            }
                            .navigationLinkIndicatorVisibility(.hidden)
                            .ledgerRow(
                                seed: account.id.handDrawnSeed,
                                showsRule: account.id != section.accounts.last?.id
                            )
                            .accessibilityIdentifier("account-list-row-\(account.id.uuidString)")
                            .id(account.id)
                        }
                    } header: {
                        AccountSectionHeader(title: section.title(locale: locale), seed: section.id.handDrawnSeed)
                            .accessibilityIdentifier("account-list-section-\(section.id)")
                    }
                }

                // 芽豆有物的物品估值：账户类型分组后面单独一组，只有一行、只读；只出现在这里和资产分析，空状态页不加
                if let store = valuationStore, store.showsAccountRow, let itemSummary = store.cachedSummary {
                    Section {
                        TabRouteLink(value: AccountsRoute.itemValuation, selectionOutset: 6) {
                            AccountListRow(
                                presentation: ItemValuationPresentation.row(
                                    summary: itemSummary,
                                    settings: store.settings,
                                    locale: locale
                                )
                            )
                            // 列表里的按钮会把标签染成强调色，原来的 NavigationLink 是主文字色
                            .foregroundStyle(Color.primary)
                        }
                        .navigationLinkIndicatorVisibility(.hidden)
                        .ledgerRow(seed: ItemValuationPresentation.rowID.handDrawnSeed, showsRule: false)
                        .accessibilityIdentifier("account-list-item-valuation")
                    } header: {
                        AccountSectionHeader(
                            title: AccountLocalization.string("itemValuation.section.title", locale: locale),
                            seed: "itemValuation.section".handDrawnSeed
                        )
                        .accessibilityIdentifier("account-list-section-item-valuation")
                    }
                }
            }
            .listStyle(.insetGrouped)
            // 下拉刷新联动列表和物品估值；5 分钟内不重复拉由 store 负责
            .refreshable { await refreshItemValuation() }
            // 宽屏单栏时居中排成阅读宽度
            .readableContentWidth(sideMargin: ReadableContentWidth.listSideMargin)
            .onChange(of: voiceMark) { _, mark in
                guard let mark, let first = accounts.first(where: { mark.accountIDs.contains($0.id) }) else { return }
                // 会话卡片压在列表下半部分，把账户滚到偏上的位置；列表一屏放得下时不会移动
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
                    proxy.scrollTo(first.id, anchor: UnitPoint(x: 0.5, y: 0.2))
                }
            }
        }
    }

    /// 汇总卡片；整张卡片点进资产分析页（两栏时换掉右栏）。还没记过账、画不出走势时也能进，构成和排行按当前余额就能看。
    ///
    /// - Parameters:
    ///   - summary: 资产、负债和净资产汇总。
    ///   - trend: 净资产近三个月的走势；还没记过账时为 `nil`，卡片里不画迷你走势。
    ///   - trendFootnote: 走势下面的说明；估值计入净资产时说明走势不含它，否则为 `nil`。
    private func summaryCard(
        _ summary: AccountSummaryPresentation,
        trend: BalanceTrendSeries?,
        trendFootnote: String?
    ) -> some View {
        // 卡片自带手绘方框，不再垫选中底色
        TabRouteLink(value: AccountsRoute.assetAnalysis, marksSelection: false) {
            AccountSummaryCard(presentation: summary, trend: trend, showsDisclosure: true, trendFootnote: trendFootnote)
                // 列表里的按钮会把标签染成强调色，原来的 NavigationLink 是主文字色
                .foregroundStyle(Color.primary)
        }
        .navigationLinkIndicatorVisibility(.hidden)
    }

    /// 启用账户合计的净资产近三个月走势，与汇总卡片同一口径；一笔流水都没有、或材料还没汇总好时不画。
    ///
    /// - Parameter accounts: 列表里的启用账户。
    private func netWorthTrend(of accounts: [Account]) -> BalanceTrendSeries? {
        guard let ledgers = balanceHistory.ledgers else { return nil }
        let history = AccountBalanceHistory(
            ledgers: ledgers,
            accountIDs: Set(accounts.map(\.id)),
            calendar: calendar
        )
        guard history.hasHistory() else { return nil }
        return history.netWorthSeries(.netAssets, range: .threeMonths)
    }

    /// 构造具有稳定自动化标识的主要添加按钮；空状态放在页面中间，有账户时放在右上角。
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

/// 支持动态字体换行的共享账户行；金额语义由“余额/欠款”标签表达，欠款金额的颜色只是轻提示。
struct AccountListRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let presentation: AccountRowPresentation

    /// 语音改动提示的标识；有值时在名称和金额下补一道笔迹，换了新标识会从头再画一次。只有账户页列表会传。
    var voiceMarkToken: UUID?

    /// 提示笔迹的书写进度。
    @State private var markProgress: CGFloat = 0

    /// 提示笔迹是否可见；收尾时整道线淡出，而不是倒着擦掉。
    @State private var isMarkVisible = false

    var body: some View {
        rowContent
            .task(id: voiceMarkToken) {
                await playVoiceMark()
            }
    }

    /// 常规字号左右排列，辅助功能字号上下排列。
    @ViewBuilder
    private var rowContent: some View {
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
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(presentation.name)
                        .font(.headline)
                        .modifier(voiceUnderline(seed: 3))
                    if presentation.isDefault {
                        Text(AccountLocalization.string("account.default.badge", locale: locale))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.12), in: Capsule())
                            .accessibilityIdentifier("account-default-badge-\(presentation.id.uuidString)")
                    }
                }
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
                .font(.system(.body, design: .serif).monospacedDigit())
                .amountTone(presentation.amountTone)
                .modifier(voiceUnderline(seed: 9))
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            presentation.isDefault
                ? "\(presentation.name), \(AccountLocalization.string("account.default.badge", locale: locale)), \(presentation.amountAccessibilityLabel)"
                : "\(presentation.name), \(presentation.amountAccessibilityLabel)"
        )
        .accessibilityIdentifier("account-list-amount-\(presentation.id.uuidString)")
    }

    /// 名称或金额下的提示笔迹。
    ///
    /// - Parameter seed: 区分两处笔迹形状的种子。
    private func voiceUnderline(seed: UInt64) -> AccountRowVoiceUnderline {
        AccountRowVoiceUnderline(
            seed: presentation.id.handDrawnSeed &+ seed,
            progress: markProgress,
            isVisible: isMarkVisible
        )
    }

    /// 播放语音改动提示：等滚动停稳后写出笔迹，停留片刻后淡出；标识清空时复位。
    private func playVoiceMark() async {
        markProgress = 0
        isMarkVisible = false
        guard voiceMarkToken != nil else { return }
        isMarkVisible = true
        do {
            try await Task.sleep(for: .milliseconds(300))
            if reduceMotion {
                markProgress = 1
            } else {
                withAnimation(.easeInOut(duration: 0.4)) { markProgress = 1 }
            }
            try await Task.sleep(for: .milliseconds(1800))
            withAnimation(.easeInOut(duration: reduceMotion ? 0.4 : 0.8)) {
                isMarkVisible = false
            }
        } catch {
            // 行被回收或提示被替换时直接结束，新的提示会从头再播
        }
    }
}

/// 语音改动账户后在名称和金额下补的一道墨色细线，与首页修改提示的下划线一致。
private struct AccountRowVoiceUnderline: ViewModifier {
    /// 笔迹种子。
    let seed: UInt64

    /// 书写进度。
    let progress: CGFloat

    /// 是否可见。
    let isVisible: Bool

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                HandDrawnRule(seed: seed)
                    .trim(from: 0, to: progress)
                    .stroke(Color.primary.opacity(0.45), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                    .frame(height: 3)
                    .offset(y: 4)
                    .opacity(isVisible ? 1 : 0)
                    .accessibilityHidden(true)
            }
    }
}

/// 汇总卡片下的一条提示：有账户的欠款填成了负数，被当成多还的钱算进资产，净资产可能偏高。
///
/// 整条点开第一个这样的账户，在详情里一键改成正数，或确认确实多还了。
private struct NegativeDebtListHint: View {
    @Environment(\.locale) private var locale

    /// 欠款为负的账户名称，按显示顺序排列。
    let names: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .font(.body)
                .foregroundStyle(Color(.ledgerRed))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(AccountLocalization.formatted(
                    "account.negative_debt.list.message",
                    value: NegativeDebtHint.quotedNames(names, locale: locale),
                    locale: locale
                ))
                .font(.subheadline)
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)

                Text(AccountLocalization.string("account.negative_debt.list.action", locale: locale))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(.ledgerRed))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 3)
                .accessibilityHidden(true)
        }
        .padding(14)
        .background(Color(.ledgerRed).opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// 账户页一次语音改动提示：本轮改动过的账户与本次提示标识。
private struct AccountListVoiceMark: Equatable {
    /// 本轮改动过、仍在列表中的账户。
    let accountIDs: Set<UUID>

    /// 每次提示的唯一标识；同一账户连续两轮改动时，旧提示到期不会误删新提示。
    let token = UUID()
}

#Preview {
    NavigationStack {
        AccountListView()
    }
        .environment(BalanceHistoryStore())
        .modelContainer(
            for: [Account.self, AccountTransaction.self, BookkeepingPreference.self],
            inMemory: true
        )
}
