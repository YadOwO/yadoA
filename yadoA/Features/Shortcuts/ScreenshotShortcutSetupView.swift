import SwiftUI

/// 两步快捷指令和系统轻点背面的配置说明。
struct ScreenshotShortcutSetupView: View {
    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL
    @State private var cannotOpenShortcuts = false

    var body: some View {
        List {
            Section {
                Label(text("shortcut.screenshot.setup.intro"), systemImage: "viewfinder")
                Text(text("shortcut.screenshot.manual_hint"))
                    .foregroundStyle(.secondary)
            }

            Section(text("shortcut.screenshot.setup.create")) {
                Text(text("shortcut.screenshot.setup.actions"))
                Text(text("shortcut.screenshot.setup.input"))
                    .foregroundStyle(.secondary)
                Button(text("shortcut.screenshot.setup.open")) {
                    openURL(URL(string: "shortcuts://create-shortcut")!) { accepted in
                        cannotOpenShortcuts = !accepted
                    }
                }
                .accessibilityIdentifier("screenshot-shortcut-create")
            }

            Section(text("shortcut.screenshot.setup.back_tap")) {
                Text(text("shortcut.screenshot.setup.settings"))
                Text(text("shortcut.screenshot.setup.select"))
                    .foregroundStyle(.secondary)
            }

            Section(text("shortcut.screenshot.setup.use")) {
                Text(text("shortcut.screenshot.setup.try"))
                Text(text("shortcut.screenshot.privacy"))
                    .foregroundStyle(.secondary)
            }

            #if DEBUG
            if ScreenshotShortcutUITestFixture.isEnabled {
                Button("UITest screenshot") {
                    Task { await ScreenshotShortcutUITestFixture.invoke() }
                }
                .accessibilityIdentifier("screenshot-shortcut-test-invoke")
            }
            #endif
        }
        .navigationTitle(text("shortcut.screenshot.title"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(text("shortcut.screenshot.setup.open_failed"), isPresented: $cannotOpenShortcuts) {
            Button(text("common.done"), role: .cancel) { }
        }
    }

    /// 说明文案与快捷指令动作名称使用同一份原生本地化资源。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}
