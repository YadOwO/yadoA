#if DEBUG
import SwiftUI

/// 「我的 → 开发 → AI 服务」（开发入口在头像右上角）：显示当前环境的 yado_ai 地址并测试连接。只在 DEBUG 包存在。
///
/// 连哪一套由构建配置决定（见 `AppEnvironment`），这里不能切换。
struct AIServiceSettingsView: View {
    @Environment(\.locale) private var locale

    /// 连接测试的状态。
    private enum TestState: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    @State private var testState = TestState.idle

    var body: some View {
        Form {
            Section {
                LabeledContent(text("debug.aiService.current"), value: AuthConfig.aiServiceURL.absoluteString)
                    .font(.footnote.monospaced())
                Button(text("debug.aiService.test")) {
                    Task { await testConnection() }
                }
                .disabled(testState == .testing)
                switch testState {
                case .idle:
                    EmptyView()
                case .testing:
                    ProgressView()
                case let .success(message):
                    Text(message).foregroundStyle(.secondary)
                case let .failure(message):
                    Text(message).foregroundStyle(Color(.ledgerRed))
                }
            }
        }
        .navigationTitle(text("debug.aiService.title"))
        .navigationBarTitleDisplayMode(.inline)
        .paperPage()
    }

    /// 请求当前地址的 `/health`，显示耗时与模型是否已配置。
    private func testConnection() async {
        testState = .testing
        let url = AuthConfig.aiServiceURL.appending(path: "health")
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let startedAt = VoiceTimingClock.now
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let elapsed = VoiceTimingBreakdown.format(VoiceTimingClock.milliseconds(since: startedAt))
            guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
                testState = .failure(AccountLocalization.formatted(
                    "debug.aiService.test.failure", value: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)", locale: locale
                ))
                return
            }
            // 健康检查的 ai 字段：configured 或 not_configured
            let body = String(decoding: data, as: UTF8.self)
            let detail = body.contains("not_configured") ? "\(elapsed), ai: not_configured" : elapsed
            testState = .success(AccountLocalization.formatted("debug.aiService.test.success", value: detail, locale: locale))
        } catch {
            testState = .failure(AccountLocalization.formatted(
                "debug.aiService.test.failure", value: error.localizedDescription, locale: locale
            ))
        }
    }

    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}
#endif
