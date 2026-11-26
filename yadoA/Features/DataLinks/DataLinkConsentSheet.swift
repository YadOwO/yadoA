import SwiftUI

/// 授权芽豆有物联动前弹出的说明：讲清会读什么、不会读什么、怎么取消，用户同意后才调 hub 授权。
///
/// 外观照 `AIProcessingConsentSheet`：品牌落款、衬线大标题、简介、三段图标加小标题加正文，按钮固定在底部。
/// 点「同意并授权」后等授权完成：进行中禁用按钮并转圈，成功就关闭，失败在按钮上方留一行错误；
/// 点「暂不」或向下滑关掉都等同于不授权。弹层只继承挂载点外面的环境，所以联动状态显式传入。
struct DataLinkConsentSheet: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss

    /// 联动状态；点同意后用它授权。
    let store: DataLinkStore

    /// 正在授权：按钮禁用并转圈。
    @State private var isGranting = false

    /// 最近一次授权失败的原因；再次点同意时清空。
    @State private var failure: DataLinkAPIError?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 页首落款：告诉用户是谁在请求同意
                BrandLockup()
                    .padding(.bottom, 4)
                Text(text("dataLink.consent.title"))
                    .font(.system(.title, design: .serif, weight: .bold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(text("dataLink.consent.intro"))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 20) {
                    section(symbol: "shippingbox", title: "dataLink.consent.read.title", body: "dataLink.consent.read.body")
                    section(symbol: "eye.slash", title: "dataLink.consent.notRead.title", body: "dataLink.consent.notRead.body")
                    section(symbol: "arrow.uturn.backward.circle", title: "dataLink.consent.cancel.title", body: "dataLink.consent.cancel.body")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if let failure {
                    Text(failureMessage(failure))
                        .font(.footnote)
                        .foregroundStyle(Color(.ledgerRed))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("data-link-consent-error")
                }

                Button {
                    Task { await agree() }
                } label: {
                    ZStack {
                        Text(text("dataLink.consent.agree"))
                            .opacity(isGranting ? 0 : 1)
                        if isGranting {
                            // 按钮底是强调色（墨色），转圈用反色才看得见
                            ProgressView()
                                .tint(Color(.onAccent))
                        }
                    }
                }
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .disabled(isGranting)
                .accessibilityIdentifier("data-link-consent-agree")

                Button {
                    dismiss()
                } label: {
                    Text(text("dataLink.consent.decline"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isGranting)
                .accessibilityIdentifier("data-link-consent-decline")
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
            .padding(.top, 8)
            .background(Color(.paperBackground))
        }
        .paperPage()
        .presentationDetents([.large])
        // 授权进行中不允许下滑关闭，免得请求还在路上弹层就没了
        .interactiveDismissDisabled(isGranting)
        // 让弹层自成容器：按钮保留各自的标识，不被弹层这一层的标识盖掉
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("data-link-consent-sheet")
    }

    /// 点同意：调授权，成功就关闭，失败留一行错误。
    private func agree() async {
        guard !isGranting else { return }
        isGranting = true
        failure = nil
        let result = await store.grant()
        isGranting = false
        switch result {
        case .success:
            dismiss()
        case let .failure(error):
            failure = error
        }
    }

    /// 授权失败的提示：来源没打开和被限流单独说明，其余统一请用户稍后重试。
    ///
    /// - Parameter error: 失败原因。
    private func failureMessage(_ error: DataLinkAPIError) -> String {
        switch error {
        case .unavailable:
            text("dataLink.error.unavailable")
        case .upgradeRequired:
            text("dataLink.error.upgradeRequired")
        default:
            text("dataLink.consent.failed")
        }
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
                Text(text(title))
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(text(body))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

#Preview("授权弹层") {
    DataLinkConsentSheet(
        store: DataLinkStore(api: DataLinkAPI { throw ServiceAuthError.notSignedIn }, currentUserID: { nil })
    )
}
