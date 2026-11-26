import SwiftData
import SwiftUI

/// “我的”Tab 根页面：页头承载登录身份，下方只放常用入口（账单、周期记账、分类）、AI 点数与每日签到、云端同步、数据联动（hub 打开了联动来源才有）、“设置”二级页、意见反馈和更多芽豆产品。
///
/// 页头的签到气泡登录后第一次出现时，从气泡弹出签到引导（`CheckInGuideCard`），每个账号只弹一次。
/// 签到成功后「+N 点」从气泡飞到「AI 点数」那一行，「AI 点数」「每日签到」两行的数字从签到前滚到新值（`CheckInRewardToken`）；
/// 签到得到连签礼包时，这段动画结束后直接弹出开礼包的整屏（`CheckInGiftOpeningView`）。
///
/// 语言、外观、默认账户、导入导出、退出登录等低频项统一收进 `SettingsView`，已停用账户由“账户”Tab 承载。
/// 进入二级页面都走路径导航（见 `ProfileRoute`），根导航据此判断是否显示语音入口；
/// 入口用 `TabRouteLink`，宽屏两栏时换掉右栏，而不是在右栏里继续往下推。
struct ProfileView: View {
    @Environment(\.locale) private var locale
    /// 全局登录状态；登录与否只影响页头身份，不影响本地账本。
    @Environment(AuthStore.self) private var authStore
    /// 整屏登录页的展示状态。
    @Environment(SignInPresentation.self) private var signInPresentation
    /// 云端同步的绑定与开关；预览中没有注入时为 nil。
    @Environment(SyncLifecycle.self) private var syncLifecycle: SyncLifecycle?
    /// 当前账号的 AI 点数；预览中没有注入时为 nil。
    @Environment(AIPointsStore.self) private var aiPoints: AIPointsStore?
    /// 意见反馈的未读回复数；预览中没有注入时为 nil。
    @Environment(FeedbackStore.self) private var feedback: FeedbackStore?
    /// 芽豆系列的产品目录；预览中没有注入时为 nil。
    @Environment(SeriesCatalogStore.self) private var seriesCatalog: SeriesCatalogStore?
    /// 数据联动状态；hub 打开了联动来源时才显示「数据联动」入口。预览中没有注入时为 nil。
    @Environment(DataLinkStore.self) private var dataLinks: DataLinkStore?
    /// 隐私政策同意状态；离线模式下隐藏所有联网入口。预览中没有注入时为 nil，按允许联网处理。
    @Environment(PrivacyAgreementStore.self) private var privacyAgreement: PrivacyAgreementStore?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 修改个人资料弹层，打开时携带当时的资料快照。
    @State private var editingProfile: AccountProfile?

    /// 签到气泡的随机位置，每次进入页面重新随机。
    @State private var checkInPlacement: ProfileCheckInPlacement = .random()

    /// 签到庆祝或淡出动画进行中；store 已把状态改为已签，靠它让气泡留到动画结束。
    @State private var isCheckInBadgeActive = false

    /// 是否正从签到气泡弹出签到引导。
    @State private var isCheckInGuidePresented = false

    /// 本页是否正显示在屏幕上；推入二级页或切到别的 Tab 时为 false，签到引导只在本页可见时弹出。
    @State private var isVisible = false

    /// 刚签到得到、等庆祝结束后要开的礼包。
    @State private var pendingGift: AICheckInGift?

    /// 正在开的礼包，非空时弹出开礼包的整屏。
    @State private var openingGift: AICheckInGift?

    /// 签到期间按住不变的「AI 点数」「每日签到」行尾，等奖励飞到再依次放开；为 nil 时两行都显示最新值。
    @State private var heldRewardRows: CheckInHeldRows?

    /// 气泡庆祝结束、要飞到「AI 点数」行的点数；由滚动视图那一层接手启动飞行，接手后清空。
    @State private var departingReward: Int?

    /// 正在飞的「+N 点」；为 nil 时没有在飞。
    @State private var rewardFlight: CheckInRewardFlight?

    /// 飞行和放开数字的整段流程是否在进行；进行中时这次得到的礼包等流程结束再弹。
    @State private var isRewardSequenceRunning = false

    /// 刚放开、正用账本绿提示的行。
    @State private var highlightedRewardRows: Set<CheckInRewardRow> = []

    /// 签到气泡中心在滚动内容里的位置，飞行的起点。
    @State private var checkInBubbleCenter: CGPoint?

    /// 「AI 点数」行在滚动内容里的位置，飞行的终点在它的行尾数字附近。
    @State private var pointsRowFrame: CGRect?

    /// 「AI 点数」「每日签到」两行是否基本都在屏幕上；不在时先滚过去再飞。
    @State private var areRewardRowsVisible = true

    /// 滚动内容的命名坐标空间：气泡、「AI 点数」行和飞行的小签都按它定位。
    nonisolated static let contentCoordinateSpace = "profile.content"

    /// 「AI 点数」「每日签到」所在分组的滚动标识。
    nonisolated static let rewardRowsID = "profile.rewardRows"

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(spacing: 28) {
                    profileHeader

                    ProfileSettingsSection(nil, seed: "profile.section.bookkeeping") {
                        // 账单是按月、按年回看的汇总，不是日常记账操作，放在这里不占记账页导航栏。
                        TabRouteLink(value: ProfileRoute.bills, selectionOutset: -4) {
                            ProfileSettingsRow(titleKey: "bill.title", symbol: "doc.text")
                        }
                        .accessibilityIdentifier("profile-bills")

                        ProfileSettingsRowDivider()

                        TabRouteLink(value: ProfileRoute.recurringRules, selectionOutset: -4) {
                            ProfileSettingsRow(titleKey: "recurring.title", symbol: "repeat")
                        }
                        .accessibilityIdentifier("profile-recurring")

                        ProfileSettingsRowDivider()

                        TabRouteLink(value: ProfileRoute.categories, selectionOutset: -4) {
                            ProfileSettingsRow(titleKey: "category.management.title", symbol: "square.grid.2x2")
                        }
                        .accessibilityIdentifier("profile-category-management")
                    }

                    // 离线模式（没同意隐私政策）下 AI、云同步和反馈都要联网，入口整体隐藏
                    if isNetworkAllowed {
                        ProfileSettingsSection(nil, seed: "profile.section.ai") {
                            TabRouteLink(value: ProfileRoute.aiPoints, selectionOutset: -4) {
                                pointsRow
                            }
                            .animation(reduceMotion ? nil : .snappy, value: aiPoints?.balance)
                            // 签到奖励飞行的终点
                            .onGeometryChange(for: CGRect.self) { proxy in
                                proxy.frame(in: .named(Self.contentCoordinateSpace))
                            } action: { frame in
                                pointsRowFrame = frame
                            }
                            .accessibilityIdentifier("profile-ai-points")

                            ProfileSettingsRowDivider()

                            checkInEntry
                        }
                        .id(Self.rewardRowsID)
                        .onScrollVisibilityChange(threshold: 0.9) { visible in
                            areRewardRowsVisible = visible
                        }
                    }

                    ProfileSettingsSection(nil, seed: "profile.section.data") {
                        if isNetworkAllowed {
                            TabRouteLink(value: ProfileRoute.sync, selectionOutset: -4) {
                                ProfileSettingsRow(
                                    titleKey: "sync.title",
                                    symbol: "icloud",
                                    value: text(isSyncOn ? "sync.row.on" : "sync.row.off"),
                                    // 已开启用账本绿表示生效，未开启保持灰色；账本绿已配好浅色与深色两套
                                    valueTint: isSyncOn ? Color(.ledgerGreen) : nil
                                )
                            }
                            .accessibilityIdentifier("profile-sync")

                            ProfileSettingsRowDivider()

                            // 只有已登录、联网，并且 hub 打开了芽豆有物联动时才有入口
                            if isSignedInOnline, dataLinks?.isItemValueLinkAvailable == true {
                                TabRouteLink(value: ProfileRoute.dataLinks, selectionOutset: -4) {
                                    ProfileSettingsRow(
                                        titleKey: "dataLink.title",
                                        symbol: "link",
                                        value: isDataLinkGranted ? text("dataLink.row.linked") : "",
                                        valueTint: isDataLinkGranted ? Color(.ledgerGreen) : nil
                                    )
                                }
                                .accessibilityIdentifier("profile-data-links")

                                ProfileSettingsRowDivider()
                            }
                        }

                        TabRouteLink(value: ProfileRoute.settings, selectionOutset: -4) {
                            ProfileSettingsRow(titleKey: "settings.title", symbol: "gearshape")
                        }
                        .accessibilityIdentifier("profile-settings")
                    }

                    if isNetworkAllowed {
                        ProfileSettingsSection(nil, seed: "profile.section.feedback") {
                            feedbackEntry

                            // 目录里除了本 App 没有别的产品时不显示入口，避免点进去是空页面
                            if seriesCatalog?.products.isEmpty == false {
                                ProfileSettingsRowDivider()

                                TabRouteLink(value: ProfileRoute.moreProducts, selectionOutset: -4) {
                                    ProfileSettingsRow(titleKey: "series.title", symbol: "square.stack.3d.up")
                                }
                                .accessibilityIdentifier("profile-more-products")
                            }
                        }
                    }

                    brandFooter
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
                .coordinateSpace(.named(Self.contentCoordinateSpace))
                .overlay(alignment: .topLeading) {
                    if let rewardFlight {
                        CheckInRewardToken(flight: rewardFlight)
                            .id(rewardFlight.id)
                    }
                }
            }
            // 宽屏单栏时居中排成阅读宽度；内容自己带 20pt 左右留白
            .readableContentWidth()
            // 气泡把点数交出来后，在能拿到滚动代理的这一层接着飞
            .onChange(of: departingReward) { _, points in
                guard let points else { return }
                departingReward = nil
                runRewardSequence(points: points, scrollProxy: scrollProxy)
            }
        }
        .paperPage()
        .navigationTitle(text("profile.title"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingProfile) { profile in
            ProfileEditView(profile: profile)
        }
        .fullScreenCover(item: $openingGift) { gift in
            CheckInGiftOpeningView(
                gift: gift,
                onOpen: { await aiPoints?.openGift($0) ?? .failure(.notSignedIn) },
                onClose: { openingGift = nil }
            )
        }
        .task(id: isCheckInGuideEligible) {
            // 签到状态刚拿到时气泡才淡入，稍等一下再弹引导，免得箭头指向还在动的气泡
            guard isCheckInGuideEligible else { return }
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled, isCheckInGuideEligible else { return }
            // 这里只请求弹出；等引导卡片真正出现时再记成已看过，弹不出来下次还有机会
            isCheckInGuidePresented = true
        }
        // 登录状态或联网许可变化时重新刷新；同意隐私政策后立即触发，请求本身已在 store 层拦住
        .task(id: refreshTrigger) {
            // 进入页面或登录状态变化时拉一次最新资料，其他端改过昵称也能及时同步
            await authStore.refreshProfile()
        }
        .onAppear {
            checkInPlacement = .random()
            isVisible = true
        }
        .onDisappear {
            isVisible = false
            // 签到动画中途离开本页时气泡的流程会被取消、不再交接；把按住的数字放开，免得回来时还停在旧值
            if !isRewardSequenceRunning {
                heldRewardRows = nil
            }
        }
        .task(id: refreshTrigger) {
            // 每次回到“我的”都刷新一次余额，其他芽豆 App 用掉的点数也能及时反映
            await aiPoints?.refresh()
            // 再刷新今天的签到状态；登录成功后也走这里，只刷新状态，不自动签到
            await aiPoints?.refreshCheckInStatus()
        }
        .task(id: refreshTrigger) {
            // 每次回到“我的”都刷新一次反馈未读数；从反馈页返回时已在标记已读后更新过，这里再对一次
            await feedback?.refreshUnread()
            // 数据联动入口以 hub 最近一次的联动列表为准，同样每次回到“我的”都对一次
            await dataLinks?.refreshLinks()
        }
        .task(id: isNetworkAllowed) {
            // 每次回到“我的”都刷新一次产品目录；新产品上架后入口自己出现，不用发版
            await seriesCatalog?.refresh()
        }
    }

    /// 是否允许联网；没注入同意状态时按允许处理。离线模式下页面按未登录显示，并隐藏联网入口。
    private var isNetworkAllowed: Bool {
        privacyAgreement?.allowsNetwork ?? true
    }

    /// 已登录且允许联网；离线模式下已登录用户也按未登录显示，但并没有退出登录。
    private var isSignedInOnline: Bool {
        authStore.isAuthenticated && isNetworkAllowed
    }

    /// 芽豆有物联动是否已授权；决定「数据联动」行的状态值。
    private var isDataLinkGranted: Bool {
        dataLinks?.isItemValueGranted == true
    }

    /// 触发刷新资料、点数和未读数的条件。
    private var refreshTrigger: ProfileRefreshTrigger {
        ProfileRefreshTrigger(isAuthenticated: authStore.isAuthenticated, isNetworkAllowed: isNetworkAllowed)
    }

    /// 每日签到入口：已登录时进入签到页；未登录时先弹窗询问是否去登录，确认后打开登录页。
    @ViewBuilder
    private var checkInEntry: some View {
        if authStore.isAuthenticated {
            TabRouteLink(value: ProfileRoute.checkIn, selectionOutset: -4) {
                checkInRow
            }
            .accessibilityIdentifier("profile-check-in-entry")
        } else {
            Button {
                signInPresentation.requestSignIn(reason: .checkIn)
            } label: {
                checkInRow
            }
            .accessibilityIdentifier("profile-check-in-entry")
        }
    }

    /// 每日签到行：签到期间先停在签到前的样子，奖励飞到后连签天数滚到新值并短暂变绿。
    private var checkInRow: some View {
        let shown = heldRewardRows?.streak ?? liveCheckInRowValue
        return ProfileSettingsRow(
            titleKey: "checkIn.title",
            symbol: "calendar.badge.checkmark",
            value: shown.text,
            valueTint: highlightedRewardRows.contains(.streak) ? Color(.ledgerGreen) : shown.tint,
            valueContentTransition: .numericText()
        )
    }

    /// 每日签到行尾的最新值：有待开的礼包时用礼包主色写礼包数，否则写连签天数，未登录或还没签过时留空。
    private var liveCheckInRowValue: CheckInHeldRows.HeldValue {
        let gifts = authStore.isAuthenticated ? aiPoints?.unopenedGifts ?? [] : []
        let streak = authStore.isAuthenticated ? aiPoints?.checkInStatus?.streak ?? 0 : 0
        if !gifts.isEmpty {
            return .init(
                text: AccountLocalization.formatted(
                    "checkIn.row.gifts",
                    value: gifts.count.formatted(.number.locale(locale)),
                    locale: locale
                ),
                tint: gifts.first?.tier.tint
            )
        }
        if streak > 0 {
            return .init(
                text: AccountLocalization.formatted(
                    "checkIn.row.streak",
                    value: streak.formatted(.number.locale(locale)),
                    locale: locale
                ),
                tint: nil
            )
        }
        return .init(text: "", tint: nil)
    }

    /// AI 点数行：签到期间先停在签到前的余额，奖励飞到后滚到新余额并短暂变绿。
    private var pointsRow: some View {
        let shown = heldRewardRows?.points ?? livePointsRowValue
        return ProfileSettingsRow(
            titleKey: "ai.points.title",
            symbol: "sparkles",
            value: shown.text,
            valueTint: highlightedRewardRows.contains(.points) ? Color(.ledgerGreen) : shown.tint,
            valueContentTransition: .numericText()
        )
    }

    /// AI 点数行尾的最新值：余额不够快捷语音说一句时用账本红提醒，其余保持灰色；与 AI 点数页的余额颜色一致。
    private var livePointsRowValue: CheckInHeldRows.HeldValue {
        .init(
            text: aiPointsValue,
            tint: authStore.isAuthenticated && aiPoints?.isExhausted(for: .quickVoice) == true
                ? Color(.ledgerRed) : nil
        )
    }

    /// 意见反馈入口：已登录时进入对话页；未登录时先弹窗询问是否去登录，确认后打开登录页。
    @ViewBuilder
    private var feedbackEntry: some View {
        if authStore.isAuthenticated {
            TabRouteLink(value: ProfileRoute.feedback, selectionOutset: -4) {
                feedbackRow
            }
            .accessibilityIdentifier("profile-feedback")
        } else {
            Button {
                signInPresentation.requestSignIn(reason: .feedback)
            } label: {
                feedbackRow
            }
            .accessibilityIdentifier("profile-feedback")
        }
    }

    /// 意见反馈行：有未读回复时行尾用账本红显示条数。
    private var feedbackRow: some View {
        let unreadCount = authStore.isAuthenticated ? feedback?.unreadCount ?? 0 : 0
        return ProfileSettingsRow(
            titleKey: "feedback.title",
            symbol: "bubble.left.and.text.bubble.right",
            value: unreadCount > 0
                ? AccountLocalization.formatted(
                    "feedback.row.unread",
                    value: unreadCount.formatted(.number.locale(locale)),
                    locale: locale
                )
                : "",
            valueTint: unreadCount > 0 ? Color(.ledgerRed) : nil
        )
    }

    /// AI 点数行尾的值：未登录时提示登录后可用，已登录时显示余额，还没取到时留空。
    private var aiPointsValue: String {
        guard authStore.isAuthenticated else {
            return text("ai.points.row.signedOut")
        }
        guard let balance = aiPoints?.balance else {
            return ""
        }
        return AccountLocalization.formatted(
            "ai.points.row.balance",
            value: balance.formatted(.number.locale(locale)),
            locale: locale
        )
    }

    /// 当前账号是否已开启云端同步；决定「云端同步」行的状态值和页头副标题。
    private var isSyncOn: Bool {
        guard authStore.isAuthenticated,
              isNetworkAllowed,
              let state = syncLifecycle?.state,
              state.isEnabled,
              let userID = authStore.userID
        else { return false }
        return state.boundUserID == userID
    }

    /// 页头留给用户自己的头像与名称，不放产品品牌；未登录时显示占位名称和登录入口。
    ///
    /// 已登录时头像右下角带铅笔角标，点头像或名称打开修改资料弹层。
    private var profileHeader: some View {
        VStack(spacing: 14) {
            // 未登录时不包成按钮，避免禁用态把头像和名称压暗
            Group {
                if isSignedInOnline {
                    Button {
                        editingProfile = authStore.profile ?? AccountProfile()
                    } label: {
                        profileIdentity
                            .contentShape(Rectangle())
                    }
                    .accessibilityHint(text("profile.edit.title"))
                    .accessibilityIdentifier("profile-edit-entry")
                } else {
                    profileIdentity
                }
            }
            #if DEBUG
            // 开发入口不能放进修改资料按钮里，否则点击会被外层按钮吃掉；这里叠在同一位置，对齐头像右上角
            .overlay(alignment: .top) {
                if DeveloperTools.isEnabled {
                    developerEntry
                        .frame(width: Self.avatarSize, height: Self.avatarSize, alignment: .topTrailing)
                }
            }
            #endif

            // 副标题说明数据存放位置：开启同步后提示已同步到云端，否则提示只在本机
            Text(text(isSyncOn ? "profile.sync_on" : "profile.local_data"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !isNetworkAllowed {
                offlineNotice
            } else if !authStore.isAuthenticated {
                signInButton
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 8)
        .overlay(alignment: .topLeading) { checkInOverlay }
    }

    /// 是否显示签到气泡：未登录时总是显示；已登录时今天还没签才显示，状态还没拿到时不显示（刷新失败沿用上一次的状态）；动画进行中保持显示。
    private var showsCheckInBadge: Bool {
        guard isNetworkAllowed else { return false }
        return !authStore.isAuthenticated || aiPoints?.shouldOfferCheckIn == true || isCheckInBadgeActive
    }

    /// 是否该弹签到引导：本页正显示、已登录、气泡因今天还没签而出现，且这个账号在本机还没看过引导。
    ///
    /// 要求本页可见：在二级页（例如「开发」页重置引导和签到）里条件就已满足时，等回到本页再弹，
    /// 不在看不见的页面上把引导标记成已看过。
    private var isCheckInGuideEligible: Bool {
        isVisible && isSignedInOnline && aiPoints?.shouldOfferCheckIn == true && aiPoints?.shouldShowCheckInGuide == true
    }

    /// 浮在页头头像左侧或右侧空白里的签到气泡；位置只在头像所在的竖向带内取值，不压住头像、角标、名称和登录按钮。
    private var checkInOverlay: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            // 24 是给铅笔角标和开发入口向外凸出的 4+16pt 再留的余量
            let sideGap = (width - Self.avatarSize) / 2 - 24
            if showsCheckInBadge, sideGap >= 72 {
                let centerX = checkInPlacement.isLeading ? sideGap / 2 : width - sideGap / 2
                let centerY = 24 + 36 + checkInPlacement.verticalFraction * max(0, Self.avatarSize - 72)
                ProfileCheckInBadge(
                    placement: checkInPlacement,
                    messageWidth: sideGap,
                    protectionOffer: authStore.isAuthenticated ? aiPoints?.checkInStatus?.protectionOffer : nil,
                    onTap: handleCheckInTap,
                    onFinished: finishCheckIn,
                    onRewardDeparting: { points in
                        departingReward = points
                    }
                )
                .frame(width: 72, height: 72)
                // 签到奖励飞行的起点
                .onGeometryChange(for: CGPoint.self) { proxy in
                    let frame = proxy.frame(in: .named(Self.contentCoordinateSpace))
                    return CGPoint(x: frame.midX, y: frame.midY)
                } action: { center in
                    checkInBubbleCenter = center
                }
                .popover(isPresented: $isCheckInGuidePresented, attachmentAnchor: .rect(.bounds)) {
                    CheckInGuideCard(status: aiPoints?.checkInStatus) {
                        isCheckInGuidePresented = false
                    }
                    .onAppear { aiPoints?.markCheckInGuideShown() }
                    .presentationCompactAdaptation(.popover)
                }
                .position(x: centerX, y: centerY)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showsCheckInBadge)
    }

    /// 点击签到气泡：未登录先弹窗询问是否去登录；已登录发起签到，动画结束前保持气泡显示。
    ///
    /// - Parameter useCard: 用户是否在弹窗里选了用补签卡。
    private func handleCheckInTap(useCard: Bool) async -> CheckInTapOutcome {
        guard authStore.isAuthenticated, let aiPoints else {
            signInPresentation.requestSignIn(reason: .checkIn)
            return .signInRequired
        }
        isCheckInBadgeActive = true
        // 先按住两行签到前的样子：store 一拿到结果就会改余额和连签，等奖励飞到再放开，让数字从旧值滚到新值
        heldRewardRows = CheckInHeldRows(points: livePointsRowValue, streak: liveCheckInRowValue)
        switch await aiPoints.checkIn(useCard: useCard) {
        case let .success(result):
            pendingGift = result.newGifts.first
            // 今天已经签过：没有新点数可飞，直接显示最新值
            if result.isDuplicate {
                heldRewardRows = nil
            }
            return .success(result)
        case let .failure(error):
            isCheckInBadgeActive = false
            heldRewardRows = nil
            return .failure(error)
        }
    }

    /// 签到庆祝结束：收起气泡；点数还在飞时礼包等整段流程结束再弹，否则直接弹。
    private func finishCheckIn() {
        isCheckInBadgeActive = false
        guard !isRewardSequenceRunning else { return }
        // 没有交接点数（例如重复签到）时不会有人放开按住的数字，这里兜底
        heldRewardRows = nil
        openPendingGift()
    }

    /// 这次签到得到了礼包就弹出开礼包的整屏；礼包以 store 里最新的为准，已开完时不再弹。
    private func openPendingGift() {
        guard let pending = pendingGift else { return }
        pendingGift = nil
        if openingGift == nil, let latest = aiPoints?.unopenedGifts.first(where: { $0.id == pending.id }) {
            openingGift = latest
        }
    }

    /// 签到奖励落到两行上：「AI 点数」不在屏幕上时先滚过去，「+N 点」从气泡飞到那一行，
    /// 落下后两行依次放开、数字滚到新值并短暂变绿，最后弹出这次得到的礼包。
    ///
    /// 开启「减弱动态效果」时不滚、不飞、不变色，数字直接换成新值。
    ///
    /// - Parameters:
    ///   - points: 这次签到获得的点数。
    ///   - scrollProxy: 「我的」页滚动视图的代理。
    private func runRewardSequence(points: Int, scrollProxy: ScrollViewProxy) {
        isRewardSequenceRunning = true
        Task {
            if !reduceMotion {
                if !areRewardRowsVisible {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        // 不给锚点：只滚到刚好露出这一组为止
                        scrollProxy.scrollTo(Self.rewardRowsID)
                    }
                    try? await Task.sleep(for: .seconds(0.4))
                }
                if let from = checkInBubbleCenter, let row = pointsRowFrame {
                    // 终点落在行尾数字附近：右边留出箭头和内边距
                    rewardFlight = CheckInRewardFlight(
                        points: points,
                        from: from,
                        to: CGPoint(x: row.maxX - 70, y: row.midY)
                    )
                    try? await Task.sleep(for: .seconds(CheckInRewardToken.duration))
                    rewardFlight = nil
                }
                AppHaptics.play(.tap)
            }
            releaseHeldRewardRow(.points)
            if !reduceMotion {
                try? await Task.sleep(for: .seconds(0.3))
            }
            releaseHeldRewardRow(.streak)
            if !reduceMotion {
                // 绿色留一小会儿让人看清新数字，再退回原色；礼包和退色一起出现，不让人多等
                try? await Task.sleep(for: .seconds(0.9))
                withAnimation(.easeOut(duration: 0.4)) {
                    highlightedRewardRows = []
                }
            }
            heldRewardRows = nil
            isRewardSequenceRunning = false
            // 气泡已经收尾时由这里弹礼包；还没收尾（减弱动态效果下整段很快）时交给 finishCheckIn
            if !isCheckInBadgeActive {
                openPendingGift()
            }
        }
    }

    /// 放开按住的一行：数字从签到前滚到最新值，并用账本绿提示一下。
    ///
    /// - Parameter row: 要放开的行。
    private func releaseHeldRewardRow(_ row: CheckInRewardRow) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.5)) {
            switch row {
            case .points:
                heldRewardRows?.points = nil
            case .streak:
                heldRewardRows?.streak = nil
            }
            if !reduceMotion {
                highlightedRewardRows.insert(row)
            }
        }
    }

    /// 头像与名称；已登录时头像带铅笔角标。
    private var profileIdentity: some View {
        VStack(spacing: 14) {
            // 离线模式下不加载远程头像
            ProfileAvatarView(url: isNetworkAllowed ? authStore.profile?.avatarURL : nil, size: Self.avatarSize)
                .overlay(alignment: .bottomTrailing) {
                    if isSignedInOnline {
                        editBadge
                    }
                }

            Text(headerTitle)
                .font(.system(.title2, design: .serif, weight: .semibold))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("profile-user-name")
        }
    }

    /// 页头头像的边长。
    private static let avatarSize: CGFloat = 96

    #if DEBUG
    /// 头像右上角的「开发」页面入口，是否显示见 `DeveloperTools.isEnabled`。
    private var developerEntry: some View {
        TabRouteLink(value: ProfileRoute.developer, marksSelection: false) {
            Image(systemName: "hammer")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color(uiColor: .secondarySystemBackground)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        }
        .offset(x: 4, y: -4)
        .accessibilityLabel(text("developer.title"))
        .accessibilityIdentifier("profile-developer")
    }
    #endif

    /// 头像右下角的铅笔角标，提示可以修改资料。
    private var editBadge: some View {
        Image(systemName: "pencil")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 32, height: 32)
            .background(Circle().fill(Color(uiColor: .secondarySystemBackground)))
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .offset(x: 4, y: 4)
            .accessibilityHidden(true)
    }

    /// 页头名称：已登录时显示账号名称，取不到名称时显示“已登录”；未登录时显示占位名称。
    private var headerTitle: String {
        guard isSignedInOnline else {
            return text("profile.user.placeholder")
        }
        return authStore.displayName ?? text("auth.user.signed_in")
    }

    /// 离线模式的说明和重新同意入口：点按钮重新弹出隐私政策同意卡，同意后联网功能立即恢复。
    private var offlineNotice: some View {
        VStack(spacing: 10) {
            Text(text("profile.offline.message"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("profile-offline-message")

            Button {
                privacyAgreement?.reviewAgain()
            } label: {
                Text(text("profile.offline.agree"))
                    .font(.body.weight(.medium))
                    .padding(.horizontal, 16)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .accessibilityIdentifier("profile-offline-agree")
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    /// 打开登录 / 注册页的入口；登录方式的选择与进度都在登录页内完成。
    private var signInButton: some View {
        Button {
            signInPresentation.present()
        } label: {
            Text(text("auth.sign_in.action"))
                .font(.body.weight(.medium))
                .padding(.horizontal, 16)
                .onAccentForeground()
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(authStore.isBusy)
        .padding(.top, 6)
        .accessibilityIdentifier("profile-sign-in")
    }

    /// 页面末尾的品牌落款：产品标记、名称与版本号，像账本封底的印记，不与页头的用户信息争位置。
    private var brandFooter: some View {
        VStack(spacing: 6) {
            Image(.brandMark)
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)

            Text(text("app.name"))
                .font(.system(.subheadline, design: .serif, weight: .medium))
                .accessibilityIdentifier("profile-app-name")

            Text(AccountLocalization.formatted("profile.version", value: Self.appVersion, locale: locale))
                .font(.system(.caption, design: .serif))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("profile-version")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    /// 营销版本号与构建号，形如 `1.0 (1)`；缺少构建号时只显示版本号。
    private static var appVersion: String {
        AppVersion.string()
    }

    /// 按应用当前语言解析已有 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 触发「我的」页刷新资料、点数和未读数的条件：登录状态变化，或同意隐私政策后允许联网。
private struct ProfileRefreshTrigger: Hashable {
    /// 本地是否持有有效凭证。
    let isAuthenticated: Bool

    /// 是否允许联网。
    let isNetworkAllowed: Bool
}

#Preview {
    NavigationStack {
        ProfileView()
            .navigationDestination(for: ProfileRoute.self) { $0.destination }
    }
        .environment(AuthStore())
        .environment(SignInPresentation())
        .modelContainer(for: [Account.self, AccountTransaction.self, BookkeepingPreference.self], inMemory: true)
}
