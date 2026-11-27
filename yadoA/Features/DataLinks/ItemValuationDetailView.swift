import SwiftUI

/// “账户 › 物品估值”：从账户页那一行点进来，看估值怎么算出来的，并调整三个估值设置。
///
/// 依次是：估值大字，在用、退役物品的购入价合计，没填价格的件数，更新时间，下面是和数据联动页共用的设置。
/// 已经不再授权，或没有可显示的汇总时，只显示一句说明，告诉用户去「我的 › 数据联动」看。
/// 数据联动页的路由挂在「我的」的导航里，账户的导航里跳不过去，所以这里不做跨 Tab 跳转。
/// 本页自己不会关闭：取消授权发生在「我的」里，回到本页时显示说明即可。
struct ItemValuationDetailView: View {
    @Environment(\.locale) private var locale
    @Environment(\.ledgerCurrencyCode) private var currencyCode
    /// 联动状态；预览中没有注入时为 nil。
    @Environment(DataLinkStore.self) private var dataLinks: DataLinkStore?
    /// 全局登录状态；读它是为了登录和退出登录时重绘。预览中没有注入时为 nil。
    @Environment(AuthStore.self) private var authStore: AuthStore?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let store = dataLinks, authStore?.isAuthenticated ?? true, store.isItemValueGranted {
                    if let summary = store.cachedSummary {
                        valuationCard(store: store, summary: summary)
                        ItemValuationSettingsSection(store: store)
                    } else if store.isRefreshingSummary {
                        // 第一次取汇总还没回来：先转圈，不闪出「没有数据」的说明
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        unavailableCard
                    }
                } else {
                    unavailableCard
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        // 宽屏单栏时居中排成阅读宽度；内容自己带 20pt 左右留白
        .readableContentWidth()
        .paperPage()
        .navigationTitle(text("itemValuation.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await dataLinks?.refreshItemValueIfStale()
        }
    }

    /// 估值大字和它的来源：在用、退役购入价合计，没填价格的件数，更新时间。
    ///
    /// - Parameters:
    ///   - store: 联动状态。
    ///   - summary: 本机缓存的汇总。
    private func valuationCard(store: DataLinkStore, summary: ItemValueSummary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(text(store.settings.countsTowardNetWorth ? "itemValuation.amount.label" : "itemValuation.notCounted"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                Text(valuationText(store: store, summary: summary))
                    .font(.system(.largeTitle, design: .serif, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .accessibilityIdentifier("item-valuation-amount")

                Text(ItemValuationPresentation.detail(
                    summary: summary,
                    discountPercent: store.settings.discountPercent,
                    locale: locale,
                    currencyCode: currencyCode
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                metricRow(
                    title: "itemValuation.detail.inService",
                    value: summary.inServicePurchaseTotal.formattedCurrency(locale: locale, currencyCode: currencyCode),
                    identifier: "item-valuation-in-service"
                )
                metricRow(
                    title: "itemValuation.detail.retired",
                    value: summary.retiredPurchaseTotal.formattedCurrency(locale: locale, currencyCode: currencyCode),
                    identifier: "item-valuation-retired"
                )
                metricRow(
                    title: "itemValuation.detail.unpriced",
                    value: AccountLocalization.formatted(
                        "itemValuation.detail.count.format",
                        value: summary.unpricedItemCount.formatted(.number.locale(locale)),
                        locale: locale
                    ),
                    identifier: "item-valuation-unpriced"
                )
                metricRow(
                    title: "itemValuation.detail.updatedAt",
                    value: summary.fetchedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)),
                    identifier: "item-valuation-updated-at"
                )
            }

            if store.lastSummaryFailure != nil {
                Text(text("dataLink.loadFailed"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ledgerFormBorder(seed: "itemValuation.detail".handDrawnSeed)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("item-valuation-card")
    }

    /// 估值大字：有填价格的物品时是折算后的金额；一件都没填价格时是 ¥0.00，下面的件数会说明原因。
    private func valuationText(store: DataLinkStore, summary: ItemValueSummary) -> String {
        ItemValuation.amount(summary: summary, discountPercent: store.settings.discountPercent)
            .formattedCurrency(locale: locale, currencyCode: currencyCode)
    }

    /// 一行名称和数值，数值靠右。
    ///
    /// - Parameters:
    ///   - title: 名称的本地化 key。
    ///   - value: 已格式化的数值。
    ///   - identifier: 无障碍标识。
    private func metricRow(title: String, value: String, identifier: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(text(title))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(.body, design: .serif).monospacedDigit())
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    /// 没有可显示的估值：说明原因，以及去哪里重新授权或查看。
    private var unavailableCard: some View {
        Text(text("itemValuation.detail.unavailable"))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ledgerFormBorder(seed: "itemValuation.unavailable".handDrawnSeed)
            .accessibilityIdentifier("item-valuation-unavailable")
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

#Preview {
    NavigationStack { ItemValuationDetailView() }
}
