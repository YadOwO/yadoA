import SwiftData
import SwiftUI

/// “我的 › 订阅”：顶部是每月合计和按分类的饼图，下面按下次扣费排列全部订阅。
struct UserSubscriptionListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.locale) private var locale
    @Environment(\.ledgerCurrencyCode) private var ledgerCurrencyCode
    @Environment(\.calendar) private var calendar
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Query private var subscriptions: [UserSubscription]
    @Query private var rules: [RecurringRule]

    /// 正在打开的新建或编辑页。
    @State private var editSeed: UserSubscriptionEditSeed?

    /// 等待确认删除的订阅。
    @State private var deletionCandidate: UserSubscriptionRowPresentation?

    /// 是否显示删除确认。
    @State private var isDeleteConfirmationPresented = false

    /// 最近一次操作是否失败。
    @State private var isOperationFailed = false

    var body: some View {
        let today = TransactionDay.encode(.now, calendar: calendar)
        let rows = UserSubscriptionListPresentation.rows(
            subscriptions: subscriptions,
            existingRuleIDs: Set(rules.map(\.id)),
            today: today,
            ledgerCurrencyCode: ledgerCurrencyCode,
            locale: locale,
            calendar: calendar
        )
        let summary = UserSubscriptionListPresentation.summary(subscriptions: subscriptions, today: today, locale: locale)
        Group {
            if rows.isEmpty {
                emptyState
            } else {
                list(rows, summary: summary)
            }
        }
        .paperPage()
        .navigationTitle(text("subscription.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editSeed = .new()
                } label: {
                    Label(text("subscription.add"), systemImage: "plus")
                }
                .accessibilityIdentifier("subscription-add")
            }
        }
        .sheet(item: $editSeed) { seed in
            NavigationStack {
                UserSubscriptionEditView(seed: seed, calendar: calendar)
            }
        }
        .confirmationDialog(
            text("subscription.delete.title"),
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible,
            presenting: deletionCandidate
        ) { row in
            UserSubscriptionDeleteDialog.actions(hasAutoBookkeeping: row.hasAutoBookkeeping, locale: locale) { deletesRule in
                delete(row.id, deletesRule: deletesRule)
            }
        } message: { row in
            Text(text(row.hasAutoBookkeeping ? "subscription.delete.message.linked" : "subscription.delete.message"))
        }
        .alert(text("subscription.operation_failed"), isPresented: $isOperationFailed) {
            Button(text("common.close"), role: .cancel) {}
        }
    }

    /// 合计、饼图和订阅列表。
    private func list(_ rows: [UserSubscriptionRowPresentation], summary: UserSubscriptionSummary?) -> some View {
        List {
            if let summary {
                Section {
                    summaryView(summary)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 2, bottom: 8, trailing: 2))
                } footer: {
                    Text(text("subscription.summary.footer"))
                }
            }
            Section {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    rowView(row)
                        .ledgerRow(seed: 600 + UInt64(index), showsRule: index != rows.count - 1)
                }
            }
        }
        .contentMargins(.top, 4, for: .scrollContent)
    }

    /// 每月合计：有两个以上分类时画饼图，圆心写每月合计；只有一类时只写数字。
    @ViewBuilder
    private func summaryView(_ summary: UserSubscriptionSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if summary.categoryCount >= 2 {
                ShareDonutBreakdown(
                    breakdown: summary.breakdown,
                    totalTitle: text("subscription.summary.monthly"),
                    color: color(in: summary.breakdown),
                    identifierPrefix: "subscription-breakdown"
                )
                Text(AccountLocalization.formatted(
                    "subscription.summary.yearly_line",
                    value: summary.yearlyTotal.formattedCurrency(locale: locale, currencyCode: ledgerCurrencyCode),
                    locale: locale
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityIdentifier("subscription-summary-yearly")
            } else {
                HStack(alignment: .firstTextBaseline) {
                    totalColumn(titleKey: "subscription.summary.monthly", amount: summary.monthlyTotal)
                        .accessibilityIdentifier("subscription-summary-monthly")
                    Spacer(minLength: 16)
                    totalColumn(titleKey: "subscription.summary.yearly", amount: summary.yearlyTotal)
                        .accessibilityIdentifier("subscription-summary-yearly")
                }
            }
        }
    }

    /// 一列合计：上面小标题，下面金额。
    private func totalColumn(titleKey: String, amount: Decimal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text(titleKey))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(amount.formattedCurrency(locale: locale, currencyCode: ledgerCurrencyCode))
                .font(.system(.title2, design: .serif).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .combine)
    }

    /// 饼图配色：按从大到小的位置取前三位分类色，合并项和「区分时不仅仅依赖颜色」时用灰色，与资产构成一致。
    private func color(in breakdown: CategoryBreakdownPresentation) -> @MainActor (CategoryRankingItem) -> Color {
        let colorScheme = colorScheme
        let differentiateWithoutColor = differentiateWithoutColor
        return { segment in
            guard !differentiateWithoutColor,
                  segment.id != CategoryBreakdownPresentation.remainingID,
                  let index = breakdown.segments.firstIndex(where: { $0.id == segment.id })
            else { return ChartPalette.neutral }
            return ChartPalette.color(slot: index, colorScheme: colorScheme)
        }
    }

    /// 一条订阅：点开编辑，左滑或长按删除。
    private func rowView(_ row: UserSubscriptionRowPresentation) -> some View {
        Button {
            guard let subscription = subscriptions.first(where: { $0.id == row.id }) else { return }
            editSeed = .edit(subscription, context: modelContext)
        } label: {
            UserSubscriptionRow(row: row)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // 不用 destructive 角色：它会让行先消失，而这里还要等确认，取消后行又会闪回来
            deleteButton(row)
                .tint(Color(.ledgerRed))
        }
        .contextMenu {
            deleteButton(row)
        }
        .accessibilityIdentifier("subscription-row-\(row.id.uuidString)")
    }

    /// 删除按钮，确认由页面负责。
    private func deleteButton(_ row: UserSubscriptionRowPresentation) -> some View {
        Button {
            deletionCandidate = row
            isDeleteConfirmationPresented = true
        } label: {
            Label(text("subscription.action.delete"), systemImage: "trash")
        }
    }

    /// 还没有订阅时的说明和入口。
    private var emptyState: some View {
        ContentUnavailableView {
            Label(text("subscription.empty.title"), systemImage: "creditcard")
        } description: {
            Text(text("subscription.empty.message"))
        } actions: {
            Button {
                editSeed = .new()
            } label: {
                Text(text("subscription.add"))
                    .onAccentForeground()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("subscription-empty-add")
        }
    }

    /// 删除订阅，并重排扣费提醒。
    private func delete(_ id: UUID, deletesRule: Bool) {
        do {
            try LocalUserSubscriptionRepository(container: modelContext.container).delete(id: id, deletesRule: deletesRule)
            AppHaptics.play(.selection)
            let container = modelContext.container
            Task {
                await UserSubscriptionReminderScheduler.reschedule(container: container, locale: locale, calendar: calendar)
            }
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

/// 删除订阅的确认：列表页和编辑页共用。
enum UserSubscriptionDeleteDialog {
    /// 确认里的按钮：打开了自动记账的，问一句要不要连周期记账一起删。
    ///
    /// - Parameters:
    ///   - hasAutoBookkeeping: 是否打开了自动记账。
    ///   - locale: 文案使用的语言环境。
    ///   - onDelete: 确认删除；参数表示是否同时删掉它管理的周期记账。
    @ViewBuilder
    static func actions(
        hasAutoBookkeeping: Bool,
        locale: Locale,
        onDelete: @escaping (Bool) -> Void
    ) -> some View {
        if hasAutoBookkeeping {
            Button(AccountLocalization.string("subscription.delete.with_rule", locale: locale), role: .destructive) {
                onDelete(true)
            }
            .accessibilityIdentifier("subscription-delete-with-rule")
            Button(AccountLocalization.string("subscription.delete.keep_rule", locale: locale)) {
                onDelete(false)
            }
            .accessibilityIdentifier("subscription-delete-keep-rule")
        } else {
            Button(AccountLocalization.string("subscription.action.delete", locale: locale), role: .destructive) {
                onDelete(false)
            }
            .accessibilityIdentifier("subscription-delete-confirm")
        }
        Button(AccountLocalization.string("common.cancel", locale: locale), role: .cancel) {}
    }
}

/// 一条订阅的纸面样式：与周期记账的行一致，已取消和到期的变淡。
private struct UserSubscriptionRow: View {
    @Environment(\.locale) private var locale

    /// 展示数据。
    let row: UserSubscriptionRowPresentation

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: row.symbolName)
                .font(.body.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.08), in: HandDrawnBlob(seed: row.id.handDrawnSeed))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(row.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.primary)
                    if row.hasAutoBookkeeping {
                        // 自动记账的订阅在标题后面带一个小的重复符号，读屏另外念出
                        Image(systemName: "repeat")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(AccountLocalization.string("subscription.row.auto_bookkeeping", locale: locale))
                    }
                }
                Text(row.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.formattedAmount)
                .font(.system(.body, design: .serif).monospacedDigit())
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .layoutPriority(1)
        }
        .opacity(row.isInactive ? 0.55 : 1)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
