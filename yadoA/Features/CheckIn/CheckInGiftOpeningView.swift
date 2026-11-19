import SwiftUI

/// 开连续签到礼包的整屏仪式：礼盒在纸面上轻轻起伏，点一下后越晃越厉害，盒盖飞起、光芒转开、彩纸喷出，点数从 0 滚到获得的数值。
///
/// 年度礼包可以开两次：第一次开完后按钮变成“再开一次”，盒盖落回，同一个礼盒再开一遍。
/// 点了打开就同时发请求，晃动和请求都结束后才揭晓；失败时摇头并在下方给出原因，网络这类问题可以再点，
/// 礼包已不存在或已在别处开过（服务端 404、409）时不再让重试，按钮换成关闭，回到列表看最新状态。
/// 开启「减弱动态效果」时不起伏、不晃、不转、不撒彩纸，盒盖淡出、数字直接显示。
/// 触感受设置里的触感开关控制：晃动时一串由轻到重的点按，开盖时一下落定，数字停下时一下成功。
struct CheckInGiftOpeningView: View {
    /// 仪式所处的阶段。
    private enum Phase: Equatable {
        /// 等用户点开。
        case ready
        /// 晃动并等服务端结果。
        case opening
        /// 已揭晓：`shown` 是当前显示的滚动数字。
        case revealed(AICheckInGiftOpenResult, shown: Int)
    }

    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 这档礼包的规则，用来在打开前显示“内含多少点”；服务端没有返回时为 nil，不显示。
    let rule: AICheckInGiftRule?

    /// 打开一次，由页面交给 `AIPointsStore.openGift(_:)`。
    let onOpen: (AICheckInGift) async -> Result<AICheckInGiftOpenResult, AIBillingAPIError>

    /// 关闭整屏。
    let onClose: () -> Void

    /// 正在开的礼包；每开一次换成服务端返回的最新状态。
    @State private var gift: AICheckInGift
    @State private var phase: Phase = .ready
    @State private var errorKey: String?
    /// 礼包已不存在或已在别处开过：手里这份礼包过时了，只能关闭。
    @State private var isStale = false
    @State private var lidLift: CGFloat = 0
    @State private var burstOpacity: Double = 0
    @State private var burstScale: CGFloat = 0.6
    @State private var shakeCount = 0
    @State private var popCount = 0
    @State private var failureShakeCount = 0
    @State private var confettiID: UUID?
    @State private var haptics = CheckInHaptics()
    @State private var flow: Task<Void, Never>?

    /// 点开后礼盒晃动的时长；请求更快回来也等晃完再揭晓。
    private static let shakeDuration = 1.1

    /// 数字滚动的时长。
    private static let rollDuration = 0.9

    /// 礼盒边长。
    private static let boxSize: CGFloat = 188

    /// 创建开礼包的整屏。
    ///
    /// - Parameters:
    ///   - gift: 要开的礼包。
    ///   - rule: 这档礼包的规则。
    ///   - onOpen: 打开一次的动作。
    ///   - onClose: 关闭整屏的动作。
    init(
        gift: AICheckInGift,
        rule: AICheckInGiftRule?,
        onOpen: @escaping (AICheckInGift) async -> Result<AICheckInGiftOpenResult, AIBillingAPIError>,
        onClose: @escaping () -> Void
    ) {
        _gift = State(initialValue: gift)
        self.rule = rule
        self.onOpen = onOpen
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            Color(.paperBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    closeButton
                }

                Spacer(minLength: 12)

                titleBlock

                stage
                    .padding(.vertical, 20)

                resultBlock
                    .frame(minHeight: 120, alignment: .top)

                Spacer(minLength: 12)

                actionArea
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: 520)
        }
        .onAppear { haptics.start() }
        .onDisappear {
            flow?.cancel()
            haptics.stop()
        }
    }

    // MARK: - 外观

    /// 右上角的关闭按钮；晃动等结果时隐藏，免得开到一半关掉。
    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color(uiColor: .secondarySystemBackground)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .opacity(phase == .opening ? 0 : 1)
        .disabled(phase == .opening)
        .accessibilityLabel(text("checkIn.opening.close"))
        .accessibilityIdentifier("check-in-gift-close")
    }

    /// 礼包名称和来历，例如“周礼包 · 连签 7 天获得”；能开几次的礼包再写上第几次。
    private var titleBlock: some View {
        VStack(spacing: 6) {
            Text(text(gift.tier.titleKey))
                .font(.system(.largeTitle, design: .serif, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
    }

    /// 标题下的一行：连签几天获得；能开几次的礼包加上“第几次，共几次”。
    private var subtitle: String {
        let earned = AccountLocalization.formatted(
            "checkIn.gift.earned",
            value: gift.streak.formatted(.number.locale(locale)),
            locale: locale
        )
        guard gift.totalOpens > 1 else { return earned }
        let round = String(
            format: text("checkIn.opening.round"),
            locale: locale,
            displayedSeq.formatted(.number.locale(locale)),
            gift.totalOpens.formatted(.number.locale(locale))
        )
        return "\(earned) · \(round)"
    }

    /// 标题里显示的“第几次”：揭晓后是刚开的那次，其余是下一次。
    private var displayedSeq: Int {
        if case let .revealed(result, _) = phase { return result.seq }
        return min(gift.nextSeq, gift.totalOpens)
    }

    /// 中间的舞台：光芒、礼盒和彩纸；点礼盒也能打开。
    private var stage: some View {
        ZStack {
            TimelineView(.animation(paused: reduceMotion || burstOpacity == 0)) { context in
                CheckInSunburst()
                    .fill(
                        RadialGradient(
                            colors: [gift.tier.tint.opacity(0.32), gift.tier.tint.opacity(0)],
                            center: .center,
                            startRadius: 10,
                            endRadius: 150
                        )
                    )
                    .rotationEffect(.degrees(reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate * 12))
            }
            .frame(width: 300, height: 300)
            .scaleEffect(burstScale)
            .opacity(burstOpacity)
            .accessibilityHidden(true)

            TimelineView(.animation(paused: !isFloating)) { context in
                CheckInGiftBox(tier: gift.tier, lidLift: lidLift)
                    .frame(width: Self.boxSize, height: Self.boxSize)
                    .offset(y: floatOffset(at: context.date))
                    .rotationEffect(.degrees(idleTilt(at: context.date)), anchor: .bottom)
            }
            // 点开后的晃动：由轻到重，最后几下最猛，像里面的东西要蹦出来
            .keyframeAnimator(initialValue: 0.0, trigger: shakeCount) { content, angle in
                content.rotationEffect(.degrees(angle), anchor: .bottom)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(2.0, duration: 0.11)
                    LinearKeyframe(-3.0, duration: 0.11)
                    LinearKeyframe(4.0, duration: 0.11)
                    LinearKeyframe(-5.0, duration: 0.11)
                    LinearKeyframe(6.0, duration: 0.1)
                    LinearKeyframe(-7.0, duration: 0.09)
                    LinearKeyframe(8.0, duration: 0.08)
                    LinearKeyframe(-9.0, duration: 0.08)
                    LinearKeyframe(10.0, duration: 0.07)
                    LinearKeyframe(-11.0, duration: 0.07)
                    LinearKeyframe(12.0, duration: 0.07)
                    LinearKeyframe(0.0, duration: 0.1)
                }
            }
            // 开盖时盒身向下一沉再弹起
            .keyframeAnimator(initialValue: CGFloat(1), trigger: popCount) { content, scale in
                content.scaleEffect(x: 2 - scale, y: scale, anchor: .bottom)
            } keyframes: { _ in
                KeyframeTrack {
                    SpringKeyframe(0.86, duration: 0.12, spring: .snappy)
                    SpringKeyframe(1.08, duration: 0.22, spring: .bouncy)
                    SpringKeyframe(1, duration: 0.3, spring: .smooth)
                }
            }
            // 失败时摇头
            .keyframeAnimator(initialValue: CGFloat(0), trigger: failureShakeCount) { content, x in
                content.offset(x: x)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(-8, duration: 0.06)
                    LinearKeyframe(8, duration: 0.1)
                    LinearKeyframe(-6, duration: 0.1)
                    LinearKeyframe(6, duration: 0.1)
                    LinearKeyframe(0, duration: 0.06)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .accessibilityElement()
            .accessibilityLabel(text(gift.tier.titleKey))
            .accessibilityHint(phase == .ready && !isStale ? text("checkIn.opening.tapToOpen") : "")
            .accessibilityAddTraits(phase == .ready && !isStale ? .isButton : [])
            .accessibilityAction { open() }

            if let confettiID, !reduceMotion {
                CheckInConfetti(tint: gift.tier.tint, origin: UnitPoint(x: 0.5, y: 0.45))
                    .frame(width: 360, height: 420)
                    .id(confettiID)
            }
        }
        .frame(height: 300)
    }

    /// 礼盒下方：打开前写“内含多少点”和操作提示，揭晓后是滚动的点数和有效期。
    @ViewBuilder
    private var resultBlock: some View {
        if case let .revealed(result, shown) = phase {
            VStack(spacing: 6) {
                Text(verbatim: "+" + shown.formatted(.number.locale(locale)))
                    .font(.system(size: 60, weight: .semibold, design: .serif))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(shown)))
                    .foregroundStyle(gift.tier.tint)

                Text(text("checkIn.opening.pointsUnit"))
                    .font(.headline)

                Text(validUntilText(result))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if gift.remainingOpens > 0 {
                    Text(text("checkIn.opening.secondChance"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(gift.tier.tint)
                        .padding(.top, 4)
                }
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("check-in-gift-result")
        } else {
            VStack(spacing: 6) {
                if let range = nextOpeningRange {
                    Text(AccountLocalization.formatted("checkIn.opening.range", value: range, locale: locale))
                        .font(.headline)
                }
                Text(text("checkIn.opening.tapToOpen"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .opacity(phase == .ready && !isStale ? 1 : 0)
            }
            .multilineTextAlignment(.center)
        }
    }

    /// 下一次打开的点数范围，例如“21–50”；不知道规则时为 nil。
    private var nextOpeningRange: String? {
        guard let rule, !rule.openings.isEmpty else { return nil }
        let index = min(gift.openedCount, rule.openings.count - 1)
        return rule.openings[index].rangeText(locale: locale)
    }

    /// 底部的按钮和失败原因。
    private var actionArea: some View {
        VStack(spacing: 10) {
            actionButton

            Text(errorKey.map(text) ?? " ")
                .font(.footnote)
                .foregroundStyle(Color(.ledgerRed))
                .multilineTextAlignment(.center)
                .opacity(errorKey == nil ? 0 : 1)
                .accessibilityHidden(errorKey == nil)
                .accessibilityIdentifier("check-in-gift-error")
        }
    }

    /// 主按钮：打开前“打开礼包”，揭晓后还能开就“再开一次”，开完了“收下”。
    @ViewBuilder
    private var actionButton: some View {
        switch phase {
        case .ready where isStale:
            LedgerSubmitButton(title: text("checkIn.opening.close"), isSaving: false, action: onClose)
                .accessibilityIdentifier("check-in-gift-stale-close")
        case .ready, .opening:
            LedgerSubmitButton(title: text("checkIn.opening.open"), isSaving: phase == .opening, action: open)
                .disabled(phase == .opening)
                .accessibilityIdentifier("check-in-gift-open")
        case .revealed:
            if gift.remainingOpens > 0 {
                LedgerSubmitButton(title: text("checkIn.opening.openAgain"), isSaving: false, action: prepareNextOpen)
                    .accessibilityIdentifier("check-in-gift-open-again")
            } else {
                LedgerSubmitButton(title: text("checkIn.opening.collect"), isSaving: false, action: onClose)
                    .accessibilityIdentifier("check-in-gift-collect")
            }
        }
    }

    // MARK: - 动态

    /// 等待打开时是否起伏：只在待开阶段，并且没开启减弱动态效果。
    private var isFloating: Bool {
        !reduceMotion && phase == .ready
    }

    /// 待开时 ±5pt、约 2.4 秒一个周期的上下起伏。
    private func floatOffset(at date: Date) -> CGFloat {
        guard isFloating else { return 0 }
        return CGFloat(5 * sin(date.timeIntervalSinceReferenceDate / 2.4 * 2 * .pi))
    }

    /// 待开时每 3 秒一次的轻晃，像里面有东西在动。
    private func idleTilt(at date: Date) -> Double {
        guard isFloating else { return 0 }
        let local = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3)
        let wobble = 0.6
        guard local < wobble else { return 0 }
        let progress = local / wobble
        return 5 * sin(progress * 2 * .pi * 2) * (1 - progress)
    }

    // MARK: - 交互

    /// 打开：同时开始晃动和请求，两者都结束后揭晓；失败时回到待开并显示原因。
    private func open() {
        guard phase == .ready, !isStale, !gift.isFinished else { return }
        errorKey = nil
        phase = .opening
        let target = gift
        flow = Task {
            let request = Task { await onOpen(target) }
            if !reduceMotion {
                shakeCount += 1
                haptics.playRoll(steps: 12, duration: Self.shakeDuration)
                try? await Task.sleep(for: .seconds(Self.shakeDuration))
            }
            let outcome = await request.value
            guard !Task.isCancelled else { return }
            switch outcome {
            case let .success(result):
                await reveal(result)
            case let .failure(error):
                AppHaptics.play(.error)
                if !reduceMotion { failureShakeCount += 1 }
                phase = .ready
                // invalidContract 来自 404、409：礼包已不存在或已在别处开过，同一个 seq 再点也不会成功
                isStale = error == .invalidContract
                withAnimation(.easeOut(duration: 0.2)) {
                    errorKey = isStale ? "checkIn.opening.failure.stale" : ProfileCheckInBadge.failureKey(for: error)
                }
            }
        }
    }

    /// 揭晓：盒盖飞起、光芒展开、彩纸喷出，点数从 0 滚到获得的数值。
    private func reveal(_ result: AICheckInGiftOpenResult) async {
        gift = result.gift
        haptics.playLanding(isBonus: true)
        if reduceMotion {
            phase = .revealed(result, shown: result.points)
            withAnimation(.easeOut(duration: 0.3)) {
                lidLift = 1
                burstOpacity = 1
                burstScale = 1
            }
            announce(result)
            return
        }

        phase = .revealed(result, shown: 0)
        popCount += 1
        confettiID = UUID()
        withAnimation(.spring(duration: 0.6, bounce: 0.35)) { lidLift = 1 }
        withAnimation(.easeOut(duration: 0.7)) {
            burstOpacity = 1
            burstScale = 1.1
        }

        try? await Task.sleep(for: .seconds(0.25))
        guard !Task.isCancelled else { return }
        let steps = max(1, min(result.points, 24))
        haptics.playRoll(steps: steps, duration: Self.rollDuration)
        for step in 1...steps {
            try? await Task.sleep(for: .seconds(Self.rollDuration / Double(steps)))
            guard !Task.isCancelled else { return }
            let value = step == steps ? result.points : Int((Double(result.points) * Double(step) / Double(steps)).rounded())
            withAnimation(.snappy(duration: 0.12)) {
                phase = .revealed(result, shown: value)
            }
        }
        AppHaptics.play(.success)
        announce(result)
    }

    /// 年度礼包开完第一次后：盒盖落回、光芒收起，回到待开，等用户再开一次。
    private func prepareNextOpen() {
        confettiID = nil
        errorKey = nil
        withAnimation(reduceMotion ? .easeOut(duration: 0.25) : .spring(duration: 0.5, bounce: 0.3)) {
            lidLift = 0
            burstOpacity = 0
            burstScale = 0.6
            phase = .ready
        }
        AppHaptics.play(.tap)
    }

    /// 有效期一行，例如“有效期至 2026年11月25日 14:20”。
    private func validUntilText(_ result: AICheckInGiftOpenResult) -> String {
        AccountLocalization.formatted(
            "checkIn.opening.validUntil",
            value: result.expiresAt.formatted(.dateTime.year().month().day().hour().minute().locale(locale)),
            locale: locale
        )
    }

    /// VoiceOver 播报“获得 N 点，有效期至…”。
    private func announce(_ result: AICheckInGiftOpenResult) {
        AccessibilityNotification.Announcement(
            String(
                format: text("checkIn.opening.announcement"),
                locale: locale,
                result.points.formatted(.number.locale(locale)),
                result.expiresAt.formatted(.dateTime.year().month().day().locale(locale))
            )
        ).post()
    }

    /// 按应用当前语言解析文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

#Preview {
    CheckInGiftOpeningView(
        gift: AICheckInGift(
            id: "1", tier: .yearly, streak: 365, checkInDate: "2026-11-18",
            totalOpens: 2, openedCount: 0, createdAt: .now
        ),
        rule: AICheckInGiftRule(
            tier: .yearly,
            everyDays: 365,
            openings: [.init(minPoints: 365, maxPoints: 365), .init(minPoints: 100, maxPoints: 365)],
            validDays: 365
        ),
        onOpen: { gift in
            try? await Task.sleep(for: .seconds(0.5))
            let opened = AICheckInGift(
                id: gift.id, tier: gift.tier, streak: gift.streak, checkInDate: gift.checkInDate,
                totalOpens: gift.totalOpens, openedCount: gift.nextSeq, createdAt: gift.createdAt
            )
            return .success(AICheckInGiftOpenResult(
                gift: opened, seq: opened.openedCount, points: opened.openedCount == 1 ? 365 : 233,
                isDuplicate: false, balance: 600, createdAt: .now, expiresAt: .now.addingTimeInterval(365 * 86_400)
            ))
        },
        onClose: {}
    )
}
