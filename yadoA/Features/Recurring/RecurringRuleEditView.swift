import Combine
import SwiftData
import SwiftUI

/// 打开周期记账编辑页时带的内容。
struct RecurringRuleEditSeed: Identifiable {
    /// 规则 UUID；新建时是新生成的。
    let id: UUID

    /// 预填的草稿；新建时为 `nil`，由记账流程创建以今天为下一期的空草稿。
    let draft: DiningExpenseDraft?

    /// 重复频率。
    let frequency: RecurringFrequency

    /// 结束日期的 `YYYYMMDD`。
    let endDay: Int?

    /// 新建一条规则，默认每月重复。
    static func new() -> RecurringRuleEditSeed {
        RecurringRuleEditSeed(id: UUID(), draft: nil, frequency: .monthly, endDay: nil)
    }

    /// 编辑一条已有规则；频率不认识时按每月显示，保存后改写。
    ///
    /// - Parameters:
    ///   - rule: 要编辑的规则。
    ///   - catalog: 解析另一方向默认分类使用的分类目录。
    /// - Returns: 编辑内容；规则方向不认识时为 `nil`。
    static func edit(_ rule: RecurringRule, catalog: BookkeepingCategoryCatalog) -> RecurringRuleEditSeed? {
        guard let entryType = rule.entryType else { return nil }
        return RecurringRuleEditSeed(
            id: rule.id,
            draft: DiningExpenseDraft(
                id: rule.id,
                accountID: rule.accountID,
                entryType: entryType,
                expenseCategoryKey: entryType == .expense ? rule.categoryKey : catalog.defaultKey(for: .expense),
                incomeCategoryKey: entryType == .income ? rule.categoryKey : catalog.defaultKey(for: .income),
                amountText: AmountExpression.amountText(rule.amount),
                transactionDay: rule.nextDueDay,
                note: rule.note ?? ""
            ),
            frequency: rule.frequency ?? .monthly,
            endDay: rule.endDay
        )
    }
}

/// 周期记账特有的选项；和记账草稿分开放，表单的其他部分与新增记账完全共用。
@MainActor
private final class RecurringRuleOptions: ObservableObject {
    /// 重复频率。
    @Published var frequency: RecurringFrequency

    /// 结束日期；为空表示一直重复。
    @Published var endDate: Date?

    /// 创建选项。
    init(frequency: RecurringFrequency, endDate: Date?) {
        self.frequency = frequency
        self.endDate = endDate
    }
}

/// 新建或编辑一条周期记账：票据样式与记账表单相同，日期一行是“下次记账”，下面多出重复频率和结束日期。
struct RecurringRuleEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Query private var accounts: [Account]
    @Query private var preferences: [BookkeepingPreference]
    @StateObject private var flow: DiningExpenseEntryFlow
    @StateObject private var options: RecurringRuleOptions

    /// 是否在新建。
    private let isNew: Bool

    /// 创建编辑页。
    ///
    /// - Parameters:
    ///   - seed: 打开时带的内容。
    ///   - container: 保存规则的本地财务容器。
    ///   - calendar: 把日期转成记账日使用的日历。
    init(seed: RecurringRuleEditSeed, container: ModelContainer, calendar: Calendar) {
        isNew = seed.draft == nil
        let options = RecurringRuleOptions(
            frequency: seed.frequency,
            endDate: seed.endDay.flatMap { TransactionDay.date(from: $0, calendar: calendar) }
        )
        _options = StateObject(wrappedValue: options)
        let draft = seed.draft ?? DiningExpenseDraft(
            id: seed.id,
            transactionDay: TransactionDay.encode(.now, calendar: calendar)
        )
        _flow = StateObject(
            wrappedValue: DiningExpenseEntryFlow(
                draft: draft,
                requiresCategoryConfirmation: seed.draft == nil,
                saveAction: { draft in
                    guard let input = RecurringRuleInput(
                        draft: draft,
                        frequency: options.frequency,
                        endDay: options.endDate.map { TransactionDay.encode($0, calendar: calendar) }
                    ) else { throw RecurringRuleRepositoryError.invalidInput }
                    let repository = LocalRecurringRuleRepository(container: container)
                    try repository.save(input)
                    // 下一期选了今天的，保存后立即记入，不用等下次打开 App
                    let entries = repository.generateDue(today: TransactionDay.encode(.now, calendar: calendar))
                    for entry in entries {
                        HomeRecentEntryHighlight.shared.mark(id: entry.id, transactionDay: entry.transactionDay)
                    }
                }
            )
        )
    }

    var body: some View {
        BookkeepingEntryForm(
            flow: flow,
            configuration: .recurring,
            startsWithCategorySelection: isNew,
            onSaved: { dismiss() },
            prepareInitialDraft: applyDefaultAccount,
            accessory: { recurrenceRows }
        )
        .navigationTitle(text(isNew ? "recurring.edit.title.new" : "recurring.edit.title.edit"))
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(flow.isSaving)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(text("common.cancel")) { dismiss() }
                    .disabled(flow.isSaving)
            }
        }
        // 下一期改到结束日期之后时，把结束日期跟着推后，避免出现永远不会记入的规则
        .onChange(of: flow.formTransactionDate) { _, nextDate in
            if let endDate = options.endDate, endDate < nextDate {
                options.endDate = nextDate
            }
        }
    }

    /// 重复频率和结束日期两行，接在票据的日期一行后面。
    @ViewBuilder
    private var recurrenceRows: some View {
        rule(seed: 71)
        LedgerRecurrenceRow(titleKey: "recurring.edit.frequency") {
            Menu {
                Picker(text("recurring.edit.frequency"), selection: $options.frequency) {
                    ForEach(RecurringFrequency.allCases) { frequency in
                        Text(text(frequency.titleKey)).tag(frequency)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(text(options.frequency.titleKey))
                        .foregroundStyle(Color.primary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityIdentifier("recurring-edit-frequency")
        }
        rule(seed: 72)
        Toggle(isOn: hasEndDate) {
            Text(text("recurring.edit.has_end"))
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 50)
        .accessibilityIdentifier("recurring-edit-has-end")
        if let endDate = options.endDate {
            rule(seed: 73)
            DatePicker(
                selection: Binding(get: { endDate }, set: { options.endDate = $0 }),
                in: flow.formTransactionDate...,
                displayedComponents: .date
            ) {
                Text(text("recurring.edit.end_date"))
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 50)
            .accessibilityIdentifier("recurring-edit-end-date")
        }
    }

    /// 是否设置了结束日期；打开时默认一年后。
    private var hasEndDate: Binding<Bool> {
        Binding(
            get: { options.endDate != nil },
            set: { isOn in
                options.endDate = isOn
                    ? calendar.date(byAdding: .year, value: 1, to: flow.formTransactionDate)
                    : nil
            }
        )
    }

    /// 两行之间的手绘细线。
    private func rule(seed: UInt64) -> some View {
        HandDrawnRule(seed: seed)
            .stroke(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            .frame(height: 3)
            .accessibilityHidden(true)
    }

    /// 新建时填入默认记账账户。
    private func applyDefaultAccount() {
        let preference = preferences.first { $0.id == BookkeepingPreference.singletonID }
        flow.applyInitialDefault(BookkeepingPreference.resolvedAccountID(preference: preference, accounts: accounts))
    }

    /// 按当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 票据里的一行：左边是灰色的项目名，右边是控件。
private struct LedgerRecurrenceRow<Content: View>: View {
    @Environment(\.locale) private var locale

    /// 项目名的本地化键。
    let titleKey: String

    /// 右边的控件。
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 16) {
            Text(AccountLocalization.string(titleKey, locale: locale))
                .foregroundStyle(.secondary)
            content
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(minHeight: 50)
    }
}
