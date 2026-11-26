import SwiftData
import SwiftUI
import UIKit

/// “我的 › 设置”二级页面：集中放置设一次就很少再动的偏好、数据维护和退出登录。
///
/// 分组顺序为通用、隐私与安全、记账、数据、关于、账号；「清除所有数据」在「数据」分组最后一行，红色显示，点了还要二次确认。
/// 账号分组第一行进入「账号与安全」（登录方式、绑定邮箱、注销芽豆账号），第二行退出登录。
/// 「截图记账」和「重看引导」按环境开关显示，线上暂时隐藏（`AuthConfig.isScreenshotShortcutAvailable` / `isOnboardingReplayAvailable`）。
struct SettingsView: View {
    @Environment(\.locale) private var locale
    @Environment(\.ledgerCurrencyCode) private var ledgerCurrencyCode
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    /// 全局登录状态；只决定是否显示退出登录分组。
    @Environment(AuthStore.self) private var authStore
    /// 云端同步的绑定状态，退出登录时据此决定是否询问保留本机数据；预览中没有注入时为 nil。
    @Environment(SyncLifecycle.self) private var syncLifecycle: SyncLifecycle?
    /// 隐私政策同意状态；离线模式下隐藏账号分组。预览中没有注入时为 nil，按允许联网处理。
    @Environment(PrivacyAgreementStore.self) private var privacyAgreement: PrivacyAgreementStore?
    /// 应用锁状态机：开关和上锁时长只由它读写。预览中没有注入时为 nil，整个「隐私与安全」分组不显示。
    @Environment(AppLockController.self) private var appLock: AppLockController?
    /// 数据联动状态，退出登录时清掉当前账号的物品估值缓存；预览中没有注入时为 nil。
    @Environment(DataLinkStore.self) private var dataLinks: DataLinkStore?
    @Query private var accounts: [Account]
    @Query private var preferences: [BookkeepingPreference]

    /// 与首页共用金额显隐偏好，修改后立即同步。
    @AppStorage("home.summary.amountsVisible") private var areAmountsVisible = false
    /// 与窗口根部共享语言偏好，修改后立即更新界面文案。
    @AppStorage(AppLanguage.storageKey) private var language: AppLanguage = .system
    /// 与窗口根部共享外观偏好，修改后立即同步亮暗色。
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system
    /// 全局正负颜色，账单、账户、点数等页面的金额都读同一个键，修改后立即生效。
    @AppStorage(AmountColorConvention.storageKey) private var amountColors: AmountColorConvention = .regionDefault()
    /// 启动页面偏好：底部导航顺序立即更新，落点在下次冷启动时生效。
    @AppStorage(AppStartPage.storageKey) private var startPage: AppStartPage = .home
    /// 全局触感开关，所有 `appHaptic` 与 `AppHaptics.play` 都读同一个键，修改后立即生效。
    @AppStorage(AppHaptics.storageKey) private var isHapticsEnabled = true
    /// 每日记账提醒开关；只有拿到通知权限才会打开。
    @AppStorage(BookkeepingReminder.isEnabledKey) private var isReminderEnabled = false
    /// 每日记账提醒的时间，从 0 点开始的分钟数。
    @AppStorage(BookkeepingReminder.minutesKey) private var reminderMinutes = BookkeepingReminder.defaultMinutes
    /// 打开提醒时发现通知权限被拒绝。
    @State private var isReminderDeniedPresented = false
    /// 打开应用锁时发现设备没设置密码，提示先去系统设置里设置。
    @State private var isAppLockPasscodeRequiredPresented = false
    /// 默认账户选择沿用现有独立弹层流程。
    @State private var isDefaultSelectionPresented = false
    /// 记账币种选择弹层。
    @State private var isCurrencyPickerPresented = false
    /// 用户最近选的、等确认「只换符号，金额不换算」的新币种；确认框收起时保留，免得标题在收起动画里闪成空白。
    @State private var pendingCurrencyCode: String?
    /// 选了不同的币种、选择弹层收起后要弹出确认框。
    @State private var isCurrencyConfirmationQueued = false
    /// 是否弹出更换币种的确认框；要等选择弹层完全收起后再弹，所以由 `onDismiss` 置位。
    @State private var isCurrencyConfirmationPresented = false
    /// 更换币种保存失败的提示。
    @State private var isCurrencyChangeFailed = false
    /// 退出登录前的二次确认（本机数据没有同步到当前账号时）。
    @State private var isSignOutConfirmationPresented = false
    /// 退出登录时选择保留还是清除本机数据（本机数据已同步到当前账号时）。
    @State private var isSignOutChoicePresented = false
    /// 退出前处理本机数据失败的提示。
    @State private var isSignOutFailurePresented = false
    /// 正在退出登录（含退出前的最后一次同步）。
    @State private var isSigningOut = false
    /// 正在重看的首次引导，每次打开时新建、从开场重新走；不写入数据，也不触发登录和同步。
    @State private var onboardingReplay: OnboardingStore?
    /// 从“关于”分组打开的协议，在 App 内用 Safari 视图显示。
    @State private var presentedLegalDocument: LegalDocument?

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                ProfileSettingsSection("settings.section.general") {
                    pickerRow("profile.language.title", symbol: "globe", selection: $language) {
                        $0.titleLocalizationKey
                    }
                    .accessibilityIdentifier("profile-language")

                    ProfileSettingsRowDivider()

                    pickerRow("profile.appearance.title", symbol: "circle.lefthalf.filled", selection: $appearance) {
                        $0.titleLocalizationKey
                    }
                    .accessibilityIdentifier("profile-appearance")

                    ProfileSettingsRowDivider()

                    amountColorsRow
                        .accessibilityIdentifier("settings-amount-colors")

                    ProfileSettingsRowDivider()

                    pickerRow("profile.start_page.title", symbol: "house", selection: $startPage) {
                        $0.titleLocalizationKey
                    }
                    .accessibilityIdentifier("profile-start-page")

                    ProfileSettingsRowDivider()

                    Toggle(isOn: $isHapticsEnabled) {
                        Label(text("settings.haptics.title"), systemImage: "iphone.radiowaves.left.and.right")
                            .labelStyle(ProfileSettingsLabelStyle())
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    // 打开时轻轻震一下，让用户马上感受到效果
                    .appHaptic(.selection, trigger: isHapticsEnabled) { _, isOn in isOn }
                    .accessibilityIdentifier("settings-haptics")
                }

                appLockSection

                ProfileSettingsSection("profile.section.bookkeeping") {
                    Button {
                        isDefaultSelectionPresented = true
                    } label: {
                        ProfileSettingsRow(titleKey: "account.management.default.title", symbol: "star", value: defaultAccountName)
                    }
                    .accessibilityIdentifier("profile-default-account")

                    ProfileSettingsRowDivider()

                    Button {
                        isCurrencyPickerPresented = true
                    } label: {
                        ProfileSettingsRow(
                            titleKey: "settings.currency.title",
                            symbol: "dollarsign.circle",
                            value: currencyValue(for: ledgerCurrencyCode)
                        )
                    }
                    .accessibilityIdentifier("settings-ledger-currency")

                    ProfileSettingsRowDivider()

                    Toggle(isOn: $areAmountsVisible) {
                        Label(text("profile.show_amounts"), systemImage: "eye")
                            .labelStyle(ProfileSettingsLabelStyle())
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .accessibilityIdentifier("profile-show-amounts")

                    ProfileSettingsRowDivider()

                    // 线上暂时藏起截图记账的设置入口，见 `AuthConfig.isScreenshotShortcutAvailable`
                    if AuthConfig.isScreenshotShortcutAvailable {
                        NavigationLink {
                            ScreenshotShortcutSetupView()
                        } label: {
                            ProfileSettingsRow(titleKey: "shortcut.screenshot.title", symbol: "viewfinder")
                        }
                        .accessibilityIdentifier("profile-screenshot-shortcut")

                        ProfileSettingsRowDivider()
                    }

                    reminderRows
                }

                ProfileSettingsSection("profile.section.data") {
                    DataExportEntryView(container: modelContext.container)
                        .labelStyle(ProfileExportLabelStyle())

                    ProfileSettingsRowDivider()

                    DataImportEntryView(container: modelContext.container)
                        .labelStyle(ProfileExportLabelStyle())

                    DataUndoEntryView(container: modelContext.container) { ProfileSettingsRowDivider() }
                        .labelStyle(ProfileExportLabelStyle())

                    ProfileSettingsRowDivider()

                    // 清除会清空本机全部记账数据：排在分组最后、用红色，和导入导出区分开
                    DataResetEntryView(container: modelContext.container)
                        .labelStyle(ProfileExportLabelStyle(color: .red))
                }

                ProfileSettingsSection("settings.section.about") {
                    // 线上暂时藏起重看引导，见 `AuthConfig.isOnboardingReplayAvailable`
                    if AuthConfig.isOnboardingReplayAvailable {
                        Button {
                            onboardingReplay = OnboardingStore(mode: .replay)
                        } label: {
                            ProfileSettingsRow(titleKey: "settings.onboarding.replay", symbol: "leaf")
                        }
                        .accessibilityIdentifier("settings-onboarding-replay")
                    }

                    ForEach(LegalDocument.allCases) { document in
                        // 分隔线只画在两行之间：没有重看引导时，第一份协议上方不画
                        if AuthConfig.isOnboardingReplayAvailable || document != LegalDocument.allCases.first {
                            ProfileSettingsRowDivider()
                        }

                        Button {
                            presentedLegalDocument = document
                        } label: {
                            ProfileSettingsRow(titleKey: document.titleLocalizationKey, symbol: document.systemImage)
                        }
                        .accessibilityIdentifier("settings-legal-\(document.rawValue)")
                    }
                }

                // 账号与安全要读写 Logto、退出登录要撤销远端凭证，离线模式（没同意隐私政策）下都不显示；已登录用户不会因此退出。
                // 注销芽豆账号在「账号与安全」页底部
                if authStore.isAuthenticated, privacyAgreement?.allowsNetwork ?? true {
                    ProfileSettingsSection("auth.section.title") {
                        // 走路径导航（见 `ProfileRoute.accountSecurity`）：退出登录后这一行消失，页面仍留在栈里
                        NavigationLink(value: ProfileRoute.accountSecurity) {
                            ProfileSettingsRow(titleKey: "account.security.title", symbol: "lock.shield")
                        }
                        .disabled(isSigningOut)
                        .accessibilityIdentifier("settings-account-security")

                        ProfileSettingsRowDivider()

                        Button {
                            beginSignOut()
                        } label: {
                            Label(text("auth.sign_out.action"), systemImage: "rectangle.portrait.and.arrow.right")
                        }
                        .labelStyle(ProfileExportLabelStyle(color: .red))
                        .disabled(authStore.isBusy || authStore.isDeletingAccount || isSigningOut)
                        .accessibilityIdentifier("profile-sign-out")
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .paperPage()
        .navigationTitle(text("settings.title"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isDefaultSelectionPresented) {
            NavigationStack { DefaultAccountSelectionView() }
        }
        .sheet(
            isPresented: $isCurrencyPickerPresented,
            onDismiss: {
                // 选择页收起后再弹确认框，两层弹层不能同时出现
                if isCurrencyConfirmationQueued {
                    isCurrencyConfirmationQueued = false
                    isCurrencyConfirmationPresented = true
                }
            }
        ) {
            LedgerCurrencyPicker(selection: ledgerCurrencyCode) { code in
                // 选了和当前相同的币种直接关掉，什么都不改
                if code != ledgerCurrencyCode {
                    pendingCurrencyCode = code
                    isCurrencyConfirmationQueued = true
                }
                isCurrencyPickerPresented = false
            }
        }
        .alert(
            currencyConfirmationTitle,
            isPresented: $isCurrencyConfirmationPresented,
            presenting: pendingCurrencyCode
        ) { code in
            Button(text("settings.currency.confirm.action")) {
                changeCurrency(to: code)
            }
            .accessibilityIdentifier("settings-ledger-currency-confirm")

            Button(text("common.cancel"), role: .cancel) {}
        } message: { code in
            Text(String(
                format: text("settings.currency.confirm.message"),
                locale: locale,
                BookkeepingCurrency.displayName(for: code, locale: locale)
            ))
        }
        .alert(text("settings.currency.failed"), isPresented: $isCurrencyChangeFailed) {
            Button(text("common.close"), role: .cancel) {}
        }
        .legalDocumentSheet($presentedLegalDocument)
        // 用 item 呈现：同一次点击里先建状态再置 isPresented 时，封面内容会读到旧的空值而白屏
        .fullScreenCover(item: $onboardingReplay) { replay in
            OnboardingView(store: replay) {
                // 纸已经撕走或淡出，底下就是设置页，直接收起封面，不再播一遍下滑
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    onboardingReplay = nil
                }
            }
            .environment(authStore)
            // 封面透明，撕下最后一页时露出底下的设置页
            .presentationBackground(.clear)
        }
        .alert(text("auth.sign_out.confirm.title"), isPresented: $isSignOutConfirmationPresented) {
            Button(text("auth.sign_out.action"), role: .destructive) {
                Task {
                    // 必须在 signOut 之前、userID 还在时清掉这个账号的联动缓存
                    dataLinks?.clearCurrentUserCache()
                    await authStore.signOut()
                }
            }
            .accessibilityIdentifier("profile-sign-out-confirm")

            Button(text("common.cancel"), role: .cancel) {}
        } message: {
            Text(text("auth.sign_out.confirm.message"))
        }
        .confirmationDialog(
            text("auth.sign_out.choice.title"),
            isPresented: $isSignOutChoicePresented,
            titleVisibility: .visible
        ) {
            Button(text("auth.sign_out.choice.keep")) {
                Task { await signOut(.keepOnDevice) }
            }
            .accessibilityIdentifier("profile-sign-out-keep")

            Button(text("auth.sign_out.choice.erase"), role: .destructive) {
                Task { await signOut(.eraseFromDevice) }
            }
            .accessibilityIdentifier("profile-sign-out-erase")

            Button(text("common.cancel"), role: .cancel) {}
        } message: {
            Text(text("auth.sign_out.choice.message"))
        }
        .alert(text("auth.sign_out.failed"), isPresented: $isSignOutFailurePresented) {
            Button(text("common.close"), role: .cancel) {}
        }
        .alert(text("reminder.denied.title"), isPresented: $isReminderDeniedPresented) {
            Button(text("reminder.denied.settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button(text("common.cancel"), role: .cancel) {}
        } message: {
            Text(text("reminder.denied.message"))
        }
        .alert(text("settings.app_lock.passcode_required.title"), isPresented: $isAppLockPasscodeRequiredPresented) {
            // 「去设置」文案是通用的，复用提醒权限被拒时的同一个键
            Button(text("reminder.denied.settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button(text("common.cancel"), role: .cancel) {}
        } message: {
            Text(text("settings.app_lock.passcode_required.message"))
        }
        .onChange(of: reminderMinutes) { _, _ in
            Task { await rescheduleReminders() }
        }
    }

    /// 「隐私与安全」分组：应用锁开关，打开后多一行「离开多久后上锁」；没有注入应用锁时整组不显示。
    @ViewBuilder
    private var appLockSection: some View {
        if let appLock {
            ProfileSettingsSection("settings.section.security") {
                Toggle(isOn: Binding(get: { appLock.isEnabled }, set: { setAppLockEnabled($0) })) {
                    Label(text("settings.app_lock.title"), systemImage: "faceid")
                        .labelStyle(ProfileSettingsLabelStyle())
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .accessibilityIdentifier("settings-app-lock")

                if appLock.isEnabled {
                    ProfileSettingsRowDivider()

                    pickerRow(
                        "settings.app_lock.timeout.title",
                        symbol: "timer",
                        selection: Binding(get: { appLock.timeout }, set: { appLock.timeout = $0 })
                    ) {
                        $0.titleLocalizationKey
                    }
                    .accessibilityIdentifier("settings-app-lock-timeout")
                }
            }
        }
    }

    /// 每日记账提醒的开关，打开后多一行时间。
    @ViewBuilder
    private var reminderRows: some View {
        Toggle(isOn: Binding(get: { isReminderEnabled }, set: { setReminderEnabled($0) })) {
            Label(text("reminder.title"), systemImage: "bell")
                .labelStyle(ProfileSettingsLabelStyle())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .accessibilityIdentifier("settings-reminder")

        if isReminderEnabled {
            ProfileSettingsRowDivider()

            DatePicker(
                selection: reminderTime,
                displayedComponents: .hourAndMinute
            ) {
                Label(text("reminder.time"), systemImage: "clock")
                    .labelStyle(ProfileSettingsLabelStyle())
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .accessibilityIdentifier("settings-reminder-time")
        }
    }

    /// 提醒时间与日期选择器之间的换算；只用到时和分。
    private var reminderTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: reminderMinutes / 60,
                    minute: reminderMinutes % 60,
                    second: 0,
                    of: .now
                ) ?? .now
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                reminderMinutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            }
        )
    }

    /// 打开或关闭每日提醒；打开时先要通知权限，被拒绝时开关保持关闭并说明怎么开启。
    ///
    /// - Parameter isEnabled: 用户想要的开关状态。
    private func setReminderEnabled(_ isEnabled: Bool) {
        Task {
            if isEnabled, await !BookkeepingReminderScheduler.requestAuthorization() {
                isReminderDeniedPresented = true
                return
            }
            isReminderEnabled = isEnabled
            await rescheduleReminders()
        }
    }

    /// 打开或关闭应用锁。
    ///
    /// 关闭时直接关，不再验证一次；打开时先验证一次设备主人，通过才真正打开，
    /// 取消或失败时开关保持关闭，设备没设置密码时弹窗说明要先去系统设置里设置。
    ///
    /// - Parameter isEnabled: 用户想要的开关状态。
    private func setAppLockEnabled(_ isEnabled: Bool) {
        guard let appLock else { return }
        guard isEnabled else {
            appLock.disable()
            return
        }
        Task {
            switch await appLock.enable() {
            case .enabled, .notAuthenticated:
                break
            case .passcodeNotSet:
                isAppLockPasscodeRequiredPresented = true
            }
        }
    }

    /// 按当前偏好重排每日提醒。
    private func rescheduleReminders() async {
        await BookkeepingReminderScheduler.reschedule(
            container: modelContext.container,
            locale: locale,
            calendar: .current
        )
    }

    /// 点击后弹出系统菜单的偏好行，行尾显示当前选项。
    ///
    /// - Parameters:
    ///   - titleKey: 行标题与菜单标题的本地化 key。
    ///   - symbol: 行图标。
    ///   - selection: 绑定的偏好值。
    ///   - optionTitleKey: 取每个选项标题本地化 key 的方法。
    private func pickerRow<Option: CaseIterable & Identifiable & Hashable>(
        _ titleKey: String,
        symbol: String,
        selection: Binding<Option>,
        optionTitleKey: @escaping (Option) -> String
    ) -> some View where Option.AllCases: RandomAccessCollection {
        Menu {
            Picker(text(titleKey), selection: selection) {
                ForEach(Option.allCases) { option in
                    Text(text(optionTitleKey(option))).tag(option)
                }
            }
        } label: {
            ProfileSettingsRow(titleKey: titleKey, symbol: symbol, value: text(optionTitleKey(selection.wrappedValue)))
        }
    }

    /// 正负颜色偏好行；系统菜单不支持给部分文字上色，菜单项用带颜色的加减号示意两种配色。
    private var amountColorsRow: some View {
        Menu {
            Picker(text("settings.amount_colors.title"), selection: $amountColors) {
                ForEach(AmountColorConvention.allCases) { option in
                    Label {
                        Text(text(option.titleLocalizationKey))
                    } icon: {
                        option.swatch(colorScheme: colorScheme)
                    }
                    .tag(option)
                }
            }
        } label: {
            ProfileSettingsRow(
                titleKey: "settings.amount_colors.title",
                symbol: "plusminus",
                value: text(amountColors.titleLocalizationKey)
            )
        }
    }

    /// 点击退出登录：本机数据已同步到当前账号时让用户选择保留还是清除，否则只做二次确认。
    private func beginSignOut() {
        // 兜底：注销进行中（「账号与安全」页的注销弹层盖着整个界面，正常点不到这里）不能退出，凭证一清，服务端的删除就拿不到 token，账号会只删一半
        guard !authStore.isDeletingAccount else { return }
        syncLifecycle?.refreshState()
        if let boundUserID = syncLifecycle?.state.boundUserID, boundUserID == authStore.userID {
            isSignOutChoicePresented = true
        } else {
            isSignOutConfirmationPresented = true
        }
    }

    /// 处理本机数据后退出登录；处理失败时不退出，本机数据和绑定保持原样。
    ///
    /// - Parameter choice: 保留在本机，或从本机清除。
    private func signOut(_ choice: SyncSignOutChoice) async {
        guard let syncLifecycle else { return }
        isSigningOut = true
        defer { isSigningOut = false }
        do {
            try await syncLifecycle.prepareForSignOut(choice)
        } catch {
            isSignOutFailurePresented = true
            return
        }
        if choice == .eraseFromDevice {
            // 从本机清除是为了不在这台设备上留下数据：撤销快照和最近搜索词也一并删除
            DataUndoService(container: modelContext.container).discardSnapshot()
            UserDefaults.standard.removeObject(forKey: BookkeepingSearchHistory.storageKey)
        }
        // 必须在 signOut 之前、userID 还在时清掉这个账号的联动缓存
        dataLinks?.clearCurrentUserCache()
        await authStore.signOut()
    }

    /// 币种在设置行里的写法：名称加符号，例如「美元 US$」。
    private func currencyValue(for code: String) -> String {
        "\(BookkeepingCurrency.displayName(for: code, locale: locale)) \(BookkeepingCurrency.symbol(for: code, locale: locale))"
    }

    /// 更换币种确认框的标题，带新币种的名称；没有待确认的币种时为空。
    private var currencyConfirmationTitle: String {
        guard let code = pendingCurrencyCode else { return "" }
        return String(
            format: text("settings.currency.confirm.title"),
            locale: locale,
            BookkeepingCurrency.displayName(for: code, locale: locale)
        )
    }

    /// 确认后把整个账本换成新币种：所有账户和流水在一次保存里改写，失败时提示且数据不变。
    ///
    /// - Parameter code: 新币种代码。
    private func changeCurrency(to code: String) {
        do {
            try LocalLedgerCurrencyRepository(container: modelContext.container).change(to: code)
            AppHaptics.play(.success)
        } catch {
            AppHaptics.play(.error)
            isCurrencyChangeFailed = true
        }
    }

    /// 显示当前生效的默认账户，保持与记账入口相同的解析规则。
    private var defaultAccountName: String {
        let id = BookkeepingPreference.resolvedAccountID(
            preference: preferences.first { $0.id == BookkeepingPreference.singletonID },
            accounts: accounts
        )
        return accounts.first { $0.id == id }?.name ?? text("account.management.no_default")
    }

    /// 按应用当前语言解析已有 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .navigationDestination(for: ProfileRoute.self) { $0.destination }
    }
        .environment(AuthStore())
        .modelContainer(for: [Account.self, AccountTransaction.self, BookkeepingPreference.self], inMemory: true)
}
