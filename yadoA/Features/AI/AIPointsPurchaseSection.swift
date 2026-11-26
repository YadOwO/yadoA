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

    /// 一个商品：左边点数和标签（订阅再加周期，活动再加结束时间），右边价格按钮；购买中按钮转圈，其他商品的按钮暂时不能点。
    ///
    /// 标签有活动（新人专享、限时多送）时优先显示活动标签，没有活动时才显示角标；没有活动的商品和以前完全一样。
    /// 新人包整行突出：换成礼物图标，并铺一层浅浅的强调色底。
    ///
    /// - Parameters:
    ///   - offer: 商品。
    ///   - shop: 点数充值。
    private func offerRow(_ offer: AIPointsShop.Offer, shop: AIPointsShop) -> some View {
        let isPurchasing = shop.purchasingProductID == offer.id
        let item = offer.item
        let tag = tagText(item)
        let titleText = titlePointsText(item)
        // 朗读：点数（含多送）、活动标签（有活动时）、价格；没有活动时和以前一样只读点数和价格
        var spokenParts = [titleText]
        if hasPromotionTag(item), let tag {
            spokenParts.append(tag)
        }
        spokenParts.append(offer.product.displayPrice)
        return HStack(spacing: 14) {
            Image(systemName: item.isStarter ? "gift.fill" : "sparkles")
                .font(.system(size: 19))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                if hasPromotionTag(item), let tag {
                    // 点数文字加上多送点数和标签可能一行放不下，放不下时标签换到点数下面
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            pointsTitle(titleText)
                            tagCapsule(tag)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            pointsTitle(titleText)
                            tagCapsule(tag)
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        pointsTitle(titleText)
                        if let tag {
                            tagCapsule(tag)
                        }
                    }
                }
                if let detailText = promotionDetailText(item) ?? periodText(offer.product) {
                    Text(detailText)
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
            .accessibilityLabel(Text(verbatim: spokenParts.joined(separator: ", ")))
            .accessibilityHint(text("ai.store.purchase.hint"))
            .accessibilityIdentifier("ai-points-store-buy-\(offer.item.points)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background {
            if item.isStarter {
                // 用语义色的浅底，浅色和深色外观都正常；四周留一点边，不压住卡片的手绘边框
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
            }
        }
    }

    /// 点数文本，例如“300 点”。
    ///
    /// - Parameter points: 点数。
    private func pointsText(_ points: Int) -> String {
        AccountLocalization.formatted("ai.store.points", value: points.formatted(.number.locale(locale)), locale: locale)
    }

    /// 商品标题里的点数文本：限时多送那一档在基础点数后面接上多送点数，例如“180 点 + 送 40”；其余只有基础点数。
    ///
    /// - Parameter item: 服务端的商品信息。
    private func titlePointsText(_ item: AIStoreItem) -> String {
        guard let bonusPoints = item.activeBonusPoints else { return pointsText(item.points) }
        let bonusText = AccountLocalization.formatted(
            "ai.store.promotion.bonusPoints",
            value: bonusPoints.formatted(.number.locale(locale)),
            locale: locale
        )
        return "\(pointsText(item.points)) \(bonusText)"
    }

    /// 商品是否带活动标签：新人包，或者有多送点数的限时多送档；活动类型不认识或没有多送点数时按普通商品。
    ///
    /// - Parameter item: 服务端的商品信息。
    private func hasPromotionTag(_ item: AIStoreItem) -> Bool {
        item.isStarter || item.activeBonusPoints != nil
    }

    /// 商品的标签文字：有活动时优先显示活动标签，没有活动时才显示角标；都没有为 nil。
    ///
    /// - Parameter item: 服务端的商品信息。
    private func tagText(_ item: AIStoreItem) -> String? {
        if item.isStarter {
            return text("ai.store.promotion.starter")
        }
        if item.activeBonusPoints != nil {
            return text("ai.store.promotion.bonus")
        }
        return item.badge.map { text($0.titleKey) }
    }

    /// 活动的副行文字：新人包是资格还剩几天（按此刻算，不足一天按 1 天），限时多送是结束日期；没有活动或没有结束时间为 nil。
    ///
    /// - Parameter item: 服务端的商品信息。
    private func promotionDetailText(_ item: AIStoreItem) -> String? {
        guard let endsAt = item.promotionEndsAt else { return nil }
        if item.isStarter {
            guard let days = AIPointsShop.starterDaysLeft(endsAt: endsAt, now: Date()) else { return nil }
            return AccountLocalization.formatted(
                "ai.store.promotion.daysLeft",
                value: days.formatted(.number.locale(locale)),
                locale: locale
            )
        }
        if item.activeBonusPoints != nil {
            return AccountLocalization.formatted("ai.store.promotion.endsOn", value: endDateText(endsAt), locale: locale)
        }
        return nil
    }

    /// 限时多送的结束日期，取用户本地时区的月日，例如“11/30”。
    ///
    /// - Parameter date: 活动结束的时刻。
    private func endDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = .current
        formatter.setLocalizedDateFormatFromTemplate("Md")
        return formatter.string(from: date)
    }

    /// 标题里的点数文字。
    ///
    /// - Parameter content: 已经格式化好的点数文本。
    private func pointsTitle(_ content: String) -> some View {
        Text(content)
            .font(.body.weight(.medium))
            .monospacedDigit()
    }

    /// 点数旁边的胶囊标签：活动标签和角标共用同一个样式。
    ///
    /// - Parameter content: 标签文字。
    private func tagCapsule(_ content: String) -> some View {
        Text(content)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(Color.accentColor)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
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
