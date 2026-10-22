import SwiftData
import SwiftUI

/// “我的”Tab 根页面：页头承载登录身份，分组卡片承载账户、备份、语言与外观等本机偏好。
struct ProfileView: View {
    @Environment(\.locale) private var locale
    @Environment(\.modelContext) private var modelContext
    /// 全局登录状态；登录与否只影响页头身份和退出入口，不影响本地账本。
    @Environment(AuthStore.self) private var authStore
    @Query private var accounts: [Account]
    @Query private var preferences: [BookkeepingPreference]

    /// 与首页共用金额显隐偏好，修改后立即同步。
    @AppStorage("home.summary.amountsVisible") private var areAmountsVisible = false
    /// 与窗口根部共享语言偏好，修改后立即更新界面文案。
    @AppStorage(AppLanguage.storageKey) private var language: AppLanguage = .system
    /// 与窗口根部共享外观偏好，修改后立即同步亮暗色。
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system
    /// 启动页面偏好：底部导航顺序立即更新，落点在下次冷启动时生效。
    @AppStorage(AppStartPage.storageKey) private var startPage: AppStartPage = .home
    /// 默认账户选择沿用现有独立弹层流程。
    @State private var isDefaultSelectionPresented = false
    /// 退出登录前的二次确认。
    @State private var isSignOutConfirmationPresented = false
    /// 修改个人资料弹层，打开时携带当时的资料快照。
    @State private var editingProfile: AccountProfile?
    /// 是否推入登录 / 注册页。
    @State private var isSignInPresented = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                profileHeader

                settingsSection("account.management.title") {
                    Button {
                        isDefaultSelectionPresented = true
                    } label: {
                        row("account.management.default.title", symbol: "star", value: defaultAccountName)
                    }
                    .accessibilityIdentifier("profile-default-account")

                    // 没有已停用账户时整行（含分隔线）不显示。
                    if deactivatedAccountCount > 0 {
                        rowDivider

                        NavigationLink {
                            DeactivatedAccountListView()
                                .secondaryPage()
                        } label: {
                            row(
                                "account.deactivated.title",
                                symbol: "archivebox",
                                value: deactivatedAccountCount.formatted()
                            )
                        }
                        .accessibilityIdentifier("profile-deactivated-accounts")
                    }
                }

                settingsSection("profile.section.bookkeeping") {
                    NavigationLink {
                        CategoryManagementView()
                            .secondaryPage()
                    } label: {
                        row("category.management.title", symbol: "square.grid.2x2", value: "")
                    }
                    .accessibilityIdentifier("profile-category-management")
                }

                settingsSection("profile.section.display") {
                    Menu {
                        Picker(text("profile.language.title"), selection: $language) {
                            ForEach(AppLanguage.allCases) { option in
                                Text(text(option.titleLocalizationKey)).tag(option)
                            }
                        }
                    } label: {
                        row("profile.language.title", symbol: "globe", value: text(language.titleLocalizationKey))
                    }
                    .accessibilityIdentifier("profile-language")

                    rowDivider

                    Menu {
                        Picker(text("profile.appearance.title"), selection: $appearance) {
                            ForEach(AppAppearance.allCases) { option in
                                Text(text(option.titleLocalizationKey)).tag(option)
                            }
                        }
                    } label: {
                        row("profile.appearance.title", symbol: "circle.lefthalf.filled", value: text(appearance.titleLocalizationKey))
                    }
                    .accessibilityIdentifier("profile-appearance")

                    rowDivider

                    Menu {
                        Picker(text("profile.start_page.title"), selection: $startPage) {
                            ForEach(AppStartPage.allCases) { option in
                                Text(text(option.titleLocalizationKey)).tag(option)
                            }
                        }
                    } label: {
                        row("profile.start_page.title", symbol: "house", value: text(startPage.titleLocalizationKey))
                    }
                    .accessibilityIdentifier("profile-start-page")

                    rowDivider

                    Toggle(isOn: $areAmountsVisible) {
                        Label(text("profile.show_amounts"), systemImage: "eye")
                            .labelStyle(ProfileSettingsLabelStyle())
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .accessibilityIdentifier("profile-show-amounts")
                }

                settingsSection("shortcut.screenshot.section") {
                    NavigationLink {
                        ScreenshotShortcutSetupView()
                            .secondaryPage()
                    } label: {
                        row("shortcut.screenshot.title", symbol: "viewfinder", value: "")
                    }
                    .accessibilityIdentifier("profile-screenshot-shortcut")
                }

                settingsSection("profile.section.data") {
                    DataExportEntryView(container: modelContext.container)
                        .labelStyle(ProfileExportLabelStyle())

                    rowDivider

                    DataImportEntryView(container: modelContext.container)
                        .labelStyle(ProfileExportLabelStyle())

                    rowDivider

                    DataResetEntryView(container: modelContext.container)
                        .labelStyle(ProfileExportLabelStyle(color: .red))

                    DataUndoEntryView(container: modelContext.container) { rowDivider }
                        .labelStyle(ProfileExportLabelStyle())
                }

                // 只在 DEBUG 包与 TestFlight 包显示
                if VoiceTimingFeature.isEnabled {
                    settingsSection("profile.section.developer") {
                        NavigationLink {
                            VoiceTimingHistoryView()
                                .secondaryPage()
                        } label: {
                            row(
                                "voice.timing.history.title",
                                symbol: "stopwatch",
                                value: VoiceTimingStore.shared.records.count.formatted()
                            )
                        }
                        .accessibilityIdentifier("profile-voice-timing")
                    }
                }

                if authStore.isAuthenticated {
                    settingsSection("auth.section.title") {
                        Button {
                            isSignOutConfirmationPresented = true
                        } label: {
                            Label(text("auth.sign_out.action"), systemImage: "rectangle.portrait.and.arrow.right")
                        }
                        .labelStyle(ProfileExportLabelStyle(color: .red))
                        .disabled(authStore.isBusy)
                        .accessibilityIdentifier("profile-sign-out")
                    }
                }

                brandFooter
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .paperPage()
        .navigationTitle(text("profile.title"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isDefaultSelectionPresented) {
            NavigationStack { DefaultAccountSelectionView() }
        }
        .sheet(item: $editingProfile) { profile in
            ProfileEditView(profile: profile)
        }
        .navigationDestination(isPresented: $isSignInPresented) {
            SignInView()
        }
        .task(id: authStore.isAuthenticated) {
            // 进入页面或登录状态变化时拉一次最新资料，其他端改过昵称也能及时同步
            await authStore.refreshProfile()
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
    }

    /// 页头留给用户自己的头像与名称，不放产品品牌；未登录时显示占位名称和登录入口。
    ///
    /// 已登录时头像右下角带铅笔角标，点头像或名称打开修改资料弹层。
    private var profileHeader: some View {
        VStack(spacing: 14) {
            // 未登录时不包成按钮，避免禁用态把头像和名称压暗
            if authStore.isAuthenticated {
                Button {
                    editingProfile = authStore.profile ?? AccountProfile()
                } label: {
                    profileIdentity
                        .contentShape(Rectangle())
                }
                .accessibilityHint(text("profile.edit.title"))
                .accessibilityIdentifier("profile-edit-entry")
            } else {
                profileIdentity
            }

            Text(text("profile.local_data"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !authStore.isAuthenticated {
                signInButton
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    /// 头像与名称；已登录时头像带铅笔角标。
    private var profileIdentity: some View {
        VStack(spacing: 14) {
            ProfileAvatarView(url: authStore.profile?.avatarURL, size: 96)
                .overlay(alignment: .bottomTrailing) {
                    if authStore.isAuthenticated {
                        editBadge
                    }
                }

            Text(headerTitle)
                .font(.system(.title2, design: .serif, weight: .semibold))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("profile-user-name")
        }
    }

    /// 头像右下角的铅笔角标，提示可以修改资料。
    private var editBadge: some View {
        Image(systemName: "pencil")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 32, height: 32)
            .background(Circle().fill(Color(uiColor: .secondarySystemBackground)))
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .offset(x: 4, y: 4)
            .accessibilityHidden(true)
    }

    /// 页头名称：已登录时显示账号名称，取不到名称时显示“已登录”；未登录时显示占位名称。
    private var headerTitle: String {
        guard authStore.isAuthenticated else {
            return text("profile.user.placeholder")
        }
        return authStore.displayName ?? text("auth.user.signed_in")
    }

    /// 打开登录 / 注册页的入口；登录方式的选择与进度都在登录页内完成。
    private var signInButton: some View {
        Button {
            isSignInPresented = true
        } label: {
            Text(text("auth.sign_in.action"))
                .font(.body.weight(.medium))
                .padding(.horizontal, 16)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(authStore.isBusy)
        .padding(.top, 6)
        .accessibilityIdentifier("profile-sign-in")
    }

    /// 页面末尾的品牌落款：产品标记、名称与版本号，像账本封底的印记，不与页头的用户信息争位置。
    private var brandFooter: some View {
        VStack(spacing: 6) {
            Image(.brandMark)
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)

            Text(text("app.name"))
                .font(.system(.subheadline, design: .serif, weight: .medium))
                .accessibilityIdentifier("profile-app-name")

            Text(AccountLocalization.formatted("profile.version", value: Self.appVersion, locale: locale))
                .font(.system(.caption, design: .serif))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("profile-version")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    /// 营销版本号与构建号，形如 `1.0 (1)`；缺少构建号时只显示版本号。
    private static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, !build.isEmpty else {
            return version
        }
        return "\(version) (\(build))"
    }

    /// 已停用账户的数量；为 0 时隐藏入口。
    private var deactivatedAccountCount: Int {
        accounts.count { !$0.isActive }
    }

    /// 显示当前生效的默认账户，保持与记账入口相同的解析规则。
    private var defaultAccountName: String {
        let id = BookkeepingPreference.resolvedAccountID(
            preference: preferences.first { $0.id == BookkeepingPreference.singletonID },
            accounts: accounts
        )
        return accounts.first { $0.id == id }?.name ?? text("account.management.no_default")
    }

    /// 分组标题与动态背景卡片，支持浅色、深色及动态字号。
    private func settingsSection<Content: View>(
        _ titleKey: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text(titleKey))
                .font(.system(.subheadline, design: .serif, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0, content: content)
                .ledgerFormBorder(seed: titleKey.handDrawnSeed)
        }
    }

    /// 图标、标题、当前值与导航箭头组成的整行点击区域。
    private func row(_ titleKey: String, symbol: String, value: String) -> some View {
        HStack(spacing: 12) {
            Label(text(titleKey), systemImage: symbol)
                .labelStyle(ProfileSettingsLabelStyle())
            Spacer(minLength: 4)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .font(.body)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(minHeight: 60)
        .contentShape(Rectangle())
    }

    /// 两行之间的手绘细线，从标题处开始。
    private var rowDivider: some View {
        HandDrawnRule(seed: 99)
            .stroke(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            .frame(height: 3)
            .padding(.leading, 62)
            .padding(.trailing, 20)
            .accessibilityHidden(true)
    }

    /// 按应用当前语言解析已有 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 统一个人页图标宽度，使用系统线性图标和主文字色。
private struct ProfileSettingsLabelStyle: LabelStyle {
    /// 图标与标题的颜色；破坏性操作使用红色。
    var color: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 14) {
            configuration.icon
                .font(.system(size: 21, weight: .regular))
                .frame(width: 28)
                .accessibilityHidden(true)
            configuration.title
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color)
    }
}

#Preview {
    NavigationStack { ProfileView() }
        .environment(AuthStore())
        .modelContainer(for: [Account.self, AccountTransaction.self, BookkeepingPreference.self], inMemory: true)
}

/// 将数据分组各行的留白纳入 Button 标签，使整行均可点击。
private struct ProfileExportLabelStyle: LabelStyle {
    /// 图标与标题的颜色；破坏性操作使用红色。
    var color: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        Label(configuration)
            .labelStyle(ProfileSettingsLabelStyle(color: color))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .contentShape(Rectangle())
    }
}
