import SwiftData
import SwiftUI

/// 周期记账列表里一条规则的状态。
enum RecurringRuleStatus: Equatable {
    /// 正常，到期自动记入。
    case active

    /// 账户或分类不可用，暂时不会记入。
    case unavailable

    /// 用户暂停了。
    case paused

    /// 已过结束日期。
    case finished
}

/// 周期记账列表里一行的展示数据。
struct RecurringRuleRowPresentation: Identifiable, Equatable {
    /// 规则 UUID。
    let id: UUID

    /// 主行文字：备注，没写备注时为分类名称。
    let title: String

    /// 分类图标。
    let symbolName: String

    /// 带方向的本地化金额，支出为负。
    let formattedAmount: String

    /// 副行文字：频率、下一期和账户，或不会记入的原因。
    let subtitle: String

    /// 规则状态。
    let status: RecurringRuleStatus
}

/// 把周期记账规则转换为列表展示数据。
enum RecurringRuleListPresentation {
    /// 生成列表行：正常的按下一期从近到远排在前面，其次是暂停的，已结束的放最后。
    ///
    /// - Parameters:
    ///   - rules: 全部规则。
    ///   - accounts: 当前账户快照。
    ///   - catalog: 分类目录。
    ///   - locale: 语言环境。
    ///   - calendar: 日历。
    /// - Returns: 排好序的列表行；方向未知的损坏规则跳过。
    static func rows(
        rules: [RecurringRule],
        accounts: [Account],
        catalog: BookkeepingCategoryCatalog,
        locale: Locale,
        calendar: Calendar
    ) -> [RecurringRuleRowPresentation] {
        rules
            .sorted { lhs, rhs in
                let lhsRank = rank(status(of: lhs, accounts: accounts, catalog: catalog))
                let rhsRank = rank(status(of: rhs, accounts: accounts, catalog: catalog))
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                if lhs.nextDueDay != rhs.nextDueDay { return lhs.nextDueDay < rhs.nextDueDay }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .compactMap { row(for: $0, accounts: accounts, catalog: catalog, locale: locale, calendar: calendar) }
    }

    /// 判断规则当前的状态；暂停和结束优先于不可用，因为这时本来就不会记入。
    static func status(
        of rule: RecurringRule,
        accounts: [Account],
        catalog: BookkeepingCategoryCatalog
    ) -> RecurringRuleStatus {
        if rule.isFinished { return .finished }
        if rule.pausedAt != nil { return .paused }
        let hasAccount = accounts.contains {
            $0.id == rule.accountID && $0.supportsBookkeeping && $0.currencyCode == "CNY"
        }
        let hasCategory = rule.entryType.map { direction in
            catalog.items(for: direction).contains { $0.key == rule.categoryKey }
        } ?? false
        return hasAccount && hasCategory && rule.frequency != nil ? .active : .unavailable
    }

    /// 状态的排序名次。
    private static func rank(_ status: RecurringRuleStatus) -> Int {
        switch status {
        case .active, .unavailable: 0
        case .paused: 1
        case .finished: 2
        }
    }

    /// 生成一行。
    private static func row(
        for rule: RecurringRule,
        accounts: [Account],
        catalog: BookkeepingCategoryCatalog,
        locale: Locale,
        calendar: Calendar
    ) -> RecurringRuleRowPresentation? {
        guard let entryType = rule.entryType else { return nil }
        let item = catalog.resolvedItem(direction: entryType, key: rule.categoryKey)
        let ruleStatus = status(of: rule, accounts: accounts, catalog: catalog)
        let signedAmount = entryType == .expense ? -rule.amount : rule.amount
        return RecurringRuleRowPresentation(
            id: rule.id,
            title: rule.note ?? item.title(locale: locale),
            symbolName: item.symbolName,
            formattedAmount: signedAmount.formatted(.currency(code: "CNY").locale(locale)),
            subtitle: subtitle(
                for: rule,
                status: ruleStatus,
                accountName: accounts.first { $0.id == rule.accountID }?.name,
                locale: locale,
                calendar: calendar
            ),
            status: ruleStatus
        )
    }

    /// 副行文字。
    private static func subtitle(
        for rule: RecurringRule,
        status: RecurringRuleStatus,
        accountName: String?,
        locale: Locale,
        calendar: Calendar
    ) -> String {
        func text(_ key: String) -> String {
            AccountLocalization.string(key, locale: locale)
        }
        let frequency = rule.frequency.map { text($0.titleKey) }
        var parts: [String]
        switch status {
        case .finished:
            parts = [text("recurring.status.finished")]
        case .paused:
            parts = [text("recurring.status.paused"), frequency].compactMap { $0 }
        case .unavailable:
            parts = [text("recurring.status.unavailable")]
        case .active:
            parts = [frequency].compactMap { $0 }
            if let date = TransactionDay.date(from: rule.nextDueDay, calendar: calendar, locale: locale) {
                parts.append(AccountLocalization.formatted(
                    "recurring.row.next",
                    value: BookkeepingDateFormatting.shortDate(date, locale: locale, calendar: calendar),
                    locale: locale
                ))
            }
            if let accountName { parts.append(accountName) }
        }
        return parts.joined(separator: " · ")
    }
}

/// “我的 › 周期记账”：查看、新建、修改、暂停和删除周期记账规则。
struct RecurringRuleListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Query private var rules: [RecurringRule]
    @Query private var accounts: [Account]
    @Query private var categories: [BookkeepingCategory]

    /// 正在打开的新建或编辑页。
    @State private var editSeed: RecurringRuleEditSeed?

    /// 等待确认删除的规则。
    @State private var deletionCandidate: RecurringRuleRowPresentation?

    /// 是否显示删除确认。
    @State private var isDeleteConfirmationPresented = false

    /// 最近一次操作是否失败。
    @State private var isOperationFailed = false

    /// 存储中的分类设置与预置默认值合并后的目录。
    private var catalog: BookkeepingCategoryCatalog {
        BookkeepingCategoryCatalog(categories: categories)
    }

    var body: some View {
        let rows = RecurringRuleListPresentation.rows(
            rules: rules,
            accounts: accounts,
            catalog: catalog,
            locale: locale,
            calendar: calendar
        )
        Group {
            if rows.isEmpty {
                emptyState
            } else {
                list(rows)
            }
        }
        .paperPage()
        .navigationTitle(text("recurring.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editSeed = RecurringRuleEditSeed.new()
                } label: {
                    Label(text("recurring.add"), systemImage: "plus")
                }
                .accessibilityIdentifier("recurring-add")
            }
        }
        .sheet(item: $editSeed) { seed in
            NavigationStack {
                RecurringRuleEditView(seed: seed, container: modelContext.container, calendar: calendar)
            }
        }
        .alert(
            text("recurring.delete.title"),
            isPresented: $isDeleteConfirmationPresented,
            presenting: deletionCandidate
        ) { row in
            Button(text("recurring.action.delete"), role: .destructive) {
                perform { try $0.delete(id: row.id) }
            }
            Button(text("common.cancel"), role: .cancel) {}
        } message: { _ in
            Text(text("recurring.delete.message"))
        }
        .alert(text("recurring.operation_failed"), isPresented: $isOperationFailed) {
            Button(text("common.close"), role: .cancel) {}
        }
    }

    /// 规则列表。
    private func list(_ rows: [RecurringRuleRowPresentation]) -> some View {
        List {
            Section {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    rowView(row)
                        .ledgerRow(seed: 400 + UInt64(index), showsRule: index != rows.count - 1)
                }
            } footer: {
                Text(text("recurring.list.footer"))
            }
        }
        .contentMargins(.top, 4, for: .scrollContent)
    }

    /// 一条规则：点开编辑，左滑暂停或删除，长按有同样的操作。
    private func rowView(_ row: RecurringRuleRowPresentation) -> some View {
        Button {
            guard let rule = rules.first(where: { $0.id == row.id }) else { return }
            editSeed = RecurringRuleEditSeed.edit(rule, catalog: catalog)
        } label: {
            RecurringRuleRow(row: row)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // 不用 destructive 角色：它会让行先消失，而这里还要等确认，取消后行又会闪回来
            deleteButton(row)
                .tint(Color(.ledgerRed))
            pauseButton(row)
        }
        .contextMenu {
            pauseButton(row)
            deleteButton(row)
        }
        .accessibilityIdentifier("recurring-row-\(row.id.uuidString)")
    }

    /// 暂停或恢复按钮；已结束的规则不需要。
    @ViewBuilder
    private func pauseButton(_ row: RecurringRuleRowPresentation) -> some View {
        if row.status != .finished {
            let isPaused = row.status == .paused
            Button {
                let today = TransactionDay.encode(.now, calendar: calendar)
                perform { try $0.setPaused(!isPaused, id: row.id, today: today) }
            } label: {
                Label(
                    text(isPaused ? "recurring.action.resume" : "recurring.action.pause"),
                    systemImage: isPaused ? "play" : "pause"
                )
            }
        }
    }

    /// 删除按钮，确认由页面负责。
    private func deleteButton(_ row: RecurringRuleRowPresentation) -> some View {
        Button {
            deletionCandidate = row
            isDeleteConfirmationPresented = true
        } label: {
            Label(text("recurring.action.delete"), systemImage: "trash")
        }
    }

    /// 还没有规则时的说明和入口。
    private var emptyState: some View {
        ContentUnavailableView {
            Label(text("recurring.empty.title"), systemImage: "repeat")
        } description: {
            Text(text("recurring.empty.message"))
        } actions: {
            Button {
                editSeed = RecurringRuleEditSeed.new()
            } label: {
                Text(text("recurring.add"))
                    .onAccentForeground()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("recurring-empty-add")
        }
    }

    /// 执行一次写操作并处理结果。
    private func perform(_ operation: (LocalRecurringRuleRepository) throws -> Void) {
        do {
            try operation(LocalRecurringRuleRepository(container: modelContext.container))
            AppHaptics.play(.selection)
        } catch {
            AppHaptics.play(.error)
            isOperationFailed = true
        }
    }

    /// 按当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 一条规则的纸面样式：与流水行一致，暂停和已结束的变淡，不可用的提示用账本红。
private struct RecurringRuleRow: View {
    /// 展示数据。
    let row: RecurringRuleRowPresentation

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: row.symbolName)
                .font(.body.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.08), in: HandDrawnBlob(seed: row.id.handDrawnSeed))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.primary)
                Text(row.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(row.status == .unavailable ? Color(.ledgerRed) : Color.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.formattedAmount)
                .font(.system(.body, design: .serif).monospacedDigit())
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .layoutPriority(1)
        }
        .opacity(row.status == .paused || row.status == .finished ? 0.55 : 1)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
