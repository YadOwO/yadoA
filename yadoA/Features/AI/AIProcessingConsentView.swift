import SwiftUI

/// “AI 记账说明”的正文：发出哪些内容、发给谁、语音怎么处理、用途和保存时间，共四段。
///
/// 首次使用 AI 时的弹层（`AIProcessingConsentSheet`）和“我的 › AI 点数 › AI 记账说明”页（`AIProcessingConsentView`）共用。
struct AIProcessingConsentDetails: View {
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            section(symbol: "text.bubble", title: "ai.consent.data.title", body: "ai.consent.data.body")
            section(symbol: "server.rack", title: "ai.consent.recipient.title", body: "ai.consent.recipient.body")
            section(symbol: "waveform", title: "ai.consent.speech.title", body: "ai.consent.speech.body")
            section(symbol: "clock.arrow.circlepath", title: "ai.consent.purpose.title", body: "ai.consent.purpose.body")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 一段说明：图标、小标题和正文。
    ///
    /// - Parameters:
    ///   - symbol: SF Symbols 图标名。
    ///   - title: 小标题的本地化 key。
    ///   - body: 正文的本地化 key。
    private func section(symbol: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(AccountLocalization.string(title, locale: locale))
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(AccountLocalization.string(body, locale: locale))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 首次使用 AI 记账前弹出的“AI 记账说明”：讲清哪些内容会发出去，用户同意后才发请求。
///
/// 点“同意并继续”先把同意写进 `AIPointsStore`，再通知语音状态；点“暂不使用”或向下滑关掉都等同于不同意。
/// 弹层只继承挂载点外面的环境，读不到根导航环境里的语音状态，所以语音状态显式传入。
struct AIProcessingConsentSheet: View {
    @Environment(\.locale) private var locale
    /// 当前账号的 AI 点数；预览中没有注入时为 nil。
    @Environment(AIPointsStore.self) private var points: AIPointsStore?

    /// 与麦克风、会话卡片共享的语音状态。
    let voice: VoiceBookkeepingState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(text("ai.consent.title"))
                    .font(.system(.title, design: .serif, weight: .bold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(text("ai.consent.intro"))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                AIProcessingConsentDetails()
                Text(text("ai.consent.footnote"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button {
                    points?.setAIProcessingConsented(true)
                    voice.acceptAIConsent()
                } label: {
                    Text(text("ai.consent.agree"))
                }
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .accessibilityIdentifier("ai-consent-agree")

                Button {
                    voice.declineAIConsent()
                } label: {
                    Text(text("ai.consent.decline"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ai-consent-decline")
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
            .padding(.top, 8)
        }
        .paperPage()
        .presentationDetents([.large])
        .accessibilityIdentifier("ai-consent-sheet")
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// “我的 › AI 点数 › AI 记账说明”：完整说明和一个开关，关掉即撤回同意。
///
/// 同意状态按账号保存在本机，由根部注入的 `AIPointsStore` 读写；撤回后再使用 AI 时会重新弹出说明。
struct AIProcessingConsentView: View {
    @Environment(\.locale) private var locale
    /// 当前账号的 AI 点数；预览中没有注入时为 nil。
    @Environment(AIPointsStore.self) private var points: AIPointsStore?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                AIProcessingConsentDetails()
                    .padding(.horizontal, 20)

                if let points {
                    ProfileSettingsSection(nil, seed: "ai.processingConsent") {
                        Toggle(isOn: Binding(
                            get: { points.isAIProcessingConsented },
                            set: { points.setAIProcessingConsented($0) }
                        )) {
                            Label(text("ai.processingConsent.toggle"), systemImage: "checkmark.shield")
                                .labelStyle(ProfileSettingsLabelStyle())
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .accessibilityIdentifier("ai-processing-consent-toggle")
                    }
                }

                Text(text("ai.processingConsent.footnote"))
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
        .navigationTitle(text("ai.consent.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

extension View {
    /// 挂上“AI 记账说明”弹层；向下滑关掉等同于“暂不使用”，弹层完全关掉后再接着做同意后的事。
    ///
    /// 根导航和聊天页各挂一份：聊天页是全屏盖住的，根导航那份盖不上去，所以只让最上面一层弹。
    ///
    /// - Parameters:
    ///   - voice: 语音状态。
    ///   - isEnabled: 是否由这一层弹出。
    func aiProcessingConsentSheet(_ voice: VoiceBookkeepingState, isEnabled: Bool) -> some View {
        sheet(
            isPresented: Binding(
                get: { isEnabled && voice.isAIConsentPresented },
                set: { if !$0 { voice.declineAIConsent() } }
            ),
            onDismiss: { voice.finishAIConsent() }
        ) {
            AIProcessingConsentSheet(voice: voice)
        }
    }
}

#Preview("说明弹层") {
    AIProcessingConsentSheet(voice: VoiceBookkeepingState())
}

#Preview("说明页") {
    NavigationStack { AIProcessingConsentView() }
}
