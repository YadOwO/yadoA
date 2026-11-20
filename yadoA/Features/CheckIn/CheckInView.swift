import SwiftUI

/// “我的 › 每日签到”：连签天数与今天的签到、本月补签卡，待开的礼包，各档礼包还差几天，按月翻看的签到日历，以及签到规则。
///
/// 签到状态（连签天数、待开礼包、礼包规则）来自根部注入的 `AIPointsStore`，进入页面和下拉时刷新；
/// 签到日历按月向服务端现查，查过的月份留在页面里，签到后重查当月。能翻到的月份最早是第一次签到的那个月，最晚是当前月份。
/// 签到复用“我的”页的签到气泡和庆祝动画；签到得到礼包时，庆祝结束后直接弹出开礼包的整屏（`CheckInGiftOpeningView`）。
struct CheckInView: View {
    @Environment(\.locale) private var locale
    @Environment(AuthStore.self) private var authStore
    /// 当前账号的 AI 点数与签到状态；预览中没有注入时为 nil。
    @Environment(AIPointsStore.self) private var points: AIPointsStore?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 日历正在显示的月份；还没拿到签到状态时为 nil。
    @State private var displayedMonth: CheckInCalendarMonth?

    /// 查过的月份，按 `YYYY-MM` 存。
    @State private var months: [String: AICheckInMonth] = [:]

    /// 加载失败的月份。
    @State private var failedMonths: Set<String> = []

    /// 正在加载的月份。
    @State private var loadingMonths: Set<String> = []

    /// 各月份最近一次查询的编号；同一个月份前后查了两次时，晚回来的旧结果按编号丢弃。
    @State private var monthRequestIDs: [String: Int] = [:]

    /// 是否正在刷新签到状态；第一次进入页面时显示加载中。
    @State private var isRefreshingStatus = false

    /// 签到庆祝动画进行中；store 已把状态改为已签，靠它让气泡留到动画结束。
    @State private var isCheckInBadgeActive = false

    /// 刚签到得到、等庆祝结束后要开的礼包。
    @State private var pendingGift: AICheckInGift?

    /// 正在开的礼包，非空时弹出开礼包的整屏。
    @State private var openingGift: AICheckInGift?

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                streakCard

                if let status {
                    if !status.gifts.isEmpty {
                        giftsSection(status.gifts)
                    }
                    if !status.giftTiers.isEmpty {
                        milestonesSection(status)
                    }
                }

                calendarSection

                if let status {
                    rulesSection(status)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 32)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .paperPage()
        .navigationTitle(text("checkIn.title"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .task(id: authStore.isAuthenticated) { await reload() }
        .fullScreenCover(item: $openingGift) { gift in
            CheckInGiftOpeningView(
                gift: gift,
                onOpen: { await points?.openGift($0) ?? .failure(.notSignedIn) },
                onClose: { openingGift = nil }
            )
        }
    }

    // MARK: - 数据

    /// 当前的签到状态；未登录、还没拿到或拿失败时为 nil。
    private var status: AICheckInStatus? {
        points?.checkInStatus
    }

    /// 服务端的今天所在的月份，日历最晚翻到这里。
    private var latestMonth: CheckInCalendarMonth? {
        status.flatMap { CheckInCalendarMonth($0.date) }
    }

    /// 第一次签到所在的月份，日历最早翻到这里；从没签过时与当前月份相同。
    private var earliestMonth: CheckInCalendarMonth? {
        guard let latestMonth else { return nil }
        return status?.firstCheckInDate.flatMap { CheckInCalendarMonth($0) } ?? latestMonth
    }

    /// 刷新签到状态，把日历夹在能翻到的范围内，并重查正在显示的月份。
    private func reload() async {
        guard let points else { return }
        isRefreshingStatus = true
        await points.refreshCheckInStatus()
        isRefreshingStatus = false
        guard let latestMonth, let earliestMonth else { return }
        let month = (displayedMonth ?? latestMonth).clamped(lower: earliestMonth, upper: latestMonth)
        displayedMonth = month
        await loadMonth(month, force: true)
    }

    /// 查询某个月的签到日历；查过或正在查、且不要求重查时直接用页面里的。
    ///
    /// 要求重查时即使这个月正在查也另发一次（例如签到后），以最后发起的那次为准。
    ///
    /// - Parameters:
    ///   - month: 月份。
    ///   - force: 是否忽略已有数据重新查询。
    private func loadMonth(_ month: CheckInCalendarMonth, force: Bool) async {
        let key = month.text
        guard let points, force || (months[key] == nil && !loadingMonths.contains(key)) else { return }
        let requestID = (monthRequestIDs[key] ?? 0) + 1
        monthRequestIDs[key] = requestID
        loadingMonths.insert(key)
        let outcome = await points.fetchCheckInMonth(key)
        guard monthRequestIDs[key] == requestID else { return }
        loadingMonths.remove(key)
        switch outcome {
        case let .success(data):
            months[key] = data
            failedMonths.remove(key)
        case .failure:
            failedMonths.insert(key)
        }
    }

    /// 切到相邻的月份并按需加载。
    private func showMonth(_ month: CheckInCalendarMonth) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
            displayedMonth = month
        }
        Task { await loadMonth(month, force: false) }
    }

    // MARK: - 连签与今天

    /// 页顶的卡片：连签天数、今天签没签，以及签到气泡或“已签到”的印章。
    private var streakCard: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                streakFigure
                    .frame(minHeight: 64, alignment: .leading)

                Text(text("checkIn.streak.caption"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(todayLine)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)

                if let protection = status?.protection, protection.isEnabled {
                    protectionCardsLine(protection)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("check-in-streak")

            checkInControl
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .glassSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// 连签天数的大数字；还没拿到时显示加载中或占位横线。
    @ViewBuilder
    private var streakFigure: some View {
        if let status {
            Text(status.streak.formatted(.number.locale(locale)))
                .font(.system(size: 56, weight: .semibold, design: .serif))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(status.streak)))
                .animation(reduceMotion ? nil : .default, value: status.streak)
        } else if isRefreshingStatus {
            ProgressView()
        } else {
            Text(verbatim: "—")
                .font(.system(size: 56, weight: .semibold, design: .serif))
                .foregroundStyle(.tertiary)
        }
    }

    /// 连签天数下面的一行：今天签了显示得了几点，没签时说明签到后是连签第几天；昨天漏签、今天能用补签卡时说明可以保住几天连签；
    /// 取不到状态时提示下拉重试。
    private var todayLine: String {
        guard let status else {
            return text(isRefreshingStatus ? "checkIn.status.loading" : "checkIn.status.failed")
        }
        if status.checkedIn, let record = status.checkIn {
            return AccountLocalization.formatted(
                "checkIn.today.done",
                value: record.points.formatted(.number.locale(locale)),
                locale: locale
            )
        }
        if let offer = status.protectionOffer {
            return AccountLocalization.formatted(
                "checkIn.today.protectable",
                value: offer.keptStreak.formatted(.number.locale(locale)),
                locale: locale
            )
        }
        guard status.streak > 0 else { return text("checkIn.today.start") }
        return AccountLocalization.formatted(
            "checkIn.today.continue",
            value: (status.streak + 1).formatted(.number.locale(locale)),
            locale: locale
        )
    }

    /// 本月补签卡还剩几张的一行，例如“本月补签卡：1 张”，用完时“本月补签卡：已用完”。
    private func protectionCardsLine(_ protection: AICheckInProtection) -> some View {
        Label {
            Text(
                protection.cardsLeft > 0
                    ? AccountLocalization.formatted(
                        "checkIn.protection.cardsLeft",
                        value: protection.cardsLeft.formatted(.number.locale(locale)),
                        locale: locale
                    )
                    : text("checkIn.protection.cardsUsedUp")
            )
        } icon: {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(Color(.ledgerGreen))
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("check-in-protection-cards")
    }

    /// 右侧：今天还没签时是签到气泡，签过了是“已签到”的印章。
    @ViewBuilder
    private var checkInControl: some View {
        if points?.shouldOfferCheckIn == true || isCheckInBadgeActive {
            ProfileCheckInBadge(
                placement: ProfileCheckInPlacement(isLeading: false, verticalFraction: 0.4),
                messageWidth: 120,
                protectionOffer: status?.protectionOffer,
                onTap: handleCheckInTap,
                onFinished: finishCheckIn
            )
            .frame(width: 72, height: 72)
            .transition(.opacity)
        } else if status?.checkedIn == true {
            checkedStamp
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }

    /// 已签到的印章：账本绿色块上一个对勾。
    private var checkedStamp: some View {
        VStack(spacing: 2) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Color(.ledgerGreen))
            Text(text("checkIn.stamp"))
                .font(.system(.caption, design: .serif, weight: .semibold))
        }
        .frame(width: 72, height: 72)
        .background(HandDrawnBlob(seed: 11).fill(Color(.ledgerGreen).opacity(0.14)))
        .rotationEffect(.degrees(-8))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("check-in-stamp")
    }

    /// 点签到气泡：发起签到，动画结束前保持气泡显示；记下这次得到的礼包，庆祝结束后弹出开礼包。
    ///
    /// - Parameter useCard: 用户是否在弹窗里选了用补签卡。
    private func handleCheckInTap(useCard: Bool) async -> CheckInTapOutcome {
        guard let points else { return .failure(.notSignedIn) }
        isCheckInBadgeActive = true
        switch await points.checkIn(useCard: useCard) {
        case let .success(result):
            pendingGift = result.newGifts.first
            return .success(result)
        case let .failure(error):
            isCheckInBadgeActive = false
            return .failure(error)
        }
    }

    /// 签到庆祝结束：收起气泡，有新礼包就弹出开礼包，并重查当月日历。
    private func finishCheckIn() {
        withAnimation(.easeInOut(duration: 0.25)) {
            isCheckInBadgeActive = false
        }
        if let pending = pendingGift {
            pendingGift = nil
            // 庆祝期间用户可能已经从列表里开过：以 store 里最新的为准，已开完或已经弹出开礼包时不再弹
            if openingGift == nil, let latest = points?.unopenedGifts.first(where: { $0.id == pending.id }) {
                openingGift = latest
            }
        }
        if let latestMonth {
            Task { await loadMonth(latestMonth, force: true) }
        }
    }

    // MARK: - 待开礼包

    /// 待开的礼包：每个一行，点整行或“开启”都弹出开礼包的整屏。
    private func giftsSection(_ gifts: [AICheckInGift]) -> some View {
        ProfileSettingsSection("checkIn.gifts.section") {
            ForEach(Array(gifts.enumerated()), id: \.element.id) { index, gift in
                if index > 0 {
                    ProfileSettingsRowDivider()
                }
                Button {
                    openingGift = gift
                } label: {
                    giftRow(gift)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("check-in-gift-\(gift.id)")
            }
        }
    }

    /// 一个待开礼包的行：礼盒小图、名称和来历、还能开几次、“开启”。
    private func giftRow(_ gift: AICheckInGift) -> some View {
        HStack(spacing: 14) {
            CheckInGiftBox(tier: gift.tier)
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text(text(gift.tier.titleKey))
                    .font(.body.weight(.semibold))
                Text(giftDetail(gift))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(text("checkIn.gift.open"))
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(gift.tier.tint.opacity(0.18)))
                .overlay(Capsule().strokeBorder(gift.tier.tint.opacity(0.6), lineWidth: 1))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// 礼包行的说明：连签几天获得；开过一次的再写还能开几次。
    private func giftDetail(_ gift: AICheckInGift) -> String {
        let earned = AccountLocalization.formatted(
            "checkIn.gift.earned",
            value: gift.streak.formatted(.number.locale(locale)),
            locale: locale
        )
        guard gift.totalOpens > 1 else { return earned }
        let left = AccountLocalization.formatted(
            "checkIn.gift.opensLeft",
            value: gift.remainingOpens.formatted(.number.locale(locale)),
            locale: locale
        )
        return "\(earned) · \(left)"
    }

    // MARK: - 连签礼包进度

    /// 各档礼包：规则和离下一个还差几天。
    private func milestonesSection(_ status: AICheckInStatus) -> some View {
        ProfileSettingsSection("checkIn.milestones.section") {
            ForEach(Array(status.giftTiers.enumerated()), id: \.offset) { index, rule in
                if index > 0 {
                    ProfileSettingsRowDivider()
                }
                milestoneRow(rule, status: status)
            }
        }
    }

    /// 一档礼包的进度行。
    private func milestoneRow(_ rule: AICheckInGiftRule, status: AICheckInStatus) -> some View {
        let progress = rule.progress(streak: status.streak)
        return HStack(alignment: .top, spacing: 14) {
            CheckInGiftBox(tier: rule.tier)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(text(rule.tier.titleKey))
                        .font(.body.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(daysLeftText(rule, status: status))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(rule.tier.tint)
                        .multilineTextAlignment(.trailing)
                }

                Text(ruleText(rule))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                CheckInProgressBar(progress: progress, tint: rule.tier.tint, seed: rule.tier.artSeed)
                    .frame(height: 8)
                    .animation(reduceMotion ? nil : .snappy, value: progress)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }

    /// 离下一个这档礼包还差几天：只差今天时说“今天签到就能拿到”，今天已签、明天就到时说“明天签到就能拿到”。
    private func daysLeftText(_ rule: AICheckInGiftRule, status: AICheckInStatus) -> String {
        guard let days = rule.daysUntilNext(streak: status.streak) else { return "" }
        if days == 1 {
            return text(status.checkedIn ? "checkIn.milestone.tomorrow" : "checkIn.milestone.today")
        }
        return AccountLocalization.formatted(
            "checkIn.milestone.daysLeft",
            value: days.formatted(.number.locale(locale)),
            locale: locale
        )
    }

    /// 一档礼包的规则文字，例如“每连签 7 天 · 随机点数 · 7 天有效”；能开几次的再加上“可开 2 次”。
    ///
    /// 不写具体能开出多少点，开出来才知道。
    private func ruleText(_ rule: AICheckInGiftRule) -> String {
        let base = String(
            format: text("checkIn.milestone.rule"),
            locale: locale,
            rule.everyDays.formatted(.number.locale(locale)),
            rule.validDays.formatted(.number.locale(locale))
        )
        guard rule.openings.count > 1 else { return base }
        let opens = AccountLocalization.formatted(
            "checkIn.milestone.opens",
            value: rule.openings.count.formatted(.number.locale(locale)),
            locale: locale
        )
        return "\(base) · \(opens)"
    }

    // MARK: - 日历

    /// 签到日历；还没拿到签到状态时不显示格子，只留标题。
    @ViewBuilder
    private var calendarSection: some View {
        if let month = displayedMonth, let earliestMonth, let latestMonth {
            ProfileSettingsSection("checkIn.calendar.section") {
                CheckInCalendarView(
                    month: month,
                    data: months[month.text],
                    today: status?.date,
                    isLoading: loadingMonths.contains(month.text),
                    didFail: failedMonths.contains(month.text),
                    canGoBack: month > earliestMonth,
                    canGoForward: month < latestMonth,
                    onPrevious: { showMonth(month.previous) },
                    onNext: { showMonth(month.next) },
                    onRetry: { Task { await loadMonth(month, force: true) } }
                )
            }
        }
    }

    // MARK: - 规则

    /// 签到规则：每天的点数范围和有效期、断签、礼包不过期、补签卡、按北京时间换日。
    private func rulesSection(_ status: AICheckInStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text("checkIn.rules.section"))
                .font(.system(.subheadline, design: .serif, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(ruleLines(status), id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "·")
                            .accessibilityHidden(true)
                        Text(line)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }

    /// 规则的各行文字；每天签到只说领随机点数，不写具体范围。
    private func ruleLines(_ status: AICheckInStatus) -> [String] {
        var lines = [
            AccountLocalization.formatted(
                "checkIn.rules.daily",
                value: (status.validHours ?? 24).formatted(.number.locale(locale)),
                locale: locale
            )
        ]
        if !status.giftTiers.isEmpty {
            lines.append(text("checkIn.rules.streak"))
            lines.append(text("checkIn.rules.gifts"))
        }
        if let protection = status.protection, protection.isEnabled {
            lines.append(
                AccountLocalization.formatted(
                    "checkIn.rules.protection",
                    value: protection.cardsPerMonth.formatted(.number.locale(locale)),
                    locale: locale
                )
            )
        }
        lines.append(text("checkIn.rules.timezone"))
        return lines
    }

    /// 按应用当前语言解析文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 礼包进度条：手绘方框里一段主色的填充。
private struct CheckInProgressBar: View {
    /// 进度，0 到 1。
    let progress: Double

    /// 填充色。
    let tint: Color

    /// 边框笔迹种子。
    let seed: UInt64

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(tint.opacity(0.12))
                Capsule()
                    .fill(tint)
                    .frame(width: max(progress > 0 ? proxy.size.height : 0, proxy.size.width * progress))
                HandDrawnBox(cornerRadius: proxy.size.height / 2, seed: seed)
                    .stroke(Color.primary.opacity(0.3), style: StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview {
    NavigationStack {
        CheckInView()
    }
    .environment(AuthStore())
}
