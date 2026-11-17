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
        .toolbar {
            // 至少两个可记账账户才有转账的意义。
            if TransferView.transferableAccounts(queriedAccounts, order: order).count >= 2 {
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
            // 添加账户和账户管理收进同一个「更多」菜单，右上角最多两个按钮。
            ToolbarItem(placement: .primaryAction) {
                moreMenu(showsAdd: AccountListState.showsToolbarAdd(accountCount: accounts.count))
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
            preference: BookkeepingPreference.canonical(in: preferences),
            accounts: queriedAccounts
        )
    }

    /// 右上角的「更多」菜单：有账户时提供添加账户，始终提供账户管理。
    ///
    /// 系统菜单不保留菜单项的 identifier，UI 测试按菜单项标题查找。
    /// - Parameter showsAdd: 是否提供添加账户；没有账户时添加入口在页面中间。
    private func moreMenu(showsAdd: Bool) -> some View {
        Menu {
            if showsAdd {
                addButton(identifier: "account-list-toolbar-add")
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

    /// 非空状态下使用原生 SwiftUI List 展示账户；汇总是手绘方框，账户按分类分段直接写在纸面上。
    ///
    /// - Parameters:
    ///   - accounts: 按统一顺序排好的启用账户。
    ///   - sections: 同一批账户按分类分好的组。
    private func accountList(_ accounts: [Account], sections: [AccountTypeSection]) -> some View {
        let summary = AccountSummaryPresentation.summary(for: accounts, locale: locale)
        let defaultAccountID = BookkeepingPreference.resolvedAccountID(
            preference: BookkeepingPreference.canonical(in: preferences),
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

                ForEach(sections) { section in
                    Section {
                        ForEach(section.accounts) { account in
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
