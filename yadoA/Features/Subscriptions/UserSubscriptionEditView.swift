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
    /// - Throws: 读取周期记账失败时抛出，调用方应提示失败、不打开编辑页。
    @MainActor
    static func edit(_ subscription: UserSubscription, context: ModelContext) throws -> UserSubscriptionEditSeed {
        let rule = try subscription.recurringRuleID.map { try context.recurringRule(id: $0) } ?? nil
        return UserSubscriptionEditSeed(id: subscription.id, subscription: subscription, linkedRule: rule)
    }
}

/// 新建或编辑一条订阅。
///
/// 样式和记账页一致：一张手绘票据里只填分类、名称、金额、周期和日期；状态、扣费渠道、提醒、
/// 自动记账和备注收在「更多选项」里，新建时默认收起。
struct UserSubscriptionEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.ledgerCurrencyCode) private var ledgerCurrencyCode
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

    /// 「更多选项」是否展开；新建时收起，编辑时只有填过选填项才展开。
    @State private var showsMoreOptions: Bool

    /// 新建时是否已经把光标放进过名称，避免页面再次出现时又抢焦点。
    @State private var hasAutoFocused = false

    /// 当前正在输入的框。
    @FocusState private var focusedField: Field?

    /// 页面里的几个输入框。
    private enum Field: Hashable {
        /// 名称。
        case name

        /// 金额。
        case amount

        /// 备注。
        case note
    }

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
            // 选填项都还是默认值时收起，打开编辑页和新建一样清爽
            _showsMoreOptions = State(
                initialValue: status != .active
                    || subscription.channel != .appStore
                    || subscription.reminderDaysBefore != nil
                    || seed.linkedRule != nil
                    || !(subscription.note ?? "").isEmpty
            )
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
            _showsMoreOptions = State(initialValue: false)
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

    /// 可以记账的账户：按账户页的顺序，数据库里已有的「不关联账户」排在最后；币种和账本不同的账户不能记。
    ///
    /// 「不关联账户」要到记账或选账户时才懒创建，还没建的不在这个列表里，由菜单补一行。
    private var bookkeepingAccounts: [Account] {
        let order = AccountDisplayOrder(preferences: preferences)
        let sorted = AccountListPresentation.sorted(accounts, order: order)
            .filter { $0.acceptsBookkeepingEntries(ledgerCurrencyCode: ledgerCurrencyCode) }
        return sorted + accounts.filter {
            $0.isUnlinked && $0.acceptsBookkeepingEntries(ledgerCurrencyCode: ledgerCurrencyCode)
        }
    }

    /// 这个账户标识能不能作为自动记账的账户。
    ///
    /// 「不关联账户」没建也能选，保存订阅时再建；其他账户必须在可记账账户里。
    /// - Parameter id: 当前选中的账户标识。
    /// - Returns: 标识为 `nil` 时为 `false`。
    private func isSelectableBookkeepingAccount(_ id: UUID?) -> Bool {
        guard let id else { return false }
        if id == Account.unlinkedID { return true }
        return bookkeepingAccounts.contains { $0.id == id }
    }

    /// 金额输入允许的小数位，按账本币种（日元、韩元没有小数）。
    private var amountFractionDigits: Int {
        BookkeepingCurrency.inputFractionDigits(for: ledgerCurrencyCode)
    }

    /// 输入框里的金额；不合法时为 `nil`。
    ///
    /// 按存储精度（两位小数）解析，而不是按账本币种的小数位：账本换成日元、韩元后，
    /// 带小数的旧订阅金额不改动时仍然合法，其他字段才能照常保存。新输入由金额框的 `onChange`
    /// 按账本币种限制小数位，无小数币种里一按键就会丢掉旧金额的小数，只有不动金额时才原样保留。
    private var amount: Decimal? {
        AccountAmountParser.amount(from: amountText, locale: locale, fractionDigits: 2)
            .flatMap { $0 > 0 ? $0 : nil }
    }

    /// 去掉首尾空白的名称。
    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 订阅的状态、周期、分类或扣费渠道是这一版不认识的值（来自更新版本）：只展示，不允许修改，避免保存时被悄悄改写。
    private var isFromNewerVersion: Bool {
        seed.subscription?.isFromNewerVersion ?? false
    }

    /// 名称、金额合法，自动记账选好了账户和分类时才能保存；来自更新版本的订阅不能保存。
    private var canSave: Bool {
        guard !isFromNewerVersion else { return false }
        guard !trimmedName.isEmpty,
              trimmedName.count <= LocalUserSubscriptionRepository.nameLengthLimit,
              amount != nil
        else { return false }
        guard isBookkeepingOn, !isBookkeepingLocked else { return true }
        return isSelectableBookkeepingAccount(bookkeepingAccountID)
            && catalog.items(for: .expense).contains { $0.key == bookkeepingCategoryKey }
    }

    /// 已取消、原来又没在自动记账时，不能新打开自动记账。
    private var isBookkeepingLocked: Bool {
        status == .cancelled && !wasLinked
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if isFromNewerVersion {
                    footnote(text("subscription.edit.newerVersion"))
                }
                slip
                if status == .trial {
                    footnote(text("subscription.edit.trial.footer"))
                }
                moreOptions
                if !isNew {
                    deleteButton
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            submitBar
        }
        .paperPage()
        .navigationTitle(text(isNew ? "subscription.edit.title.new" : "subscription.edit.title.edit"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(text("common.cancel"), systemImage: "xmark") { dismiss() }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(text("common.done")) { focusedField = nil }
            }
        }
        .task {
            // 新建时直接把光标放进名称，填完名称和金额就能保存
            guard isNew, !hasAutoFocused else { return }
            hasAutoFocused = true
            focusedField = .name
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

    // MARK: - 票据

    /// 和记账页同样的一张手绘票据：分类、名称、金额和周期在上，日期写在下面。
    ///
    /// 添加一条订阅只需要填这里；状态、渠道、提醒这些收在「更多选项」里。
    private var slip: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                categoryMenu
                nameField
                amountField
                HandDrawnRule(seed: 61)
                    .stroke(Color.primary.opacity(0.6), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                    .frame(height: 3)
                    .accessibilityHidden(true)
                frequencyChoice
            }
            .padding(.bottom, 8)
            fieldRule(seed: 63)
            dateRow
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .ledgerFormBorder(seed: 131)
    }

    /// 票据顶部的分类：图标垫一块淡淡的墨色，点开在固定的几个分类里选。
    private var categoryMenu: some View {
        Menu {
            Picker(text("subscription.edit.category"), selection: $category) {
                ForEach(UserSubscriptionCategory.allCases) { option in
                    Label(text(option.titleKey), systemImage: option.symbolName).tag(option)
                }
            }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: category.symbolName)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.tint)
                    .frame(width: 52, height: 52)
                    .background {
                        HandDrawnBlob(seed: category.rawValue.handDrawnSeed)
                            .fill(Color.accentColor.opacity(0.08))
                    }
                HStack(spacing: 6) {
                    Text(text(category.titleKey))
                        .font(.system(.headline, design: .serif))
                        .foregroundStyle(Color.primary)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(text("subscription.edit.category"))
        .accessibilityValue(text(category.titleKey))
        .accessibilityIdentifier("subscription-edit-category")
    }

    /// 订阅名称，居中写在分类下面。
    private var nameField: some View {
        TextField(
            text("subscription.edit.name"),
            text: $name,
            prompt: Text(text("subscription.edit.name.placeholder"))
        )
        .font(.system(.title3, design: .serif))
        .multilineTextAlignment(.center)
        .focused($focusedField, equals: .name)
        .submitLabel(.next)
        .onSubmit { focusedField = .amount }
        .frame(minHeight: 44)
        .accessibilityIdentifier("subscription-edit-name")
    }

    /// 每期金额：和记账页一样的大号衬线数字，写在一条手绘横线上。
    private var amountField: some View {
        TextField(
            text("subscription.edit.amount"),
            text: $amountText,
            prompt: Text(verbatim: "0")
        )
        .font(.system(.largeTitle, design: .serif, weight: .medium))
        .monospacedDigit()
        .keyboardType(.decimalPad)
        .focused($focusedField, equals: .amount)
        .multilineTextAlignment(.center)
        .minimumScaleFactor(0.55)
        .lineLimit(1)
        .frame(maxWidth: .infinity, minHeight: 56)
        .accessibilityIdentifier("subscription-edit-amount")
        .onChange(of: amountText) { oldValue, newValue in
            // 只接受不超过账本币种小数位的非负数字，其余输入原样退回；
            // 没有小数的币种遇到旧金额的小数点时丢掉小数部分，旧金额才能一位位删掉
            guard !newValue.isEmpty else { return }
            let separator = locale.decimalSeparator ?? "."
            guard let normalized = AccountAmountParser.normalizedLiveAmountText(
                newValue, decimalSeparator: separator, fractionDigits: amountFractionDigits
            ) else {
                amountText = oldValue
                return
            }
            if amountFractionDigits == 0,
               normalized != AccountAmountParser.canonicalized(newValue, decimalSeparator: separator) {
                amountText = normalized
            }
        }
    }

    /// 金额下面手写的扣费周期；放不下（如英文、大字号）时换成下拉菜单。
    private var frequencyChoice: some View {
        ViewThatFits(in: .horizontal) {
            LedgerSwitch(
                label: text("subscription.edit.frequency"),
                selection: $frequency,
                options: frequencyOptions.map { option in
                    LedgerSwitch<RecurringFrequency>.Option(
                        value: option,
                        title: text(option.titleKey),
                        identifier: "subscription-edit-frequency-\(option.rawValue)"
                    )
                },
                size: .compact
            )
            Menu {
                Picker(text("subscription.edit.frequency"), selection: $frequency) {
                    ForEach(frequencyOptions) { option in
                        Text(text(option.titleKey)).tag(option)
                    }
                }
            } label: {
                menuLabel(text(frequency.titleKey))
                    .frame(minHeight: 44)
            }
            .accessibilityLabel(text("subscription.edit.frequency"))
            .accessibilityIdentifier("subscription-edit-frequency")
        }
        .frame(maxWidth: .infinity)
    }

    /// 可选的周期；同步来的其他频率也放进去，保存前不会被悄悄改掉。
    private var frequencyOptions: [RecurringFrequency] {
        UserSubscriptionSchedule.cycles.contains(frequency)
            ? UserSubscriptionSchedule.cycles
            : UserSubscriptionSchedule.cycles + [frequency]
    }

    /// 日期一行：订阅中是下次扣费，试用中是试用结束，已取消是还能用到哪天。
    @ViewBuilder
    private var dateRow: some View {
        switch status {
        case .active, .trial:
            DatePicker(selection: $chargeDate, in: today..., displayedComponents: .date) {
                Text(text(status == .trial ? "subscription.edit.trial_end" : "subscription.edit.next_charge"))
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 50)
            .accessibilityIdentifier("subscription-edit-charge-date")
        case .cancelled:
            DatePicker(selection: $accessEndDate, displayedComponents: .date) {
                Text(text("subscription.edit.access_end"))
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 50)
            .accessibilityIdentifier("subscription-edit-access-end")
        }
    }

    // MARK: - 更多选项

    /// 收起来的选填项：状态、扣费渠道、提醒、自动记账和备注，点开才显示。
    private var moreOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                focusedField = nil
                withAnimation(.snappy(duration: 0.25)) { showsMoreOptions.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(text("subscription.edit.more"))
                    Image(systemName: showsMoreOptions ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .padding(.horizontal, 4)
            .accessibilityIdentifier("subscription-edit-more")

            if showsMoreOptions {
                LedgerCard(seed: 132) {
                    statusRow
                    pickerRow(
                        "subscription.edit.channel",
                        selection: $channel,
                        current: text(channel.titleKey),
                        identifier: "subscription-edit-channel"
                    ) {
                        ForEach(UserSubscriptionChannel.allCases) { option in
                            Text(text(option.titleKey)).tag(option)
                        }
                    }
                    if !isNew, channel == .appStore, let url = UserSubscriptionChannel.appStoreManagementURL {
                        Link(destination: url) {
                            Label(text("subscription.edit.manage_app_store"), systemImage: "arrow.up.forward.app")
                                .foregroundStyle(.tint)
                                .ledgerCardRow()
                        }
                        .accessibilityIdentifier("subscription-edit-manage-app-store")
                    }
                    if status != .cancelled {
                        pickerRow(
                            "subscription.edit.reminder",
                            selection: $reminderDaysBefore,
                            current: reminderDaysBefore.map(reminderTitle) ?? text("subscription.reminder.option.none"),
                            identifier: "subscription-edit-reminder"
                        ) {
                            Text(text("subscription.reminder.option.none")).tag(Int?.none)
                            ForEach(reminderOptions, id: \.self) { days in
                                Text(reminderTitle(days)).tag(Int?.some(days))
                            }
                        }
                    }
                    bookkeepingRows
                    LedgerFormRow(title: text("subscription.edit.note")) {
                        TextField(
                            text("subscription.edit.note"),
                            text: $note,
                            prompt: Text(text("common.optional")),
                            axis: .vertical
                        )
                        .lineLimit(1...4)
                        .focused($focusedField, equals: .note)
                        .accessibilityIdentifier("subscription-edit-note")
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))

                if let bookkeepingFooterKey {
                    footnote(text(bookkeepingFooterKey))
                }
            }
        }
    }

    /// 状态：三个词手写并排；放不下时换成下拉菜单。
    private var statusRow: some View {
        LedgerFormRow(title: text("subscription.edit.status")) {
            ViewThatFits(in: .horizontal) {
                LedgerSwitch(
                    label: text("subscription.edit.status"),
                    selection: $status,
                    options: UserSubscriptionStatus.allCases.map { option in
                        LedgerSwitch<UserSubscriptionStatus>.Option(
                            value: option,
                            title: text(option.titleKey),
                            identifier: "subscription-edit-status-\(option.rawValue)"
                        )
                    },
                    size: .compact
                )
                Menu {
                    Picker(text("subscription.edit.status"), selection: $status) {
                        ForEach(UserSubscriptionStatus.allCases) { option in
                            Text(text(option.titleKey)).tag(option)
                        }
                    }
                } label: {
                    menuLabel(text(status.titleKey))
                }
                .accessibilityIdentifier("subscription-edit-status")
            }
        }
    }

    /// 自动记账开关；打开后多出记入账户和支出分类两行。
    @ViewBuilder
    private var bookkeepingRows: some View {
        Toggle(isOn: bookkeepingBinding) {
            Text(text("subscription.edit.bookkeeping"))
                .foregroundStyle(.secondary)
        }
        .disabled(isBookkeepingLocked)
        .ledgerCardRow()
        .accessibilityIdentifier("subscription-edit-bookkeeping")
        if isBookkeepingOn, !isBookkeepingLocked {
            pickerRow(
                "subscription.edit.bookkeeping.account",
                selection: $bookkeepingAccountID,
                current: bookkeepingAccounts.first { $0.id == bookkeepingAccountID }?.localizedName(locale: locale)
                    ?? (bookkeepingAccountID == Account.unlinkedID
                        ? AccountLocalization.string("account.unlinked.name", locale: locale)
                        : text("subscription.edit.choose")),
                identifier: "subscription-edit-bookkeeping-account"
            ) {
                if !isSelectableBookkeepingAccount(bookkeepingAccountID) {
                    Text(text("subscription.edit.choose")).tag(UUID?.none)
                }
                ForEach(bookkeepingAccounts) { account in
                    Text(account.localizedName(locale: locale)).tag(Optional(account.id))
                }
                // 「不关联账户」还没建时补一行，选中后保存订阅时再建
                if !bookkeepingAccounts.contains(where: { $0.id == Account.unlinkedID }) {
                    Text(AccountLocalization.string("account.unlinked.name", locale: locale))
                        .tag(Optional(Account.unlinkedID))
                }
            }
            let items = catalog.items(for: .expense)
            pickerRow(
                "subscription.edit.bookkeeping.category",
                selection: $bookkeepingCategoryKey,
                current: items.first { $0.key == bookkeepingCategoryKey }?.title(locale: locale)
                    ?? text("subscription.edit.choose"),
                identifier: "subscription-edit-bookkeeping-category"
            ) {
                if !items.contains(where: { $0.key == bookkeepingCategoryKey }) {
                    Text(text("subscription.edit.choose")).tag(String?.none)
                }
                ForEach(items, id: \.key) { item in
                    Label(item.title(locale: locale), systemImage: item.symbolName).tag(Optional(item.key))
                }
            }
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

    /// 自动记账的说明：只在打开了自动记账、或者因为已取消而有特别规则时才显示。
    private var bookkeepingFooterKey: String? {
        if isBookkeepingLocked { return "subscription.edit.bookkeeping.cancelled_footer" }
        guard isBookkeepingOn else { return nil }
        if status == .cancelled { return "subscription.edit.bookkeeping.stops_footer" }
        return "subscription.edit.bookkeeping.footer"
    }

    // MARK: - 票据之外

    /// 编辑时页面最下面的删除入口，用账本红的文字，不做成大按钮。
    private var deleteButton: some View {
        Button(role: .destructive) {
            focusedField = nil
            isDeleteConfirmationPresented = true
        } label: {
            Label(text("subscription.edit.delete"), systemImage: "trash")
                .foregroundStyle(Color(.ledgerRed))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("subscription-edit-delete")
    }

    /// 页面底部始终可见的保存按钮；键盘弹出时跟在键盘上方。
    private var submitBar: some View {
        LedgerSubmitButton(title: text("common.save"), isSaving: false) {
            focusedField = nil
            save()
        }
        .disabled(!canSave)
        .accessibilityIdentifier("subscription-edit-save")
        .ledgerBottomBar()
    }

    // MARK: - 小部件

    /// 卡片里"名称 — 下拉菜单"的一行。
    ///
    /// - Parameters:
    ///   - titleKey: 左边项目名的本地化键，也用作菜单标题。
    ///   - selection: 菜单选中的值。
    ///   - current: 右边显示的当前选项名称。
    ///   - identifier: 自动化标识。
    ///   - content: 菜单里的各个选项。
    private func pickerRow<Value: Hashable, Content: View>(
        _ titleKey: String,
        selection: Binding<Value>,
        current: String,
        identifier: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        LedgerFormRow(title: text(titleKey)) {
            Menu {
                Picker(text(titleKey), selection: selection) {
                    content()
                }
            } label: {
                menuLabel(current)
            }
            .accessibilityIdentifier(identifier)
        }
    }

    /// 下拉菜单的外观：墨色的当前选项加一个上下箭头。
    private func menuLabel(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .foregroundStyle(Color.primary)
            Image(systemName: "chevron.up.chevron.down")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }

    /// 卡片下方的一段灰色小字说明。
    private func footnote(_ content: String) -> some View {
        Text(content)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    /// 票据里两行之间的手绘细线。
    private func fieldRule(seed: UInt64) -> some View {
        HandDrawnRule(seed: seed)
            .stroke(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            .frame(height: 3)
            .accessibilityHidden(true)
    }

    /// 自动记账开关：打开时预选默认记账账户和按订阅分类建议的支出分类。
    private var bookkeepingBinding: Binding<Bool> {
        Binding(
            get: { isBookkeepingOn && !isBookkeepingLocked },
            set: { isOn in
                isBookkeepingOn = isOn
                guard isOn else { return }
                if !isSelectableBookkeepingAccount(bookkeepingAccountID) {
                    let preference = preferences.first { $0.id == BookkeepingPreference.singletonID }
                    let defaultID = BookkeepingPreference.resolvedAccountID(preference: preference, accounts: accounts)
                    bookkeepingAccountID = bookkeepingAccounts.first { $0.id == defaultID }?.id
                        ?? bookkeepingAccounts.first?.id
                        ?? Account.unlinkedID
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
            // 选的是还没建的「不关联账户」时先建好，周期记账列表才找得到它；失败时什么都不保存
            if bookkeeping?.accountID == Account.unlinkedID {
                try LocalAccountRepository(container: container).ensureUnlinkedAccount(locale: locale)
            }
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
