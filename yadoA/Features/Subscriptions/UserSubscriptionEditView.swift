import SwiftData
import SwiftUI

/// 打开订阅编辑页时带的内容。
struct UserSubscriptionEditSeed: Identifiable {
    /// 订阅 UUID；新建时是新生成的。
    let id: UUID

    /// 要编辑的订阅；新建时为 `nil`。
    let subscription: UserSubscription?

    /// 订阅当前管理的周期记账规则；没打开自动记账或规则已被删掉时为 `nil`。
    let linkedRule: RecurringRule?

    /// 新建一条订阅。
    static func new() -> UserSubscriptionEditSeed {
        UserSubscriptionEditSeed(id: UUID(), subscription: nil, linkedRule: nil)
    }

    /// 编辑一条已有订阅。
    ///
    /// - Parameters:
    ///   - subscription: 要编辑的订阅。
    ///   - context: 读取它管理的周期记账规则使用的 context。
    /// - Returns: 编辑内容。
    @MainActor
    static func edit(_ subscription: UserSubscription, context: ModelContext) -> UserSubscriptionEditSeed {
        let rule = subscription.recurringRuleID.flatMap { try? context.recurringRule(id: $0) }
        return UserSubscriptionEditSeed(id: subscription.id, subscription: subscription, linkedRule: rule)
    }
}

/// 新建或编辑一条订阅：名称、价格、周期、日期、分类、扣费渠道、状态、扣费提醒和自动记账。
struct UserSubscriptionEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Query private var accounts: [Account]
    @Query private var categories: [BookkeepingCategory]
    @Query private var preferences: [BookkeepingPreference]

    /// 打开时带的内容。
    private let seed: UserSubscriptionEditSeed

    /// 日期运算使用的日历。
    private let calendar: Calendar

    /// 打开时今天的日期，作为日期选择的下限。
    private let today: Date

    /// 名称。
    @State private var name: String

    /// 金额输入框的文字，使用当前语言的小数点。
    @State private var amountText: String

    /// 扣费周期。
    @State private var frequency: RecurringFrequency

    /// 订阅中是下一次扣费日，试用中是试用结束日。
    @State private var chargeDate: Date

    /// 分类。
    @State private var category: UserSubscriptionCategory

    /// 扣费渠道。
    @State private var channel: UserSubscriptionChannel

    /// 状态。
    @State private var status: UserSubscriptionStatus

    /// 已取消时还能用到的那天。
    @State private var accessEndDate: Date

    /// 提前几天提醒扣费；为空表示不提醒。
    @State private var reminderDaysBefore: Int?

    /// 备注。
    @State private var note: String

    /// 是否自动记账。
    @State private var isBookkeepingOn: Bool

    /// 自动记账记入的账户。
    @State private var bookkeepingAccountID: UUID?

    /// 自动记账用的支出分类。
    @State private var bookkeepingCategoryKey: String?

    /// 关掉自动记账后保存时，问保留还是删掉原来的周期记账。
    @State private var isUnlinkChoicePresented = false

    /// 是否显示删除确认。
    @State private var isDeleteConfirmationPresented = false

    /// 打开提醒时通知权限被拒绝。
    @State private var isReminderDeniedPresented = false

    /// 最近一次保存或删除是否失败。
    @State private var isOperationFailed = false

    /// 创建编辑页。
    ///
    /// - Parameters:
    ///   - seed: 打开时带的内容。
    ///   - calendar: 日期运算使用的日历。
    init(seed: UserSubscriptionEditSeed, calendar: Calendar) {
        self.seed = seed
        self.calendar = calendar
        let now = Date.now
        today = calendar.startOfDay(for: now)
        let todayDay = TransactionDay.encode(now, calendar: calendar)

        if let subscription = seed.subscription {
            let chargeDay = subscription.displayedChargeDay(today: todayDay)
            let chargeDate = TransactionDay.date(from: chargeDay, calendar: calendar) ?? today
            // 试用已经过了结束日的，按订阅中显示
            var status = subscription.status ?? .active
            if status == .trial, todayDay >= subscription.anchorDay { status = .active }
            let accessEndDay = subscription.accessEndDay
                ?? UserSubscriptionSchedule.defaultAccessEndDay(beforeChargeDay: chargeDay, calendar: calendar)
            _name = State(initialValue: subscription.name)
            _amountText = State(initialValue: Self.amountText(subscription.amount, locale: .current))
            _frequency = State(initialValue: subscription.frequency ?? .monthly)
            _chargeDate = State(initialValue: chargeDate)
            _category = State(initialValue: subscription.category)
            _channel = State(initialValue: subscription.channel)
            _status = State(initialValue: status)
            _accessEndDate = State(initialValue: TransactionDay.date(from: accessEndDay, calendar: calendar) ?? chargeDate)
            _reminderDaysBefore = State(initialValue: subscription.reminderDaysBefore)
            _note = State(initialValue: subscription.note ?? "")
        } else {
            let chargeDate = calendar.date(byAdding: .month, value: 1, to: today) ?? today
            _name = State(initialValue: "")
            _amountText = State(initialValue: "")
            _frequency = State(initialValue: .monthly)
            _chargeDate = State(initialValue: chargeDate)
            _category = State(initialValue: .other)
            _channel = State(initialValue: .appStore)
            _status = State(initialValue: .active)
            _accessEndDate = State(initialValue: calendar.date(byAdding: .day, value: -1, to: chargeDate) ?? chargeDate)
            _reminderDaysBefore = State(initialValue: nil)
            _note = State(initialValue: "")
        }
        _isBookkeepingOn = State(initialValue: seed.linkedRule != nil)
        _bookkeepingAccountID = State(initialValue: seed.linkedRule?.accountID)
        _bookkeepingCategoryKey = State(initialValue: seed.linkedRule?.categoryKey)
    }

    /// 是否在新建。
    private var isNew: Bool { seed.subscription == nil }

    /// 打开时是否在自动记账。
    private var wasLinked: Bool { seed.linkedRule != nil }

    /// 存储中的分类设置与预置默认值合并后的目录。
    private var catalog: BookkeepingCategoryCatalog {
        BookkeepingCategoryCatalog(categories: categories)
    }

    /// 可以记账的账户：按账户页的顺序，最后是「不关联账户」。
    private var bookkeepingAccounts: [Account] {
        let order = AccountDisplayOrder(preferences: preferences)
        let sorted = AccountListPresentation.sorted(accounts, order: order).filter(\.acceptsBookkeepingEntries)
        return sorted + accounts.filter { $0.isUnlinked && $0.acceptsBookkeepingEntries }
    }

    /// 输入框里的金额；不合法时为 `nil`。
    private var amount: Decimal? {
        AccountAmountParser.amount(from: amountText, locale: locale).flatMap { $0 > 0 ? $0 : nil }
    }

    /// 去掉首尾空白的名称。
    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 名称、金额合法，自动记账选好了账户和分类时才能保存。
    private var canSave: Bool {
        guard !trimmedName.isEmpty,
              trimmedName.count <= LocalUserSubscriptionRepository.nameLengthLimit,
              amount != nil
        else { return false }
        guard isBookkeepingOn, !isBookkeepingLocked else { return true }
        return bookkeepingAccounts.contains { $0.id == bookkeepingAccountID }
            && catalog.items(for: .expense).contains { $0.key == bookkeepingCategoryKey }
    }

    /// 已取消、原来又没在自动记账时，不能新打开自动记账。
    private var isBookkeepingLocked: Bool {
        status == .cancelled && !wasLinked
    }

    var body: some View {
        Form {
            basicsSection
            scheduleSection
            channelSection
            if status != .cancelled {
                reminderSection
            }
            bookkeepingSection
            Section {
                TextField(text("subscription.edit.note.placeholder"), text: $note, axis: .vertical)
                    .accessibilityIdentifier("subscription-edit-note")
            } header: {
                Text(text("subscription.edit.note"))
            }
            if !isNew {
                Section {
                    Button(text("subscription.edit.delete"), role: .destructive) {
                        isDeleteConfirmationPresented = true
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("subscription-edit-delete")
                }
            }
        }
        .paperPage()
        .navigationTitle(text(isNew ? "subscription.edit.title.new" : "subscription.edit.title.edit"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(text("common.cancel"), systemImage: "xmark") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(text("common.save"), systemImage: "checkmark") { save() }
                    .disabled(!canSave)
                    .accessibilityIdentifier("subscription-edit-save")
            }
        }
        .onChange(of: status) { _, newStatus in
            // 改成已取消时，可用日期预填为已付费周期的最后一天
            if newStatus == .cancelled {
                let chargeDay = TransactionDay.encode(chargeDate, calendar: calendar)
                let accessEndDay = UserSubscriptionSchedule.defaultAccessEndDay(beforeChargeDay: chargeDay, calendar: calendar)
                accessEndDate = TransactionDay.date(from: accessEndDay, calendar: calendar) ?? chargeDate
            }
        }
        .onChange(of: reminderDaysBefore) { oldValue, newValue in
            guard oldValue == nil, newValue != nil else { return }
            Task {
                if await !BookkeepingReminderScheduler.requestAuthorization() {
                    reminderDaysBefore = nil
                    isReminderDeniedPresented = true
                }
            }
        }
        .confirmationDialog(
            text("subscription.unlink.title"),
            isPresented: $isUnlinkChoicePresented,
            titleVisibility: .visible
        ) {
            Button(text("subscription.unlink.delete_rule"), role: .destructive) { commit(deletesRuleWhenUnlinking: true) }
                .accessibilityIdentifier("subscription-unlink-delete-rule")
            Button(text("subscription.unlink.keep_rule")) { commit(deletesRuleWhenUnlinking: false) }
                .accessibilityIdentifier("subscription-unlink-keep-rule")
            Button(text("common.cancel"), role: .cancel) {}
        } message: {
            Text(text("subscription.unlink.message"))
        }
        .confirmationDialog(
            text("subscription.delete.title"),
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            UserSubscriptionDeleteDialog.actions(hasAutoBookkeeping: wasLinked, locale: locale) { deletesRule in
                delete(deletesRule: deletesRule)
            }
        } message: {
            Text(text(wasLinked ? "subscription.delete.message.linked" : "subscription.delete.message"))
        }
        .alert(text("reminder.denied.title"), isPresented: $isReminderDeniedPresented) {
            Button(text("reminder.denied.settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button(text("common.cancel"), role: .cancel) {}
        } message: {
            Text(text("subscription.reminder.denied.message"))
        }
        .alert(text("subscription.operation_failed"), isPresented: $isOperationFailed) {
            Button(text("common.close"), role: .cancel) {}
        }
    }

    // MARK: - 分组

    /// 名称、价格、周期和分类。
    private var basicsSection: some View {
        Section {
            TextField(text("subscription.edit.name.placeholder"), text: $name)
                .accessibilityIdentifier("subscription-edit-name")
            HStack {
                Text(text("subscription.edit.amount"))
                Spacer()
                TextField(text("subscription.edit.amount.placeholder"), text: $amountText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(.body.monospacedDigit())
                    .accessibilityIdentifier("subscription-edit-amount")
                    .onChange(of: amountText) { oldValue, newValue in
                        // 只接受最多两位小数的非负数字，其余输入原样退回
                        let separator = locale.decimalSeparator ?? "."
                        if !newValue.isEmpty,
                           AccountAmountParser.normalizedCNYAmountText(newValue, decimalSeparator: separator) == nil {
                            amountText = oldValue
                        }
                    }
            }
            Picker(text("subscription.edit.frequency"), selection: $frequency) {
                ForEach(frequencyOptions) { option in
                    Text(text(option.titleKey)).tag(option)
                }
            }
            .accessibilityIdentifier("subscription-edit-frequency")
            Picker(text("subscription.edit.category"), selection: $category) {
                ForEach(UserSubscriptionCategory.allCases) { option in
                    Label(text(option.titleKey), systemImage: option.symbolName).tag(option)
                }
            }
            .accessibilityIdentifier("subscription-edit-category")
        } footer: {
            Text(text("subscription.edit.amount.footer"))
        }
    }

    /// 可选的周期；同步来的其他频率也放进去，保存前不会被悄悄改掉。
    private var frequencyOptions: [RecurringFrequency] {
        UserSubscriptionSchedule.cycles.contains(frequency)
            ? UserSubscriptionSchedule.cycles
            : UserSubscriptionSchedule.cycles + [frequency]
    }

    /// 状态和日期：订阅中填下次扣费，试用中填试用结束，已取消填还能用到哪天。
    private var scheduleSection: some View {
        Section {
            Picker(text("subscription.edit.status"), selection: $status) {
                ForEach(UserSubscriptionStatus.allCases) { option in
                    Text(text(option.titleKey)).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("subscription-edit-status")
            switch status {
            case .active, .trial:
                DatePicker(
                    text(status == .trial ? "subscription.edit.trial_end" : "subscription.edit.next_charge"),
                    selection: $chargeDate,
                    in: today...,
                    displayedComponents: .date
                )
                .accessibilityIdentifier("subscription-edit-charge-date")
            case .cancelled:
                DatePicker(
                    text("subscription.edit.access_end"),
                    selection: $accessEndDate,
                    displayedComponents: .date
                )
                .accessibilityIdentifier("subscription-edit-access-end")
            }
        } footer: {
            if status == .trial {
                Text(text("subscription.edit.trial.footer"))
            }
        }
    }

    /// 扣费渠道；App Store 扣费的给一个去系统订阅管理页的入口。
    private var channelSection: some View {
        Section {
            Picker(text("subscription.edit.channel"), selection: $channel) {
                ForEach(UserSubscriptionChannel.allCases) { option in
                    Text(text(option.titleKey)).tag(option)
                }
            }
            .accessibilityIdentifier("subscription-edit-channel")
            if channel == .appStore, let url = UserSubscriptionChannel.appStoreManagementURL {
                Link(destination: url) {
                    Label(text("subscription.edit.manage_app_store"), systemImage: "arrow.up.forward.app")
                }
                .accessibilityIdentifier("subscription-edit-manage-app-store")
            }
        }
    }

    /// 扣费前提醒。
    private var reminderSection: some View {
        Section {
            Picker(text("subscription.edit.reminder"), selection: $reminderDaysBefore) {
                Text(text("subscription.reminder.option.none")).tag(Int?.none)
                ForEach(reminderOptions, id: \.self) { days in
                    Text(reminderTitle(days)).tag(Int?.some(days))
                }
            }
            .accessibilityIdentifier("subscription-edit-reminder")
        } footer: {
            Text(text(status == .trial ? "subscription.edit.reminder.trial_footer" : "subscription.edit.reminder.footer"))
        }
    }

    /// 可选的提前天数；同步来的其他天数也放进去。
    private var reminderOptions: [Int] {
        let options = UserSubscriptionReminderOption.daysBefore
        guard let reminderDaysBefore, !options.contains(reminderDaysBefore) else { return options }
        return (options + [reminderDaysBefore]).sorted()
    }

    /// 提醒选项的名称。
    private func reminderTitle(_ days: Int) -> String {
        if UserSubscriptionReminderOption.daysBefore.contains(days) {
            return text("subscription.reminder.option.\(days)")
        }
        return String(format: text("subscription.reminder.option.other"), locale: locale, days)
    }

    /// 自动记账：打开后选账户和支出分类，由订阅管理一条周期记账。
    private var bookkeepingSection: some View {
        Section {
            Toggle(text("subscription.edit.bookkeeping"), isOn: bookkeepingBinding)
                .disabled(isBookkeepingLocked)
                .accessibilityIdentifier("subscription-edit-bookkeeping")
            if isBookkeepingOn, !isBookkeepingLocked {
                Picker(text("subscription.edit.bookkeeping.account"), selection: $bookkeepingAccountID) {
                    if !bookkeepingAccounts.contains(where: { $0.id == bookkeepingAccountID }) {
                        Text(text("subscription.edit.choose")).tag(UUID?.none)
                    }
                    ForEach(bookkeepingAccounts) { account in
                        Text(account.localizedName(locale: locale)).tag(Optional(account.id))
                    }
                }
                .accessibilityIdentifier("subscription-edit-bookkeeping-account")
                Picker(text("subscription.edit.bookkeeping.category"), selection: $bookkeepingCategoryKey) {
                    let items = catalog.items(for: .expense)
                    if !items.contains(where: { $0.key == bookkeepingCategoryKey }) {
                        Text(text("subscription.edit.choose")).tag(String?.none)
                    }
                    ForEach(items, id: \.key) { item in
                        Label(item.title(locale: locale), systemImage: item.symbolName).tag(Optional(item.key))
                    }
                }
                .accessibilityIdentifier("subscription-edit-bookkeeping-category")
            }
        } footer: {
            Text(text(bookkeepingFooterKey))
        }
    }

    /// 自动记账分组下面的说明。
    private var bookkeepingFooterKey: String {
        if isBookkeepingLocked { return "subscription.edit.bookkeeping.cancelled_footer" }
        if status == .cancelled { return "subscription.edit.bookkeeping.stops_footer" }
        return "subscription.edit.bookkeeping.footer"
    }

    /// 自动记账开关：打开时预选默认记账账户和按订阅分类建议的支出分类。
    private var bookkeepingBinding: Binding<Bool> {
        Binding(
            get: { isBookkeepingOn && !isBookkeepingLocked },
            set: { isOn in
                isBookkeepingOn = isOn
                guard isOn else { return }
                if !bookkeepingAccounts.contains(where: { $0.id == bookkeepingAccountID }) {
                    let preference = preferences.first { $0.id == BookkeepingPreference.singletonID }
                    let defaultID = BookkeepingPreference.resolvedAccountID(preference: preference, accounts: accounts)
                    bookkeepingAccountID = bookkeepingAccounts.first { $0.id == defaultID }?.id ?? bookkeepingAccounts.first?.id
                }
                if !catalog.items(for: .expense).contains(where: { $0.key == bookkeepingCategoryKey }) {
                    bookkeepingCategoryKey = category.defaultExpenseCategoryKey(in: catalog)
                }
            }
        )
    }

    // MARK: - 保存

    /// 保存；原来在自动记账、这次关掉了的，先问保留还是删掉那条周期记账。
    private func save() {
        guard canSave else { return }
        if wasLinked, !isBookkeepingOn {
            isUnlinkChoicePresented = true
            return
        }
        commit(deletesRuleWhenUnlinking: false)
    }

    /// 写入订阅；自动记账的这一期是今天的立即记入，然后重排扣费提醒并关闭页面。
    private func commit(deletesRuleWhenUnlinking: Bool) {
        guard let amount else { return }
        let todayDay = TransactionDay.encode(.now, calendar: calendar)
        var bookkeeping: UserSubscriptionBookkeeping?
        if isBookkeepingOn, !isBookkeepingLocked,
           let accountID = bookkeepingAccountID,
           let categoryKey = bookkeepingCategoryKey {
            bookkeeping = UserSubscriptionBookkeeping(accountID: accountID, categoryKey: categoryKey)
        }
        let input = UserSubscriptionInput(
            id: seed.id,
            name: name,
            amount: amount,
            frequency: frequency,
            chargeDay: TransactionDay.encode(chargeDate, calendar: calendar),
            category: category,
            channel: channel,
            status: status,
            accessEndDay: status == .cancelled ? TransactionDay.encode(accessEndDate, calendar: calendar) : nil,
            reminderDaysBefore: status == .cancelled ? nil : reminderDaysBefore,
            note: note,
            bookkeeping: bookkeeping,
            deletesRuleWhenUnlinking: deletesRuleWhenUnlinking
        )
        let container = modelContext.container
        do {
            let ruleID = try LocalUserSubscriptionRepository(container: container).save(input, today: todayDay)
            if let ruleID, status != .cancelled {
                let entries = LocalRecurringRuleRepository(container: container).generateDue(ruleID: ruleID, today: todayDay)
                for entry in entries {
                    HomeRecentEntryHighlight.shared.mark(id: entry.id, transactionDay: entry.transactionDay)
                }
            }
            AppHaptics.play(.success)
            rescheduleReminders(container: container)
            dismiss()
        } catch {
            AppHaptics.play(.error)
            isOperationFailed = true
        }
    }

    /// 删除订阅并关闭页面。
    private func delete(deletesRule: Bool) {
        let container = modelContext.container
        do {
            try LocalUserSubscriptionRepository(container: container).delete(id: seed.id, deletesRule: deletesRule)
            AppHaptics.play(.selection)
            rescheduleReminders(container: container)
            dismiss()
        } catch {
            AppHaptics.play(.error)
            isOperationFailed = true
        }
    }

    /// 页面关掉以后接着重排扣费提醒。
    private func rescheduleReminders(container: ModelContainer) {
        let locale = locale
        let calendar = calendar
        Task {
            await UserSubscriptionReminderScheduler.reschedule(container: container, locale: locale, calendar: calendar)
        }
    }

    /// 按当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }

    /// 已有金额在输入框里的写法：换成当前语言的小数点。
    private static func amountText(_ amount: Decimal, locale: Locale) -> String {
        AmountExpression.amountText(amount).replacingOccurrences(of: ".", with: locale.decimalSeparator ?? ".")
    }
}
