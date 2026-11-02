import SwiftUI

/// “我的 › AI 点数 › 帮助改进 AI”：开关和完整说明放在同一页，打开前能看清上报什么、存多久。
///
/// 默认关闭，只有用户主动打开才上报；按账号保存在本机，由根部注入的 `AIPointsStore` 读写。
struct AITraceConsentView: View {
    @Environment(\.locale) private var locale
    /// 当前账号的 AI 点数；预览中没有注入时为 nil。
    @Environment(AIPointsStore.self) private var points: AIPointsStore?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let points {
                    ProfileSettingsSection(nil, seed: "ai.traceConsent") {
                        Toggle(isOn: Binding(
                            get: { points.isTraceConsented },
                            set: { points.setTraceConsented($0) }
                        )) {
                            Label(text("ai.traceConsent.title"), systemImage: "hand.raised")
                                .labelStyle(ProfileSettingsLabelStyle())
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .accessibilityIdentifier("ai-trace-consent")
                    }
                }

                Text(text("ai.traceConsent.footnote"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .paperPage()
        .navigationTitle(text("ai.traceConsent.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

#Preview {
    NavigationStack { AITraceConsentView() }
}
