#if DEBUG
import SwiftUI

/// 「我的 → 头像右上角 → 开发」：集中查看开发调试信息（AI 耗时、AI 服务、云端同步状态、构建信息）。
///
/// 只在 DEBUG 包存在，入口由 `DeveloperTools.isEnabled` 控制。数值是给开发者看的原始值，不做本地化。
struct DeveloperView: View {
    @Environment(\.locale) private var locale
    @Environment(AuthStore.self) private var authStore
    /// 同步引擎；预览中没有注入时为 nil。
    @Environment(SyncEngine.self) private var syncEngine: SyncEngine?
    /// 同步生命周期，提供本机同步状态快照；预览中没有注入时为 nil。
    @Environment(SyncLifecycle.self) private var syncLifecycle: SyncLifecycle?

    /// 当前选择的 AI 服务，与 `AIServiceEnvironment.current` 共用存储。
    @AppStorage(AIServiceEnvironment.storageKey) private var aiServiceEnvironment: AIServiceEnvironment = .production

    var body: some View {
        Form {
            Section(text("developer.section.ai")) {
                NavigationLink {
                    VoiceTimingHistoryView()
                } label: {
                    LabeledContent(
                        text("voice.timing.history.title"),
                        value: VoiceTimingStore.shared.records.count.formatted()
                    )
                }
                .accessibilityIdentifier("developer-voice-timing")

                NavigationLink {
                    AIServiceSettingsView()
                } label: {
                    LabeledContent(
                        text("debug.aiService.title"),
                        value: text(aiServiceEnvironment.titleLocalizationKey)
                    )
                }
                .accessibilityIdentifier("developer-ai-service")
            }

            Section(text("developer.section.sync")) {
                infoRow("developer.sync.endpoint", value: SyncServiceEnvironment.currentEndpoint.absoluteString)
                infoRow("developer.sync.status", value: syncStatusDescription)
                if let state = syncLifecycle?.state {
                    infoRow("developer.sync.enabled", value: state.isEnabled ? "true" : "false")
                    infoRow("developer.sync.boundUser", value: state.boundUserID ?? "—")
                    infoRow("developer.sync.epoch", value: String(state.epoch))
                    infoRow("developer.sync.since", value: String(state.since))
                    infoRow("developer.sync.deviceID", value: state.deviceID.uuidString.lowercased())
                    infoRow("developer.sync.lastSynced", value: state.lastSyncedAt.map(formatted) ?? "—")
                }
                infoRow("developer.sync.oversized", value: String(syncEngine?.oversizedRecordCount ?? 0))
            }

            Section(text("developer.section.account")) {
                infoRow("developer.account.userID", value: authStore.userID ?? "—")
            }

            Section(text("developer.section.app")) {
                infoRow("developer.app.version", value: Self.appVersion)
                infoRow("developer.app.bundleID", value: Bundle.main.bundleIdentifier ?? "—")
            }
        }
        .navigationTitle(text("developer.title"))
        .navigationBarTitleDisplayMode(.inline)
        .paperPage()
        .onAppear { syncLifecycle?.refreshState() }
    }

    /// 一行只读信息；值用等宽字体，长按可复制。
    ///
    /// - Parameters:
    ///   - titleKey: 标题的本地化键。
    ///   - value: 原始值。
    private func infoRow(_ titleKey: String, value: String) -> some View {
        LabeledContent(text(titleKey)) {
            Text(value)
                .font(.footnote.monospaced())
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    /// 同步引擎当前状态的原始描述，失败时带上具体原因，便于排查。
    private var syncStatusDescription: String {
        guard let syncEngine else { return "—" }
        switch syncEngine.status {
        case .idle: return "idle"
        case .syncing: return "syncing"
        case let .failed(failure): return "failed: \(String(describing: failure))"
        case let .epochMismatch(currentEpoch): return "epochMismatch: \(currentEpoch)"
        }
    }

    /// 按应用当前语言格式化日期时间（精确到秒）。
    private func formatted(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .numeric, time: .standard, locale: locale))
    }

    /// 版本号与构建号，如 `1.0 (12)`。
    private static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }

    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}
#endif
