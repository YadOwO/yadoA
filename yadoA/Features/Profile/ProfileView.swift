import SwiftData
import SwiftUI

/// “我的”Tab 根页面：页头承载登录身份，下方只放常用入口（账单、分类）、AI 点数、云端同步、“设置”二级页和意见反馈。
///
/// 语言、外观、默认账户、导入导出、退出登录等低频项统一收进 `SettingsView`，已停用账户由“账户”Tab 承载。
/// 进入二级页面都走路径导航（见 `ProfileRoute`），根导航据此判断是否显示语音入口。
struct ProfileView: View {
    @Environment(\.locale) private var locale
    /// 全局登录状态；登录与否只影响页头身份，不影响本地账本。
    @Environment(AuthStore.self) private var authStore
    /// 整屏登录页的展示状态。
    @Environment(SignInPresentation.self) private var signInPresentation
    /// 云端同步的绑定与开关；预览中没有注入时为 nil。
    @Environment(SyncLifecycle.self) private var syncLifecycle: SyncLifecycle?
    /// 当前账号的 AI 点数；预览中没有注入时为 nil。
    @Environment(AIPointsStore.self) private var aiPoints: AIPointsStore?
    /// 意见反馈的未读回复数；预览中没有注入时为 nil。
    @Environment(FeedbackStore.self) private var feedback: FeedbackStore?

    /// 修改个人资料弹层，打开时携带当时的资料快照。
    @State private var editingProfile: AccountProfile?

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                profileHeader

                ProfileSettingsSection(nil, seed: "profile.section.bookkeeping") {
                    // 账单是按月、按年回看的汇总，不是日常记账操作，放在这里不占记账页导航栏。
                    NavigationLink(value: ProfileRoute.bills) {
                        ProfileSettingsRow(titleKey: "bill.title", symbol: "doc.text")
                    }
                    .accessibilityIdentifier("profile-bills")

                    ProfileSettingsRowDivider()

                    NavigationLink(value: ProfileRoute.categories) {
                        ProfileSettingsRow(titleKey: "category.management.title", symbol: "square.grid.2x2")
                    }
                    .accessibilityIdentifier("profile-category-management")
                }

                ProfileSettingsSection(nil, seed: "profile.section.ai") {
                    NavigationLink(value: ProfileRoute.aiPoints) {
                        ProfileSettingsRow(
                            titleKey: "ai.points.title",
                            symbol: "sparkles",
                            value: aiPointsValue,
                            // 余额不够说一句时用账本红提醒，其余保持灰色
                            valueTint: authStore.isAuthenticated && aiPoints?.isExhausted == true ? Color(.ledgerRed) : nil
                        )
                    }
                    .accessibilityIdentifier("profile-ai-points")
                }

                ProfileSettingsSection(nil, seed: "profile.section.data") {
                    NavigationLink(value: ProfileRoute.sync) {
                        ProfileSettingsRow(
                            titleKey: "sync.title",
                            symbol: "icloud",
                            value: text(isSyncOn ? "sync.row.on" : "sync.row.off"),
                            // 已开启用账本绿表示生效，未开启保持灰色；账本绿已配好浅色与深色两套
                            valueTint: isSyncOn ? Color(.ledgerGreen) : nil
                        )
                    }
                    .accessibilityIdentifier("profile-sync")

                    ProfileSettingsRowDivider()

                    NavigationLink(value: ProfileRoute.settings) {
                        ProfileSettingsRow(titleKey: "settings.title", symbol: "gearshape")
                    }
                    .accessibilityIdentifier("profile-settings")
                }

                ProfileSettingsSection(nil, seed: "profile.section.feedback") {
                    feedbackEntry
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
        .sheet(item: $editingProfile) { profile in
            ProfileEditView(profile: profile)
        }
        .task(id: authStore.isAuthenticated) {
            // 进入页面或登录状态变化时拉一次最新资料，其他端改过昵称也能及时同步
            await authStore.refreshProfile()
        }
        .task(id: authStore.isAuthenticated) {
            // 每次回到“我的”都刷新一次余额，其他芽豆 App 用掉的点数也能及时反映
            await aiPoints?.refresh()
        }
        .task(id: authStore.isAuthenticated) {
            // 每次回到“我的”都刷新一次反馈未读数；从反馈页返回时已在标记已读后更新过，这里再对一次
            await feedback?.refreshUnread()
        }
    }

    /// 意见反馈入口：已登录时进入对话页；未登录时直接打开登录页，说明反馈需要登录。
    @ViewBuilder
    private var feedbackEntry: some View {
        if authStore.isAuthenticated {
            NavigationLink(value: ProfileRoute.feedback) {
                feedbackRow
            }
            .accessibilityIdentifier("profile-feedback")
        } else {
            Button {
                signInPresentation.present(reason: .feedback)
            } label: {
                feedbackRow
            }
            .accessibilityIdentifier("profile-feedback")
        }
    }

    /// 意见反馈行：有未读回复时行尾用账本红显示条数。
    private var feedbackRow: some View {
        let unreadCount = authStore.isAuthenticated ? feedback?.unreadCount ?? 0 : 0
        return ProfileSettingsRow(
            titleKey: "feedback.title",
            symbol: "bubble.left.and.text.bubble.right",
            value: unreadCount > 0
                ? AccountLocalization.formatted(
                    "feedback.row.unread",
                    value: unreadCount.formatted(.number.locale(locale)),
                    locale: locale
                )
                : "",
            valueTint: unreadCount > 0 ? Color(.ledgerRed) : nil
        )
    }

    /// AI 点数行尾的值：未登录时提示登录后可用，已登录时显示余额，还没取到时留空。
    private var aiPointsValue: String {
        guard authStore.isAuthenticated else {
            return text("ai.points.row.signedOut")
        }
        guard let balance = aiPoints?.balance else {
            return ""
        }
        return AccountLocalization.formatted(
            "ai.points.row.balance",
            value: balance.formatted(.number.locale(locale)),
            locale: locale
        )
    }

    /// 当前账号是否已开启云端同步；决定「云端同步」行的状态值和页头副标题。
    private var isSyncOn: Bool {
        guard authStore.isAuthenticated,
              let state = syncLifecycle?.state,
              state.isEnabled,
              let userID = authStore.userID
        else { return false }
        return state.boundUserID == userID
    }

    /// 页头留给用户自己的头像与名称，不放产品品牌；未登录时显示占位名称和登录入口。
    ///
    /// 已登录时头像右下角带铅笔角标，点头像或名称打开修改资料弹层。
    private var profileHeader: some View {
        VStack(spacing: 14) {
            // 未登录时不包成按钮，避免禁用态把头像和名称压暗
            Group {
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
            }
            #if DEBUG
            // 开发入口不能放进修改资料按钮里，否则点击会被外层按钮吃掉；这里叠在同一位置，对齐头像右上角
            .overlay(alignment: .top) {
                if DeveloperTools.isEnabled {
                    developerEntry
                        .frame(width: Self.avatarSize, height: Self.avatarSize, alignment: .topTrailing)
                }
            }
            #endif

            // 副标题说明数据存放位置：开启同步后提示已同步到云端，否则提示只在本机
            Text(text(isSyncOn ? "profile.sync_on" : "profile.local_data"))
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
            ProfileAvatarView(url: authStore.profile?.avatarURL, size: Self.avatarSize)
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

    /// 页头头像的边长。
    private static let avatarSize: CGFloat = 96

    #if DEBUG
    /// 头像右上角的「开发」页面入口，是否显示见 `DeveloperTools.isEnabled`。
    private var developerEntry: some View {
        NavigationLink(value: ProfileRoute.developer) {
            Image(systemName: "hammer")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color(uiColor: .secondarySystemBackground)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        }
        .offset(x: 4, y: -4)
        .accessibilityLabel(text("developer.title"))
        .accessibilityIdentifier("profile-developer")
    }
    #endif

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
            signInPresentation.present()
        } label: {
            Text(text("auth.sign_in.action"))
                .font(.body.weight(.medium))
                .padding(.horizontal, 16)
                .onAccentForeground()
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

    /// 按应用当前语言解析已有 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

#Preview {
    NavigationStack {
        ProfileView()
            .navigationDestination(for: ProfileRoute.self) { $0.destination }
    }
        .environment(AuthStore())
        .environment(SignInPresentation())
        .modelContainer(for: [Account.self, AccountTransaction.self, BookkeepingPreference.self], inMemory: true)
}
