import SwiftData
import SwiftUI

/// 个人设置入口：以分组卡片承载账户、备份、语言与外观等本机偏好。
struct ProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.modelContext) private var modelContext
    @Query private var accounts: [Account]
    @Query private var preferences: [BookkeepingPreference]

    /// 与首页共用金额显隐偏好，修改后立即同步。
    @AppStorage("home.summary.amountsVisible") private var areAmountsVisible = false
    /// 与窗口根部共享语言偏好，修改后立即更新界面文案。
    @AppStorage(AppLanguage.storageKey) private var language: AppLanguage = .system
    /// 与窗口根部共享外观偏好，修改后立即同步亮暗色。
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system
    /// 默认账户选择沿用现有独立弹层流程。
    @State private var isDefaultSelectionPresented = false

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

                    rowDivider

                    NavigationLink {
                        DeactivatedAccountListView()
                    } label: {
                        row(
                            "account.deactivated.title",
                            symbol: "archivebox",
                            value: accounts.filter { !$0.isActive }.count.formatted()
                        )
                    }
                }

                settingsSection("profile.section.data") {
                    DataExportEntryView(container: modelContext.container)
                        .labelStyle(ProfileExportLabelStyle())
                }

                settingsSection("shortcut.screenshot.section") {
                    NavigationLink {
                        ScreenshotShortcutSetupView()
                    } label: {
                        row("shortcut.screenshot.title", symbol: "viewfinder", value: "")
                    }
                    .accessibilityIdentifier("profile-screenshot-shortcut")
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

                    Toggle(isOn: $areAmountsVisible) {
                        Label(text("profile.show_amounts"), systemImage: "eye")
                            .labelStyle(ProfileSettingsLabelStyle())
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .accessibilityIdentifier("profile-show-amounts")
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .paperPage()
        .navigationTitle(text("profile.title"))
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(appearance.colorScheme)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                }
                .accessibilityLabel(text("common.close"))
                .accessibilityIdentifier("profile-close")
            }
        }
        .sheet(isPresented: $isDefaultSelectionPresented) {
            NavigationStack { DefaultAccountSelectionView() }
        }
    }

    /// 本地应用没有登录身份，头像仅作视觉标识，不暗示可编辑的在线账户。
    private var profileHeader: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 88, weight: .light))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            Text(verbatim: "yadoA")
                .font(.system(.title2, design: .serif, weight: .semibold))

            Text(text("profile.local_data"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 8)
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
        .foregroundStyle(.primary)
    }
}

#Preview {
    NavigationStack { ProfileView() }
        .modelContainer(for: [Account.self, AccountTransaction.self, BookkeepingPreference.self], inMemory: true)
}

/// 将导出行的留白纳入 Button 标签，使整张卡片均可点击。
private struct ProfileExportLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label(configuration)
            .labelStyle(ProfileSettingsLabelStyle())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .contentShape(Rectangle())
    }
}
