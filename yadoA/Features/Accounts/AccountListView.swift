import Foundation
import SwiftData
import SwiftUI

/// 与 SwiftUI 渲染解耦的账户行展示数据，便于验证本地化和未知值降级。
struct AccountRowPresentation: Identifiable, Equatable {
    /// 持久账户的稳定标识。
    let id: UUID

    /// 不可改名的机构账户使用本地化模板标签，其余保留持久化账户名称。
    let name: String

    /// 本地化账户类型及可选掩码后缀。
    let detail: String

    /// 使用账户自身货币代码格式化后的金额。
    let formattedAmount: String

    /// 明确表达余额、金额或债务含义的可见标签。
    let amountLabel: String

    /// 同时包含金融语义与金额的无障碍播报文本。
    let amountAccessibilityLabel: String

    /// 是否是当前唯一默认记账账户。
    let isDefault: Bool

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

        for account in accounts where account.isActive {
            if account.accountType?.expenseBalanceEffect == .increaseDebt {
                liabilities += account.balance
            } else {
                assets += account.balance
            }
        }
        return summary(assets: assets, liabilities: liabilities, locale: locale)
    }

    /// 由已经汇总好的资产和负债生成展示数据；首次引导的示例账户也用它，和账户页保持同一种写法。
    ///
    /// - Parameters:
    ///   - assets: 资产总额。
    ///   - liabilities: 负债总额，以正数表示欠款。
    ///   - locale: 金额与播报文本使用的语言环境。
    /// - Returns: 资产、负债和净资产汇总。
    static func summary(
        assets: Decimal,
        liabilities: Decimal,
        locale: Locale = .current
    ) -> AccountSummaryPresentation {
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
        accounts.filter { $0.isActive }.sorted(by: AccountOrdering.newestFirst)
    }

    /// 将持久模型安全转换为当前语言环境的行展示数据。
    static func row(
        for account: Account,
        locale: Locale = .current,
        isDefault: Bool = false
    ) -> AccountRowPresentation {
        row(
            id: account.id,
            accountType: account.accountType,
            templateID: account.templateID,
            name: account.name,
            lastFourDigits: account.lastFourDigits,
            balance: account.balance,
            currencyCode: account.currencyCode,
            locale: locale,
            isDefault: isDefault
        )
    }

    /// 由账户字段生成行展示数据；首次引导的示例账户不落库，也用它得到与账户页一致的一行。
    ///
    /// - Parameters:
    ///   - id: 账户标识。
    ///   - accountType: 账户类型；未知类型为 `nil`。
    ///   - templateID: 静态模板标识。
    ///   - name: 账户名称。
    ///   - lastFourDigits: 卡号后四位。
    ///   - balance: 当前余额或欠款。
    ///   - currencyCode: ISO 货币代码。
    ///   - locale: 文案与金额使用的语言环境。
    ///   - isDefault: 是否为默认记账账户。
    /// - Returns: 账户行展示数据。
    static func row(
        id: UUID,
        accountType: AccountType?,
        templateID: String?,
        name: String,
        lastFourDigits: String?,
        balance: Decimal,
        currencyCode: String,
        locale: Locale = .current,
        isDefault: Bool = false
    ) -> AccountRowPresentation {
        let template = template(id: templateID, accountType: accountType)
        let typeTitle = accountType?.title(locale: locale)
            ?? AccountLocalization.string("account.type.unknown.title", locale: locale)
        let amountLabel = accountType?.amountLabel(locale: locale)
            ?? AccountLocalization.string("account.amount.value", locale: locale)
        let formattedAmount = currencyAmount(
            balance,
            currencyCode: currencyCode,
            locale: locale
        )
        let detail: String
        if let suffix = lastFourDigits {
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
            id: id,
            name: accountType?.showsEditableName == false
                ? (template?.name(locale: locale) ?? name)
                : name,
            detail: detail,
            formattedAmount: formattedAmount,
            amountLabel: amountLabel,
            amountAccessibilityLabel: accessibilityLabel,
            isDefault: isDefault,
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
    @Environment(\.calendar) private var calendar
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 语音记账共享状态；预览中没有注入时为 nil。
    @Environment(VoiceBookkeepingState.self) private var voice: VoiceBookkeepingState?
    @Query private var queriedAccounts: [Account]
    @Query private var preferences: [BookkeepingPreference]
    @State private var isPresentingCreation = false
    @State private var isPresentingManagement = false
    @State private var isPresentingDeactivated = false
    /// 正在填写的转账；为空时不显示转账表单。
    @State private var transferDraft: TransferDraft?
    /// 账户列表当前是否显示在屏幕上；切到别的 Tab 或进入详情时不播放语音改动提示。
    @State private var isVisible = false
    /// 正在播放的语音改动提示；到期后清除。
    @State private var voiceMark: AccountListVoiceMark?

    /// 语音改动提示从出现到笔迹淡出所需的总时长，之后清除标记。
    private static let voiceMarkLifetime: Duration = .milliseconds(4000)

    var body: some View {
        let accounts = AccountListPresentation.sorted(queriedAccounts)

        Group {
            if AccountListState.showsInlineAdd(accountCount: accounts.count) {
                emptyContent
            } else {
                accountList(accounts)
            }
        }
        .navigationTitle(AccountLocalization.string("account.list.title", locale: locale))
        .toolbar {
            // 至少两个可记账账户才有转账的意义。
            if TransferView.transferableAccounts(queriedAccounts).count >= 2 {
                ToolbarItem(placement: .primaryAction) {
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
            }
            if AccountListState.showsToolbarAdd(accountCount: accounts.count) {
                ToolbarItem(placement: .primaryAction) {
                    addButton(identifier: "account-list-toolbar-add")
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    isPresentingManagement = true
                } label: {
                    Label(
                        AccountLocalization.string("account.management.title", locale: locale),
                        systemImage: "gearshape"
                    )
                }
                .accessibilityIdentifier("account-list-management")
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
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

    /// 从账户列表发起转账时预选的转出账户：有默认记账账户时用它，否则先不选。
    private var defaultTransferSourceID: UUID? {
        BookkeepingPreference.resolvedAccountID(
            preference: preferences.first { $0.id == BookkeepingPreference.singletonID },
            accounts: queriedAccounts
        )
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
                if queriedAccounts.contains(where: { !$0.isActive }) {
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

    /// 非空状态下使用原生 SwiftUI List 展示账户；汇总是手绘方框，账户行直接写在纸面上。
    private func accountList(_ accounts: [Account]) -> some View {
        let summary = AccountSummaryPresentation.summary(for: accounts, locale: locale)
        let defaultAccountID = BookkeepingPreference.resolvedAccountID(
            preference: preferences.first { $0.id == BookkeepingPreference.singletonID },
            accounts: accounts
        )

        return ScrollViewReader { proxy in
            List {
                AccountSummaryCard(presentation: summary)
                    .listRowInsets(
                        EdgeInsets(top: 12, leading: 2, bottom: 8, trailing: 2)
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                Section {
                    ForEach(accounts) { account in
                        let presentation = AccountListPresentation.row(
                            for: account,
                            locale: locale,
                            isDefault: account.id == defaultAccountID
                        )
                        NavigationLink(value: AccountsRoute.detail(account.id)) {
                            AccountListRow(
                                presentation: presentation,
                                voiceMarkToken: voiceMark.flatMap { $0.accountIDs.contains(account.id) ? $0.token : nil }
                            )
                        }
                        .navigationLinkIndicatorVisibility(.hidden)
                        .ledgerRow(
                            seed: account.id.handDrawnSeed,
                            showsRule: account.id != accounts.last?.id
                        )
                        .accessibilityIdentifier("account-list-row-\(account.id.uuidString)")
                        .id(account.id)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .onChange(of: voiceMark) { _, mark in
                guard let mark, let first = accounts.first(where: { mark.accountIDs.contains($0.id) }) else { return }
                // 会话卡片压在列表下半部分，把账户滚到偏上的位置；列表一屏放得下时不会移动
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
                    proxy.scrollTo(first.id, anchor: UnitPoint(x: 0.5, y: 0.2))
                }
            }
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

/// 账户列表顶部的资产汇总卡片，突出净资产并并列展示资产和负债；首次引导的示例也用它。
struct AccountSummaryCard: View {
    @Environment(\.locale) private var locale

    /// 用户选择的启动页面；账户页是启动页时汇总卡片才带装饰。
    @AppStorage(AppStartPage.storageKey) private var startPage: AppStartPage = .home

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
                    .font(.system(.largeTitle, design: .serif, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }

            HStack(alignment: .top, spacing: 16) {
                AccountSummaryMetric(
                    title: AccountLocalization.string("account.summary.assets", locale: locale),
                    amount: presentation.formattedAssets
                )

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
        .background {
            // 框内铺纸色，启动页装饰的垫纸只从框的右下边缘露出来。
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(.paperBackground))
            HandDrawnBox(cornerRadius: 22, seed: 21)
                .stroke(
                    Color.primary.opacity(0.85),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                )
        }
        .startPageDecoration(isEnabled: startPage == .accounts, cornerRadius: 22, seed: 21)
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
                .font(.system(.title3, design: .serif, weight: .medium))
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
        .modelContainer(
            for: [Account.self, AccountTransaction.self, BookkeepingPreference.self],
            inMemory: true
        )
}
