import SwiftData
import SwiftUI
import UIKit

/// “我的 › 设置”二级页面：集中放置设一次就很少再动的偏好、数据维护和退出登录。
///
/// 分组顺序为通用、记账、数据、关于、危险操作、账号；重置数据单独成卡，避免与导入导出相邻误触。
struct SettingsView: View {
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    /// 全局登录状态；只决定是否显示退出登录分组。
    @Environment(AuthStore.self) private var authStore
    /// 云端同步的绑定状态，退出登录时据此决定是否询问保留本机数据；预览中没有注入时为 nil。
    @Environment(SyncLifecycle.self) private var syncLifecycle: SyncLifecycle?
    /// AI 点数状态，注销时关闭当前账号的“帮助改进 AI”授权；预览中没有注入时为 nil。
    @Environment(AIPointsStore.self) private var aiPoints: AIPointsStore?
    @Query private var accounts: [Account]
    @Query private var preferences: [BookkeepingPreference]

    /// 与首页共用金额显隐偏好，修改后立即同步。
    @AppStorage("home.summary.amountsVisible") private var areAmountsVisible = false
    /// 与窗口根部共享语言偏好，修改后立即更新界面文案。
    @AppStorage(AppLanguage.storageKey) private var language: AppLanguage = .system
    /// 与窗口根部共享外观偏好，修改后立即同步亮暗色。
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system
    /// 全局正负颜色，账单、账户、点数等页面的金额都读同一个键，修改后立即生效。
    @AppStorage(AmountColorConvention.storageKey) private var amountColors: AmountColorConvention = .positiveRed
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
    /// 默认账户选择沿用现有独立弹层流程。
    @State private var isDefaultSelectionPresented = false
    /// 退出登录前的二次确认（本机数据没有同步到当前账号时）。
    @State private var isSignOutConfirmationPresented = false
    /// 退出登录时选择保留还是清除本机数据（本机数据已同步到当前账号时）。
    @State private var isSignOutChoicePresented = false
    /// 退出前处理本机数据失败的提示。
    @State private var isSignOutFailurePresented = false
    /// 正在退出登录（含退出前的最后一次同步）。
    @State private var isSigningOut = false
    /// 注销账号第一步：提醒芽豆系列所有 App 共用这一个芽豆账号、注销会影响全部 App，并说明会发生什么。
    @State private var isDeleteAccountWarningPresented = false
    /// 注销账号第二步：选择本机账本保留还是清除。
    @State private var isDeleteAccountChoicePresented = false
    /// 正在注销账号。
    @State private var isDeletingAccount = false
    /// 注销没有完成（服务端调用失败），本机数据和登录状态不变，可以重试。
    @State private var isDeleteAccountFailurePresented = false
    /// 服务端已注销，但本机数据没清掉。
    @State private var isDeleteAccountLocalCleanupFailurePresented = false
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

                ProfileSettingsSection("profile.section.bookkeeping") {
                    Button {
                        isDefaultSelectionPresented = true
                    } label: {
                        ProfileSettingsRow(titleKey: "account.management.default.title", symbol: "star", value: defaultAccountName)
                    }
                    .accessibilityIdentifier("profile-default-account")

                    ProfileSettingsRowDivider()

                    Toggle(isOn: $areAmountsVisible) {
                        Label(text("profile.show_amounts"), systemImage: "eye")
                            .labelStyle(ProfileSettingsLabelStyle())
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .accessibilityIdentifier("profile-show-amounts")

                    ProfileSettingsRowDivider()

                    NavigationLink {
                        ScreenshotShortcutSetupView()
                    } label: {
                        ProfileSettingsRow(titleKey: "shortcut.screenshot.title", symbol: "viewfinder")
                    }
                    .accessibilityIdentifier("profile-screenshot-shortcut")

                    ProfileSettingsRowDivider()

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
                }

                ProfileSettingsSection("settings.section.about") {
                    Button {
                        onboardingReplay = OnboardingStore(mode: .replay)
                    } label: {
                        ProfileSettingsRow(titleKey: "settings.onboarding.replay", symbol: "leaf")
                    }
                    .accessibilityIdentifier("settings-onboarding-replay")

                    ForEach(LegalDocument.allCases) { document in
                        ProfileSettingsRowDivider()

                        Button {
                            presentedLegalDocument = document
                        } label: {
                            ProfileSettingsRow(titleKey: document.titleLocalizationKey, symbol: document.systemImage)
                        }
                        .accessibilityIdentifier("settings-legal-\(document.rawValue)")
                    }
                }

                // 重置会清空本机全部记账数据，单独成卡与常规数据操作拉开距离
                ProfileSettingsSection(nil, seed: "settings.reset") {
                    DataResetEntryView(container: modelContext.container)
                        .labelStyle(ProfileExportLabelStyle(color: .red))
                }

                if authStore.isAuthenticated {
                    ProfileSettingsSection("auth.section.title") {
                        Button {
                            beginSignOut()
                        } label: {
                            Label(text("auth.sign_out.action"), systemImage: "rectangle.portrait.and.arrow.right")
                        }
                        .labelStyle(ProfileExportLabelStyle(color: .red))
                        .disabled(authStore.isBusy || isSigningOut || isDeletingAccount)
                        .accessibilityIdentifier("profile-sign-out")

                        ProfileSettingsRowDivider()

                        HStack {
                            Button {
                                isDeleteAccountWarningPresented = true
                            } label: {
                                Label(text("account.delete.action"), systemImage: "person.crop.circle.badge.xmark")
                            }
                            .labelStyle(ProfileExportLabelStyle(color: .red))
                            .disabled(authStore.isBusy || isSigningOut || isDeletingAccount)
                            .accessibilityIdentifier("settings-delete-account")

                            if isDeletingAccount {
                                ProgressView()
                                    .padding(.trailing, 20)
                            }
                        }
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
                Task { await authStore.signOut() }
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
        .alert(text("account.delete.warning.title"), isPresented: $isDeleteAccountWarningPresented) {
            Button(text("account.delete.warning.continue"), role: .destructive) {
                isDeleteAccountChoicePresented = true
            }
            .accessibilityIdentifier("settings-delete-account-continue")

            Button(text("common.cancel"), role: .cancel) {}
        } message: {
            Text(text("account.delete.warning.message"))
        }
        .confirmationDialog(
            text("account.delete.choice.title"),
            isPresented: $isDeleteAccountChoicePresented,
            titleVisibility: .visible
        ) {
            Button(text("account.delete.choice.keep"), role: .destructive) {
                Task { await deleteAccount(.keepOnDevice) }
            }
            .accessibilityIdentifier("settings-delete-account-keep")

            Button(text("account.delete.choice.erase"), role: .destructive) {
                Task { await deleteAccount(.eraseFromDevice) }
            }
            .accessibilityIdentifier("settings-delete-account-erase")

            Button(text("common.cancel"), role: .cancel) {}
        } message: {
            Text(text("account.delete.choice.message"))
        }
        .alert(text("account.delete.failed"), isPresented: $isDeleteAccountFailurePresented) {
            Button(text("common.close"), role: .cancel) {}
        }
        .alert(text("account.delete.local_cleanup_failed"), isPresented: $isDeleteAccountLocalCleanupFailurePresented) {
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
        .onChange(of: reminderMinutes) { _, _ in
            Task { await rescheduleReminders() }
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
        guard !isDeletingAccount else { return }
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
        await authStore.signOut()
    }

    /// 注销账号：先让两个服务端删除账号和云端数据，成功后处理本机数据并退出登录。
    ///
    /// 删除的是芽豆系列所有 App 共用的芽豆账号（Logto 用户），注销后其他芽豆 App 也无法再用它登录，
    /// 所以第一步警告必须讲明影响全部 App。
    ///
    /// 服务端调用失败时中止，本机数据和登录状态不变，提示重试；只有“服务端已注销、本机清理失败”
    /// 仍会退出登录，因为账号已经不存在，并提示用户可以在设置里重置数据。
    ///
    /// - Parameter choice: 本机账本保留，或一并清除。
    private func deleteAccount(_ choice: SyncSignOutChoice) async {
        guard let syncLifecycle else { return }
        isDeletingAccount = true
        defer { isDeletingAccount = false }
        let api = AccountDeletionAPI(
            aiAccessToken: { try await authStore.accessTokenForAIService() },
            syncAccessToken: { try await authStore.accessTokenForSyncService() }
        )
        var isLocalCleanupFailed = false
        do {
            try await syncLifecycle.deleteAccount(choice) {
                try await api.deleteAIData()
                try await api.deleteAccount()
            }
        } catch SyncLifecycleError.storage {
            isLocalCleanupFailed = true
        } catch {
            isDeleteAccountFailurePresented = true
            return
        }
        // 必须在 signOut 之前、userID 还在时关闭授权
        aiPoints?.setTraceConsented(false)
        if choice == .eraseFromDevice, !isLocalCleanupFailed {
            DataUndoService(container: modelContext.container).discardSnapshot()
            UserDefaults.standard.removeObject(forKey: BookkeepingSearchHistory.storageKey)
        }
        await authStore.signOut()
        if isLocalCleanupFailed {
            isDeleteAccountLocalCleanupFailurePresented = true
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
    NavigationStack { SettingsView() }
        .environment(AuthStore())
        .modelContainer(for: [Account.self, AccountTransaction.self, BookkeepingPreference.self], inMemory: true)
}
