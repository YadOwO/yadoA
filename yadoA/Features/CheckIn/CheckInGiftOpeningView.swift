import SwiftUI

/// 开连续签到礼包的整屏仪式：礼盒在纸面上轻轻起伏，点一下后越晃越厉害，盒盖飞起、光芒转开、彩纸喷出，点数从 0 滚到获得的数值。
///
/// 周、月、年一级比一级重，具体分量见 `CheckInGiftCeremony`：月礼包多了星光、盒缝透光、整屏一闪、冲击波和两波彩纸，
/// 年度礼包再加上礼盒悬起后砸地、画面震动、两侧礼炮、漫天星星和最后的印章。
///
/// 年度礼包可以开两次：第一次开完后按钮变成“再开一次”，盒盖落回，同一个礼盒再开一遍；印章盖过一次就留着。
/// 点了打开就同时发请求，蓄力和请求都结束后才揭晓；请求比蓄力慢时，月礼包和年度礼包原地颤动等着。
/// 失败时摇头并在下方给出原因，网络这类问题可以再点，
/// 礼包已不存在或已在别处开过（服务端 404、409）时不再让重试，按钮换成关闭，回到列表看最新状态。
/// 开启「减弱动态效果」时不起伏、不晃、不转、不闪、不震、不撒彩纸，盒盖淡出、数字直接显示、印章淡入；开启「减弱闪烁光」时不闪屏。
/// 触感受设置里的触感开关控制，同样一级比一级重：蓄力时一串由轻到重的点按，开盖时一下重击（月、年还有余震和噼啪声），
/// 数字停下时一下成功，年度礼包盖章时再一下。
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
    @Environment(\.accessibilityDimFlashingLights) private var dimFlashingLights

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
    /// 开始蓄力的时刻；不在蓄力时为 nil。礼盒的晃动、悬起和透光都按离它过了多久算出来。
    @State private var chargeStart: Date?
    /// 开盖次数：每次开盖加 1，触发盒身下沉回弹。
    @State private var popCount = 0
    /// 开盖爆发次数：触发闪屏、冲击波和画面震动；减弱动态效果时不加。
    @State private var burstCount = 0
    /// 数字停下次数：触发数字放大和光环。
    @State private var landCount = 0
    /// 盖章次数：触发印章落下。
    @State private var sealCount = 0
    /// 年度礼包的印章是否已经盖上；盖过一次，再开一次时留着不再盖。
    @State private var isSealed = false
    @State private var failureShakeCount = 0
    @State private var confettiID: UUID?
    @State private var haptics = CheckInHaptics()
    @State private var flow: Task<Void, Never>?

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

    /// 这档礼包的仪式分量。
    private var ceremony: CheckInGiftCeremony {
        gift.tier.ceremony
    }

    var body: some View {
        ZStack {
            Color(.paperBackground)
                .ignoresSafeArea()

            ambientGlow

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
            .modifier(CheckInScreenShake(trigger: burstCount, amplitude: reduceMotion ? 0 : ceremony.screenShake))

            flash

            // 年度礼包两侧的礼炮和飘落的星星铺满整屏，压在内容上面但不挡点击
            if let confettiID, !reduceMotion, !ceremony.screenConfetti.isEmpty {
                CheckInConfetti(tint: gift.tier.tint, emitters: ceremony.screenConfetti)
                    .ignoresSafeArea()
                    .id(confettiID)
            }
        }
        .onAppear { haptics.start() }
        .onDisappear {
            flow?.cancel()
            haptics.stop()
        }
    }

    // MARK: - 外观

    /// 月礼包、年度礼包背后的一团主色光，开盖后变亮；周礼包没有。
    @ViewBuilder
    private var ambientGlow: some View {
        let base = ceremony.ambientGlow
        let peak = base + ceremony.ambientBoost
        if base > 0 {
            // 渐变颜色本身不做插值，按最亮时画好，再用不透明度过渡，开盖时才能平滑变亮
            RadialGradient(
                colors: [gift.tier.tint.opacity(peak), gift.tier.tint.opacity(0)],
                center: UnitPoint(x: 0.5, y: 0.42),
                startRadius: 0,
                endRadius: 420
            )
            .opacity((base + ceremony.ambientBoost * burstOpacity) / peak)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// 开盖时整屏闪一下主色；周礼包、减弱动态效果和减弱闪烁光时不闪。
    @ViewBuilder
    private var flash: some View {
        let peak = ceremony.flashPeak
        if peak > 0, !reduceMotion, !dimFlashingLights {
            gift.tier.tint
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .keyframeAnimator(initialValue: 0.0, trigger: burstCount) { content, opacity in
                    content.opacity(opacity)
                } keyframes: { _ in
                    KeyframeTrack {
                        LinearKeyframe(peak, duration: 0.06)
                        LinearKeyframe(peak * 0.35, duration: 0.18)
                        LinearKeyframe(0, duration: 0.45)
                    }
                }
        }
    }

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

    /// 中间的舞台：光芒、星光、冲击波、礼盒、彩纸和年度礼包的印章；点礼盒也能打开。
    private var stage: some View {
        let ceremony = self.ceremony
        let tint = gift.tier.tint
        return ZStack {
            sunburst

            if ceremony.sparkleCount > 0 {
                CheckInSparkles(tint: tint, count: ceremony.sparkleCount, isAnimating: !reduceMotion)
                    .frame(width: 340, height: 300)
            }

            ForEach(0..<ceremony.shockwaveCount, id: \.self) { index in
                CheckInRipple(
                    tint: tint.opacity(0.75),
                    trigger: burstCount,
                    delay: Double(index) * 0.16,
                    maxScale: 2.4 + CGFloat(index) * 0.5,
                    lineWidth: 3,
                    seed: UInt64(index) &+ 41
                )
                .frame(width: 150, height: 150)
            }

            box

            if let confettiID, !reduceMotion {
                CheckInConfetti(tint: tint, emitters: ceremony.stageConfetti)
                    .frame(width: 360, height: 420)
                    .id(confettiID)
            }

            if ceremony.hasSeal {
                seal
                    .offset(x: 104, y: -96)
            }
        }
        .frame(height: 300)
    }

    /// 礼盒背后的光芒：开盖后展开并旋转；年度礼包里面再叠一层反向旋转的短光芒。
    private var sunburst: some View {
        let ceremony = self.ceremony
        let tint = gift.tier.tint
        let size = ceremony.sunburstSize
        return TimelineView(.animation(paused: reduceMotion || burstOpacity == 0)) { context in
            let angle = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate * ceremony.raySpeed
            ZStack {
                CheckInSunburst(rayCount: ceremony.rayCount)
                    .fill(
                        RadialGradient(
                            colors: [tint.opacity(0.32), tint.opacity(0)],
                            center: .center,
                            startRadius: 10,
                            endRadius: size / 2
                        )
                    )
                    .rotationEffect(.degrees(angle))

                if ceremony.hasInnerRays {
                    CheckInSunburst(rayCount: ceremony.rayCount / 2)
                        .fill(
                            RadialGradient(
                                colors: [tint.opacity(0.4), tint.opacity(0)],
                                center: .center,
                                startRadius: 6,
                                endRadius: size * 0.32
                            )
                        )
                        .frame(width: size * 0.64, height: size * 0.64)
                        .rotationEffect(.degrees(-angle * 1.6))
                }
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(burstScale)
        .opacity(burstOpacity)
        .accessibilityHidden(true)
    }

    /// 礼盒本身：待开时起伏，蓄力时晃动、透光（年度礼包还会悬起），开盖时下沉回弹，失败时摇头。
    private var box: some View {
        let ceremony = self.ceremony
        let squash = ceremony.popSquash
        let stretch = ceremony.popStretch
        return TimelineView(.animation(paused: !isBoxAnimating)) { context in
            let pose = boxPose(at: context.date)
            CheckInGiftBox(
                tier: gift.tier,
                lidLift: max(lidLift, pose.lidLift),
                glow: pose.glow,
                beamCount: ceremony.beamCount
            )
            .frame(width: ceremony.boxSize, height: ceremony.boxSize)
            .rotationEffect(.degrees(pose.angle), anchor: .bottom)
            .offset(y: pose.offsetY)
        }
        // 开盖时盒身向下一沉再弹起，档位越高沉得越深
        .keyframeAnimator(initialValue: CGFloat(1), trigger: popCount) { content, scale in
            content.scaleEffect(x: 2 - scale, y: scale, anchor: .bottom)
        } keyframes: { _ in
            KeyframeTrack {
                SpringKeyframe(squash, duration: 0.12, spring: .snappy)
                SpringKeyframe(stretch, duration: 0.22, spring: .bouncy)
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
    }

    /// 年度礼包的印章：数字停下后从空中重重落下，压出一圈余波；减弱动态效果时直接淡入。
    private var seal: some View {
        let tint = gift.tier.tint
        let impact = CheckInHaptics.sealImpactDelay
        return ZStack {
            CheckInRipple(tint: tint.opacity(0.6), trigger: sealCount, delay: impact, maxScale: 1.8, lineWidth: 2, seed: 365)
                .frame(width: CheckInSeal.size, height: CheckInSeal.size)

            CheckInSeal(tint: tint, streak: gift.streak)
                .keyframeAnimator(initialValue: SealDrop(), trigger: sealCount) { content, drop in
                    content
                        .scaleEffect(drop.scale)
                        .rotationEffect(.degrees(drop.angle))
                        .opacity(drop.opacity)
                } keyframes: { _ in
                    // 从放大、半透明、更歪的样子加速压下，落到纸面时略微压扁再回弹
                    KeyframeTrack(\.scale) {
                        MoveKeyframe(2.6)
                        LinearKeyframe(0.9, duration: impact, timingCurve: .easeIn)
                        SpringKeyframe(1, duration: 0.35, spring: .bouncy)
                    }
                    KeyframeTrack(\.angle) {
                        MoveKeyframe(-16)
                        LinearKeyframe(0, duration: impact, timingCurve: .easeIn)
                    }
                    KeyframeTrack(\.opacity) {
                        MoveKeyframe(0)
                        LinearKeyframe(1, duration: impact * 0.75)
                    }
                }
        }
        .opacity(isSealed ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 礼盒下方：打开前写“内含多少点”和操作提示，揭晓后是滚动的点数和有效期。
    @ViewBuilder
    private var resultBlock: some View {
        if case let .revealed(result, shown) = phase {
            let ceremony = self.ceremony
            let punch = ceremony.landingPunch
            VStack(spacing: 6) {
                Text(verbatim: "+" + shown.formatted(.number.locale(locale)))
                    .font(.system(size: ceremony.numberFontSize, weight: .semibold, design: .serif))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(shown)))
                    .foregroundStyle(gift.tier.tint)
                    .shadow(color: gift.tier.tint.opacity(ceremony.numberGlow), radius: 12)
                    // 数字停下时放大一下再落回；周礼包不放大
                    .keyframeAnimator(initialValue: CGFloat(1), trigger: landCount) { content, scale in
                        content.scaleEffect(scale)
                    } keyframes: { _ in
                        KeyframeTrack {
                            SpringKeyframe(1 + punch, duration: 0.12, spring: .snappy)
                            SpringKeyframe(1, duration: 0.45, spring: .bouncy)
                        }
                    }
                    .background {
                        if ceremony.hasLandingRipple {
                            CheckInRipple(tint: gift.tier.tint.opacity(0.6), trigger: landCount, maxScale: 1.9, seed: 77)
                                .frame(width: 150, height: 150)
                        }
                    }

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

    /// 礼盒是否需要逐帧刷新：待开时起伏，蓄力时晃动；开启减弱动态效果时都不动。
    private var isBoxAnimating: Bool {
        !reduceMotion && (phase == .ready || chargeStart != nil)
    }

    /// 礼盒此刻的姿态：待开时起伏轻晃，蓄力时按离点开过了多久算，揭晓后静止。
    ///
    /// - Parameter date: 当前帧的时刻。
    private func boxPose(at date: Date) -> CheckInGiftCeremony.BoxPose {
        guard !reduceMotion else { return .rest }
        switch phase {
        case .ready:
            return ceremony.idlePose(time: date.timeIntervalSinceReferenceDate)
        case .opening:
            guard let chargeStart else { return .rest }
            return ceremony.chargePose(elapsed: date.timeIntervalSince(chargeStart))
        case .revealed:
            return .rest
        }
    }

    // MARK: - 交互

    /// 打开：同时开始晃动和请求，两者都结束后揭晓；失败时回到待开并显示原因。
    private func open() {
        guard phase == .ready, !isStale, !gift.isFinished else { return }
        errorKey = nil
        phase = .opening
        let target = gift
        let ceremony = self.ceremony
        flow = Task {
            let request = Task { await onOpen(target) }
            if !reduceMotion {
                chargeStart = .now
                haptics.playCharge(ceremony.level, duration: ceremony.chargeDuration)
                try? await Task.sleep(for: .seconds(ceremony.chargeDuration))
            }
            // 请求比蓄力慢时礼盒按 holdPose 原地颤动，直到结果回来
            let outcome = await request.value
            guard !Task.isCancelled else { return }
            chargeStart = nil
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

    /// 揭晓：盒盖飞起、光芒展开、彩纸喷出（月、年还有闪屏、冲击波和画面震动），点数从 0 滚到获得的数值；
    /// 年度礼包数字停下后再盖一枚印章。
    private func reveal(_ result: AICheckInGiftOpenResult) async {
        gift = result.gift
        let ceremony = self.ceremony
        haptics.playBurst(ceremony.level)
        if reduceMotion {
            phase = .revealed(result, shown: result.points)
            withAnimation(.easeOut(duration: 0.3)) {
                lidLift = 1
                burstOpacity = 1
                burstScale = 1
            }
            announce(result)
            if ceremony.hasSeal, !isSealed {
                try? await Task.sleep(for: .seconds(ceremony.sealDelay))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.3)) { isSealed = true }
                haptics.playSeal()
            }
            return
        }

        phase = .revealed(result, shown: 0)
        popCount += 1
        burstCount += 1
        confettiID = UUID()
        withAnimation(.spring(duration: 0.6, bounce: ceremony.lidBounce)) { lidLift = 1 }
        withAnimation(.easeOut(duration: 0.7)) {
            burstOpacity = 1
            burstScale = ceremony.burstScale
        }

        try? await Task.sleep(for: .seconds(ceremony.rollDelay))
        guard !Task.isCancelled else { return }
        // 每跳加的点数相同；月礼包、年度礼包后面几跳越来越慢，触感跟着放慢
        let steps = max(1, min(result.points, ceremony.maxRollSteps))
        let times = ceremony.rollTimes(steps: steps)
        haptics.playRoll(times: times)
        var elapsed = 0.0
        for (index, time) in times.enumerated() {
            try? await Task.sleep(for: .seconds(max(0, time - elapsed)))
            elapsed = time
            guard !Task.isCancelled else { return }
            let value = CheckInGiftCeremony.rolledValue(points: result.points, step: index + 1, of: steps)
            withAnimation(.snappy(duration: 0.12)) {
                phase = .revealed(result, shown: value)
            }
        }
        landCount += 1
        AppHaptics.play(.success)
        if ceremony.level > .light {
            haptics.playLanding(isBonus: ceremony.level == .epic)
        }
        announce(result)

        guard ceremony.hasSeal, !isSealed else { return }
        try? await Task.sleep(for: .seconds(ceremony.sealDelay))
        guard !Task.isCancelled else { return }
        isSealed = true
        sealCount += 1
        haptics.playSeal()
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

/// 印章落下过程中某一刻的样子；初始值就是盖好后的样子，播完回到初始值也不会跳。
private nonisolated struct SealDrop {
    var scale: CGFloat = 1
    var angle: Double = 0
    var opacity: Double = 1
}

/// 开盖时整块内容震一下：先猛后弱地左右上下抖几下，回到原位；幅度为 0 时不动。
private struct CheckInScreenShake: ViewModifier {
    /// 每次变化震一次。
    let trigger: Int

    /// 最大位移，单位为点。
    let amplitude: CGFloat

    /// 震动某一刻的位移；初始和结束都是 0。
    private nonisolated struct Jolt {
        var x: CGFloat = 0
        var y: CGFloat = 0
    }

    func body(content: Content) -> some View {
        let amplitude = self.amplitude
        content
            .keyframeAnimator(initialValue: Jolt(), trigger: trigger) { content, jolt in
                content.offset(x: jolt.x, y: jolt.y)
            } keyframes: { _ in
                KeyframeTrack(\.x) {
                    LinearKeyframe(amplitude, duration: 0.04)
                    LinearKeyframe(-amplitude * 0.8, duration: 0.06)
                    LinearKeyframe(amplitude * 0.55, duration: 0.06)
                    LinearKeyframe(-amplitude * 0.3, duration: 0.06)
                    LinearKeyframe(amplitude * 0.12, duration: 0.06)
                    LinearKeyframe(0, duration: 0.06)
                }
                KeyframeTrack(\.y) {
                    LinearKeyframe(-amplitude * 0.5, duration: 0.05)
                    LinearKeyframe(amplitude * 0.6, duration: 0.06)
                    LinearKeyframe(-amplitude * 0.3, duration: 0.06)
                    LinearKeyframe(amplitude * 0.15, duration: 0.06)
                    LinearKeyframe(0, duration: 0.07)
                }
            }
    }
}

/// 预览用的开礼包整屏：0.5 秒后“打开成功”，点数取这一次的上限。
///
/// - Parameters:
///   - tier: 礼包档位。
///   - streak: 连签天数。
///   - openings: 依次打开的点数范围。
private func previewOpening(
    tier: AICheckInGiftTier,
    streak: Int,
    openings: [AICheckInGiftOpening]
) -> some View {
    CheckInGiftOpeningView(
        gift: AICheckInGift(
            id: "preview", tier: tier, streak: streak, checkInDate: "2026-11-18",
            totalOpens: openings.count, openedCount: 0, createdAt: .now
        ),
        rule: AICheckInGiftRule(tier: tier, everyDays: streak, openings: openings, validDays: 30),
        onOpen: { gift in
            try? await Task.sleep(for: .seconds(0.5))
            let opened = AICheckInGift(
                id: gift.id, tier: gift.tier, streak: gift.streak, checkInDate: gift.checkInDate,
                totalOpens: gift.totalOpens, openedCount: gift.nextSeq, createdAt: gift.createdAt
            )
            let opening = openings[min(opened.openedCount, openings.count) - 1]
            return .success(AICheckInGiftOpenResult(
                gift: opened, seq: opened.openedCount, points: opening.maxPoints,
                isDuplicate: false, balance: 600, createdAt: .now, expiresAt: .now.addingTimeInterval(30 * 86_400)
            ))
        },
        onClose: {}
    )
}

#Preview("周礼包") {
    previewOpening(tier: .weekly, streak: 7, openings: [.init(minPoints: 5, maxPoints: 20)])
}

#Preview("月礼包") {
    previewOpening(tier: .monthly, streak: 30, openings: [.init(minPoints: 21, maxPoints: 50)])
}

#Preview("年度礼包") {
    previewOpening(
        tier: .yearly,
        streak: 365,
        openings: [.init(minPoints: 365, maxPoints: 365), .init(minPoints: 100, maxPoints: 365)]
    )
}
