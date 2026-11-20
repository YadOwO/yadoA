#if DEBUG
import SwiftUI

/// 「我的 → 头像右上角 → 开发」：集中查看开发调试信息（AI 耗时、AI 服务、云端同步状态、构建信息），
/// 以及尚未接入正式流程的线条头像选择原型。dev 包另有签到测试：重置签到引导、清空签到、把连签设成差一天拿礼包、
/// 昨天漏签（测补签卡）。
///
/// 只在 DEBUG 包存在，入口由 `DeveloperTools.isEnabled` 控制。数值是给开发者看的原始值，不做本地化。
struct DeveloperView: View {
    @Environment(\.locale) private var locale
    @Environment(AuthStore.self) private var authStore
    /// 同步引擎；预览中没有注入时为 nil。
    @Environment(SyncEngine.self) private var syncEngine: SyncEngine?
    /// 同步生命周期，提供本机同步状态快照；预览中没有注入时为 nil。
    @Environment(SyncLifecycle.self) private var syncLifecycle: SyncLifecycle?
    /// 当前账号的 AI 点数与签到状态；预览中没有注入时为 nil，此时不显示签到测试。
    @Environment(AIPointsStore.self) private var aiPoints: AIPointsStore?

    /// 是否正在打开线条头像选择页（原型，尚未接入修改资料）。
    @State private var isPickingLineAvatar = false
    /// 线条头像选择页最近一次选中的头像 ID，只在本页显示，不保存。
    @State private var pickedLineAvatarID: String?

    /// 是否正在服务端重置签到；期间重置按钮不可点。
    @State private var isResettingCheckIn = false

    /// 最近一次签到测试操作的结果，显示在签到测试的脚注里。
    @State private var checkInToolResult: String?

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
                        value: AuthConfig.aiServiceURL.host() ?? "—"
                    )
                }
                .accessibilityIdentifier("developer-ai-service")
            }

            // 签到测试只给连 dev 的包：服务端只有 dev 环境开放重置接口，DebugProd 连的是线上
            if AppEnvironment.current == .dev, let aiPoints {
                checkInToolsSection(aiPoints)
            }

            Section(text("developer.section.sync")) {
                infoRow("developer.sync.endpoint", value: AuthConfig.syncServiceURL.absoluteString)
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

            Section(text("developer.section.lineAvatar")) {
                Button(text("developer.lineAvatar.open")) {
                    isPickingLineAvatar = true
                }
                .accessibilityIdentifier("developer-line-avatar")

                infoRow("developer.lineAvatar.selected", value: pickedLineAvatarID ?? "—")

                // 全部预制头像的静态效果，方便对照浅色、深色外观检查设计
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: 12)], spacing: 12) {
                    ForEach(LineAvatarCatalog.presets) { preset in
                        LineAvatarView(preset: preset, size: 60)
                    }
                }
                .padding(.vertical, 8)
            }

            Section(text("developer.section.app")) {
                infoRow("developer.app.version", value: Self.appVersion)
                infoRow("developer.app.bundleID", value: Bundle.main.bundleIdentifier ?? "—")
                infoRow("developer.app.environment", value: AppEnvironment.current.rawValue)
            }
        }
        .navigationTitle(text("developer.title"))
        .navigationBarTitleDisplayMode(.inline)
        .paperPage()
        .onAppear { syncLifecycle?.refreshState() }
        .sheet(isPresented: $isPickingLineAvatar) {
            LineAvatarPickerView { preset in
                pickedLineAvatarID = preset.id
                isPickingLineAvatar = false
            }
        }
    }

    /// 签到测试：重置签到引导、清空签到记录，以及按各档礼包把连签设成差一天，今天一签就拿到礼包。
    ///
    /// 连签天数取服务端下发的礼包规则（周 7 → 设 6 天），规则改了不用改这里。
    ///
    /// - Parameter aiPoints: 当前账号的 AI 点数与签到状态。
    private func checkInToolsSection(_ aiPoints: AIPointsStore) -> some View {
        let isSignedIn = authStore.userID != nil
        return Section {
            infoRow("developer.checkIn.status", value: checkInStatusDescription(aiPoints))

            Button(text("developer.checkIn.resetGuide")) {
                aiPoints.resetCheckInGuide()
                checkInToolResult = text("developer.checkIn.done.guide")
            }
            .disabled(!isSignedIn)
            .accessibilityIdentifier("developer-check-in-reset-guide")

            Button(text("developer.checkIn.clear"), role: .destructive) {
                resetCheckIn(aiPoints, AICheckInResetOptions(streak: 0))
            }
            .disabled(!isSignedIn || isResettingCheckIn)
            .accessibilityIdentifier("developer-check-in-clear")

            ForEach(aiPoints.checkInStatus?.giftTiers ?? [], id: \.self) { rule in
                Button(streakTitle(for: rule)) {
                    resetCheckIn(aiPoints, AICheckInResetOptions(streak: max(rule.everyDays - 1, 0)))
                }
                .disabled(!isSignedIn || isResettingCheckIn)
                .accessibilityIdentifier("developer-check-in-streak-\(rule.tier.rawValue)")
            }

            // 服务端开了补签卡才有：昨天漏签，今天签到时用不用卡；再加上本月的卡已用，测卡用完时照常断签
            if aiPoints.checkInStatus?.protection?.isEnabled == true {
                let streak = protectionTestStreak(aiPoints)
                Button(protectionTitle("developer.checkIn.missedYesterday", streak: streak)) {
                    resetCheckIn(aiPoints, AICheckInResetOptions(streak: streak, missedYesterday: true))
                }
                .disabled(!isSignedIn || isResettingCheckIn)
                .accessibilityIdentifier("developer-check-in-missed-yesterday")

                Button(protectionTitle("developer.checkIn.cardUsed", streak: streak)) {
                    resetCheckIn(aiPoints, AICheckInResetOptions(streak: streak, missedYesterday: true, cardUsed: true))
                }
                .disabled(!isSignedIn || isResettingCheckIn)
                .accessibilityIdentifier("developer-check-in-card-used")
            }
        } header: {
            Text(text("developer.section.checkIn"))
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let checkInToolResult {
                    Text(checkInToolResult)
                        .foregroundStyle(.primary)
                }
                Text(text("developer.checkIn.footer"))
            }
        }
        // 礼包规则来自签到状态，进本页时拉一次，没拿到时只显示清空
        .task { await aiPoints.refreshCheckInStatus() }
    }

    /// 签到状态的原始描述：今天是否已签、连签天数、待开礼包数；服务端开了补签卡时再加剩余张数和今天能保住的日子。
    ///
    /// - Parameter aiPoints: 当前账号的 AI 点数与签到状态。
    private func checkInStatusDescription(_ aiPoints: AIPointsStore) -> String {
        guard let status = aiPoints.checkInStatus else { return "—" }
        var description = "checkedIn: \(status.checkedIn), streak: \(status.streak), gifts: \(aiPoints.unopenedGifts.count)"
        if let protection = status.protection {
            description += ", cards: \(protection.cardsLeft)/\(protection.cardsPerMonth), pending: \(protection.pendingDate ?? "—")"
        }
        return description
    }

    /// 测补签卡时补出的连签天数：差一天拿周礼包，用卡签到就能顺带看到礼包；没拿到周礼包规则时按 6 天。
    ///
    /// - Parameter aiPoints: 当前账号的 AI 点数与签到状态。
    private func protectionTestStreak(_ aiPoints: AIPointsStore) -> Int {
        max((aiPoints.checkInStatus?.rule(for: .weekly)?.everyDays ?? 7) - 1, 1)
    }

    /// 补签卡测试按钮的文案，例如“连签 6 天、昨天漏签（今天可用补签卡）”。
    ///
    /// - Parameters:
    ///   - key: 文案的本地化键。
    ///   - streak: 补出的连签天数。
    private func protectionTitle(_ key: String, streak: Int) -> String {
        AccountLocalization.formatted(key, value: streak.formatted(.number.locale(locale)), locale: locale)
    }

    /// 把连签设成差一天拿到这档礼包的按钮文案，例如“连签设为 6 天（今天签到得周礼包）”。
    ///
    /// - Parameter rule: 这档礼包的规则。
    private func streakTitle(for rule: AICheckInGiftRule) -> String {
        String(
            format: text("developer.checkIn.streak"),
            locale: locale,
            max(rule.everyDays - 1, 0).formatted(.number.locale(locale)),
            text(rule.tier.titleKey)
        )
    }

    /// 在服务端重置签到，完成后在脚注里显示结果。
    ///
    /// - Parameters:
    ///   - aiPoints: 当前账号的 AI 点数与签到状态。
    ///   - options: 补几天连签（0 为清空）、昨天是否漏签、本月的补签卡是否已用。
    private func resetCheckIn(_ aiPoints: AIPointsStore, _ options: AICheckInResetOptions) {
        isResettingCheckIn = true
        checkInToolResult = nil
        Task {
            let result = await aiPoints.resetCheckInForTesting(options)
            isResettingCheckIn = false
            switch result {
            case .success:
                checkInToolResult = text("developer.checkIn.done.reset")
            case let .failure(error):
                checkInToolResult = AccountLocalization.formatted(
                    "developer.checkIn.failed",
                    value: String(describing: error),
                    locale: locale
                )
            }
        }
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
        AppVersion.string()
    }

    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}
#endif
