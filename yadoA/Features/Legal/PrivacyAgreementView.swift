import SwiftUI

/// 中国大陆地区首次启动的隐私政策同意卡：全屏盖在界面最上层，用户做出选择之前不显示引导。
///
/// 列出要联网的四项功能（登录、云同步、AI 记账、意见反馈），点「同意」后才会联网；点「不同意」进入完全离线的本地记账模式。
/// 卡片本身不发任何请求；用户主动点《用户协议》《隐私政策》链接时，会在 App 内用 Safari 打开网页，这是用户自己的操作。
struct PrivacyAgreementView: View {
    @Environment(\.locale) private var locale

    /// 隐私政策同意状态。
    let store: PrivacyAgreementStore

    /// 正在 App 内打开的法律文档。
    @State private var presentedDocument: LegalDocument?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(text("privacy.agreement.title"))
                    .font(.system(.title, design: .serif, weight: .bold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(text("privacy.agreement.intro"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(PrivacyAgreementFeature.allCases) { feature in
                    featureRow(feature)
                }
                links
            }
            .padding(.horizontal, 24)
            .padding(.top, 48)
            .padding(.bottom, 24)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.paperBackground).ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { buttons }
        .legalDocumentSheet($presentedDocument)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("privacy-agreement-card")
    }

    // MARK: - 内容

    /// 一项要联网的功能：图标、小标题和一句说明。
    ///
    /// - Parameter feature: 功能项。
    private func featureRow(_ feature: PrivacyAgreementFeature) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: feature.systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(text("privacy.agreement.feature.\(feature.rawValue).title"))
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(text("privacy.agreement.feature.\(feature.rawValue).body"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// 带《用户协议》《隐私政策》链接的说明；点链接在 App 内打开，不交给系统。
    private var links: some View {
        Text(LegalDocument.linkedText("privacy.agreement.links", locale: locale))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .tint(Color.primary)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { url in
                guard let document = LegalDocument(linkURL: url) else { return .systemAction }
                presentedDocument = document
                return .handled
            })
            .accessibilityIdentifier("privacy-agreement-links")
    }

    /// 底部的「同意」「不同意」按钮。
    private var buttons: some View {
        VStack(spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.25)) { store.agree() }
            } label: {
                Text(text("privacy.agreement.agree"))
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .onAccentForeground()
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .accessibilityIdentifier("privacy-agreement-agree")

            Button {
                withAnimation(.easeOut(duration: 0.25)) { store.decline() }
            } label: {
                Text(text("privacy.agreement.decline"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("privacy-agreement-decline")
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .background(Color(.paperBackground))
    }

    /// 按当前语言取文案。
    ///
    /// - Parameter key: 本地化键。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 同意卡上列出的要联网的功能；原始值用于拼本地化键 `privacy.agreement.feature.<原始值>.title / .body`。
private enum PrivacyAgreementFeature: String, CaseIterable, Identifiable {
    /// 登录。
    case signIn
    /// 云同步。
    case sync
    /// AI 记账。
    case ai
    /// 意见反馈。
    case feedback

    /// 稳定标识。
    var id: String { rawValue }

    /// 行首图标。
    var systemImage: String {
        switch self {
        case .signIn: "person.crop.circle"
        case .sync: "icloud"
        case .ai: "sparkles"
        case .feedback: "bubble.left.and.text.bubble.right"
        }
    }
}

#Preview {
    PrivacyAgreementView(store: PrivacyAgreementStore(requiresAgreement: true))
}
