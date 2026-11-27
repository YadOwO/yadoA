import SwiftUI

/// “我的 › 数据联动”：列出可以联动的芽豆有物和它的状态，授权、查看估值、调整设置、取消授权。
///
/// - 未授权：一个「授权」按钮，打开 `DataLinkConsentSheet`。
/// - 已授权：估值金额和更新时间，下面是三个估值设置（`ItemValuationSettingsSection`），最下面是红色的「取消授权」，点了先二次确认。
///
/// 是否授权以 hub 为准：进入页面先拉联动列表，再拉汇总；汇总 5 分钟内不重复拉，拉不到时显示上次的数据和它的更新时间。
/// 没登录、离线、hub 没打开这个来源时只显示一句说明，不会崩。
struct DataLinksView: View {
    @Environment(\.locale) private var locale
    @Environment(\.ledgerCurrencyCode) private var currencyCode
    /// 联动状态；预览中没有注入时为 nil。
    @Environment(DataLinkStore.self) private var dataLinks: DataLinkStore?
    /// 全局登录状态；读它是为了登录和退出登录时重绘。预览中没有注入时为 nil。
    @Environment(AuthStore.self) private var authStore: AuthStore?
    /// 隐私政策同意状态；读它是为了同意或重新进入离线模式时重绘。预览中没有注入时为 nil。
    @Environment(PrivacyAgreementStore.self) private var privacyAgreement: PrivacyAgreementStore?

    /// 是否正在显示授权弹层。
    @State private var isPresentingConsent = false

    /// 是否正在显示取消授权的二次确认。
    @State private var isConfirmingRevoke = false

    /// 正在取消授权：「取消授权」按钮禁用。
    @State private var isRevoking = false

    /// 取消授权失败的提示是否在显示。
    @State private var isRevokeFailurePresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(text("dataLink.intro"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)

                if let store = dataLinks, isSignedInOnline, store.isItemValueLinkAvailable {
                    sourceCard(store)

                    if store.isItemValueGranted {
                        ItemValuationSettingsSection(store: store)
                        revokeSection
                    }
                } else {
                    Text(text("dataLink.unavailable"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                        .accessibilityIdentifier("data-link-unavailable")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        // 宽屏单栏时居中排成阅读宽度；内容自己带 20pt 左右留白
        .readableContentWidth()
        .paperPage()
        .navigationTitle(text("dataLink.title"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isPresentingConsent) {
            if let dataLinks {
                DataLinkConsentSheet(store: dataLinks)
            }
        }
        .confirmationDialog(
            text("dataLink.revoke.confirm.title"),
            isPresented: $isConfirmingRevoke,
            titleVisibility: .visible
        ) {
            Button(text("dataLink.revoke.confirm.action"), role: .destructive) {
                Task { await revoke() }
            }
            .accessibilityIdentifier("data-link-revoke-confirm")

            Button(text("common.cancel"), role: .cancel) {}
        } message: {
            Text(text("dataLink.revoke.confirm.message"))
        }
        .alert(text("dataLink.revoke.failed"), isPresented: $isRevokeFailurePresented) {
            Button(text("common.close"), role: .cancel) {}
        }
        .task {
            await dataLinks?.refreshLinks()
            await dataLinks?.refreshItemValueIfStale()
        }
    }

    /// 已登录且允许联网；没登录或离线时联动都不可用。
    private var isSignedInOnline: Bool {
        (authStore?.isAuthenticated ?? true) && (privacyAgreement?.allowsNetwork ?? true)
    }

    /// 芽豆有物的卡片：名称和状态；未授权时有「授权」按钮，已授权时显示估值和更新时间。
    ///
    /// - Parameter store: 联动状态。
    private func sourceCard(_ store: DataLinkStore) -> some View {
        let state = store.linkState
        let summary = store.cachedSummary

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                AccountIconView(
                    presentation: AccountIconPresentation(brandImageName: nil, symbolName: "shippingbox.fill", tint: .secondary),
                    size: 44
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(text("dataLink.source.name"))
                        .font(.system(.headline, design: .serif, weight: .semibold))
                    Text(stateText(state))
                        .font(.subheadline)
                        .foregroundStyle(state == .notGranted ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color(.ledgerGreen)))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("data-link-state")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if state == .notGranted {
                Button {
                    isPresentingConsent = true
                } label: {
                    Text(text("dataLink.action.grant"))
                        .font(.body.weight(.medium))
                        .padding(.horizontal, 16)
                        .onAccentForeground()
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .accessibilityIdentifier("data-link-grant")
            } else {
                grantedDetails(store: store, summary: summary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ledgerFormBorder(seed: "dataLink.source.\(DataLinkCode.source)".handDrawnSeed)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("data-link-card")
    }

    /// 已授权时卡片下半部分：估值金额、更新时间，拉不到时的说明。
    ///
    /// - Parameters:
    ///   - store: 联动状态。
    ///   - summary: 本机缓存的汇总；还没取到时为 nil。
    @ViewBuilder
    private func grantedDetails(store: DataLinkStore, summary: ItemValueSummary?) -> some View {
        if let valuation = store.accountValuation {
            Text(valuation.formattedCurrency(locale: locale, currencyCode: currencyCode))
                .font(.system(.largeTitle, design: .serif, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .accessibilityIdentifier("data-link-valuation")
        }

        if let summary {
            Text(AccountLocalization.formatted(
                "dataLink.updatedAt.format",
                value: summary.fetchedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)),
                locale: locale
            ))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("data-link-updated-at")
        }

        if store.lastSummaryFailure != nil {
            Text(text(summary == nil ? "dataLink.loadFailed.noCache" : "dataLink.loadFailed"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("data-link-load-failed")
        } else if summary == nil, store.isRefreshingSummary {
            ProgressView()
        }
    }

    /// 红色的「取消授权」，点了先弹二次确认。
    private var revokeSection: some View {
        ProfileSettingsSection(nil, seed: "dataLink.revoke") {
            Button(role: .destructive) {
                isConfirmingRevoke = true
            } label: {
                Label(text("dataLink.action.revoke"), systemImage: "xmark.circle")
            }
            .labelStyle(ProfileExportLabelStyle(color: .red))
            .buttonStyle(.plain)
            .disabled(isRevoking)
            .accessibilityIdentifier("data-link-revoke")
        }
    }

    /// 确认后取消授权；失败时授权状态保持原样，弹提示。
    private func revoke() async {
        guard let dataLinks, !isRevoking else { return }
        isRevoking = true
        defer { isRevoking = false }
        if case .failure = await dataLinks.revoke() {
            isRevokeFailurePresented = true
        }
    }

    /// 四种联动状态对应的文案。
    ///
    /// - Parameter state: 联动状态。
    private func stateText(_ state: ItemValueLinkState) -> String {
        switch state {
        case .notGranted:
            text("dataLink.state.notGranted")
        case .linked:
            text("dataLink.state.linked")
        case .linkedNoItems:
            text("dataLink.state.linkedNoItems")
        case .linkedNoPrices:
            text("dataLink.state.linkedNoPrices")
        }
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

#Preview {
    NavigationStack { DataLinksView() }
}
