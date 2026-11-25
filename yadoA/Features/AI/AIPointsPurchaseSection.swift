import StoreKit
import SwiftUI

/// “AI 点数”页的充值区：服务端列出、StoreKit 查得到的点数包，点价格按钮用 Apple 账号付款，入账后弹出提示。
///
/// 只在登录后、且有可买的商品时出现（由 `AIPointsView` 判断登录，本视图在没有商品时什么都不画）。
/// 商品出现订阅时，额外显示续订说明、服务条款与隐私政策链接、管理订阅和恢复购买，这是 App Store 对订阅的要求；
/// 现在只卖点数包，这部分为以后开卖订阅预留，旧版 App 不用更新也能正确展示。
struct AIPointsPurchaseSection: View {
    @Environment(\.locale) private var locale
    /// 点数充值；预览中没有注入时为 nil。
    @Environment(AIPointsShop.self) private var shop: AIPointsShop?

    /// 是否在显示系统的管理订阅页。
    @State private var isManagingSubscriptions = false

    /// 是否正在恢复购买。
    @State private var isRestoring = false

    var body: some View {
        if let shop, !shop.offers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ProfileSettingsSection("ai.store.title") {
                    ForEach(Array(shop.offers.enumerated()), id: \.element.id) { index, offer in
                        if index > 0 {
                            ProfileSettingsRowDivider()
                        }
                        offerRow(offer, shop: shop)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("ai-points-store")

                footnote(text("ai.store.footnote"))

                if shop.hasSubscriptions {
                    subscriptionFooter(shop: shop)
                }
            }
            .alert(
                noticeTitle(shop.notice),
                isPresented: Binding(
                    get: { shop.notice != nil },
                    set: { isPresented in
                        if !isPresented { shop.dismissNotice() }
                    }
                ),
                presenting: shop.notice
            ) { _ in
                Button(text("common.close"), role: .cancel) {}
            } message: { notice in
                Text(noticeMessage(notice))
            }
            .manageSubscriptionsSheet(isPresented: $isManagingSubscriptions)
        }
    }

    // MARK: - 商品

    /// 一个商品：左边点数和角标（订阅再加周期），右边价格按钮；购买中按钮转圈，其他商品的按钮暂时不能点。
    ///
    /// - Parameters:
    ///   - offer: 商品。
    ///   - shop: 点数充值。
    private func offerRow(_ offer: AIPointsShop.Offer, shop: AIPointsShop) -> some View {
        let isPurchasing = shop.purchasingProductID == offer.id
        return HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 19))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(pointsText(offer.item.points))
                        .font(.body.weight(.medium))
                        .monospacedDigit()
                    if let badge = offer.item.badge {
                        Text(text(badge.titleKey))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .foregroundStyle(Color.accentColor)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                }
                if let periodText = periodText(offer.product) {
                    Text(periodText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Button {
                Task { await shop.purchase(offer) }
            } label: {
                ZStack {
                    // 转圈时保留价格的宽度，按钮不跳动
                    Text(offer.product.displayPrice)
                        .opacity(isPurchasing ? 0 : 1)
                    if isPurchasing {
                        ProgressView()
                    }
                }
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .padding(.horizontal, 4)
                .onAccentForeground()
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .disabled(shop.purchasingProductID != nil)
            .accessibilityLabel(Text(verbatim: "\(pointsText(offer.item.points)), \(offer.product.displayPrice)"))
            .accessibilityHint(text("ai.store.purchase.hint"))
            .accessibilityIdentifier("ai-points-store-buy-\(offer.item.points)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// 点数文本，例如“300 点”。
    ///
    /// - Parameter points: 点数。
    private func pointsText(_ points: Int) -> String {
        AccountLocalization.formatted("ai.store.points", value: points.formatted(.number.locale(locale)), locale: locale)
    }

    /// 订阅的周期文本，例如“每 1个月”；不是订阅时为 nil。
    ///
    /// - Parameter product: StoreKit 商品。
    private func periodText(_ product: AIStoreProduct) -> String? {
        guard let period = product.subscriptionPeriod else { return nil }
        var components = DateComponents()
        switch period.unit {
        case .day: components.day = period.value
        case .week: components.weekOfMonth = period.value
        case .month: components.month = period.value
        case .year: components.year = period.value
        }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        var calendar = Calendar.current
        calendar.locale = locale
        formatter.calendar = calendar
        guard let duration = formatter.string(from: components) else { return nil }
        return AccountLocalization.formatted("ai.store.period", value: duration, locale: locale)
    }

    // MARK: - 订阅

    /// 订阅的续订说明、服务条款与隐私政策、管理订阅和恢复购买。
    ///
    /// - Parameter shop: 点数充值。
    private func subscriptionFooter(shop: AIPointsShop) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            footnote(text("ai.store.subscription.terms"))

            HStack(spacing: 16) {
                ForEach([LegalDocument.terms, .privacy]) { document in
                    Link(text(document.titleLocalizationKey), destination: document.url(locale: locale))
                }
            }
            .font(.footnote)
            .padding(.horizontal, 20)

            HStack(spacing: 16) {
                Button(text("ai.store.manageSubscriptions")) {
                    isManagingSubscriptions = true
                }
                Button(text("ai.store.restore")) {
                    Task { await restore(shop: shop) }
                }
                .disabled(isRestoring)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 20)
        }
    }

    /// 恢复购买：让 StoreKit 和 App Store 同步一次，再补传没结束的交易。
    ///
    /// - Parameter shop: 点数充值。
    private func restore(shop: AIPointsShop) async {
        isRestoring = true
        defer { isRestoring = false }
        try? await AppStore.sync()
        await shop.processUnfinishedTransactions()
    }

    // MARK: - 提示

    /// 购买结果提示的标题。
    ///
    /// - Parameter notice: 购买结果；为 nil 时返回空字符串（提示不显示）。
    private func noticeTitle(_ notice: AIPointsShop.PurchaseNotice?) -> String {
        switch notice {
        case .credited: text("ai.store.notice.credited.title")
        case .pending: text("ai.store.notice.pending.title")
        case .creditDelayed: text("ai.store.notice.delayed.title")
        case .otherAccount: text("ai.store.notice.otherAccount.title")
        case .cannotCredit: text("ai.store.notice.cannotCredit.title")
        case .failed: text("ai.store.notice.failed.title")
        case nil: ""
        }
    }

    /// 购买结果提示的说明。
    ///
    /// - Parameter notice: 购买结果。
    private func noticeMessage(_ notice: AIPointsShop.PurchaseNotice) -> String {
        switch notice {
        case let .credited(points):
            AccountLocalization.formatted(
                "ai.store.notice.credited.message",
                value: points.formatted(.number.locale(locale)),
                locale: locale
            )
        case .pending: text("ai.store.notice.pending.message")
        case .creditDelayed: text("ai.store.notice.delayed.message")
        case .otherAccount: text("ai.store.notice.otherAccount.message")
        case .cannotCredit: text("ai.store.notice.cannotCredit.message")
        case .failed: text("ai.store.notice.failed.message")
        }
    }

    // MARK: - 通用

    /// 分组卡片下方的说明文字，与卡片内的标题对齐。
    ///
    /// - Parameter content: 说明文案。
    private func footnote(_ content: String) -> some View {
        Text(content)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 20)
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}
