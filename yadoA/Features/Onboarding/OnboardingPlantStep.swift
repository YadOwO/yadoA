import SwiftUI

/// 小结与种下：前面的回答重新写成一份清单；下方一块地上躺着那颗豆子，按住它种下去。
///
/// 按下时豆子压进土里，先往下扎根，再破土长出茎，把豆子一路顶上去，两片叶子依次展开，长满时豆子停在芽尖上。
/// 手指一直按在豆子上，芽就在指尖上方长出来，进度就是芽本身，不另画进度条。
/// 长满的那一刻一次写入所有草稿；失败时芽缩回、在下方提示，可以再按一次。
/// 叶子开始展开后松手也会自己长完；更早松手芽缩回土里，什么都不写。
/// 开启“减弱动态效果”或使用 VoiceOver 时改为点按。
struct OnboardingPlantStep: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled
    @Environment(AuthStore.self) private var authStore

    /// 引导状态。
    let store: OnboardingStore

    /// 触感。
    let haptics: OnboardingHaptics

    /// 一次写入所有草稿；成功返回 true。
    let onPlant: () -> Bool

    /// 豆子在芽尖上落定。
    let onBeanLanded: () -> Void

    /// 种下之后进入下一行。
    let onContinue: () -> Void

    /// 点清单里的一行，回到那一行改。
    let onRevise: (OnboardingStep) -> Void

    /// 从按下到长满所需的时长。
    static let holdDuration: Double = 1.6

    /// 松手后缩回比长出快的倍数。
    private static let retractSpeed: Double = 2.6

    /// 过了不回头的进度后松手，自己长完比按着长快的倍数。
    private static let finishSpeed: Double = 2

    /// 种植区的边长。
    private static let bedSize: CGFloat = 180

    /// 标题写完后依次写出清单。
    @State private var isDetailVisible = false

    /// 已经写出的清单行数。
    @State private var inkedCount = 0

    /// 按住进度随时间的变化；界面每一帧按它推算芽长到了哪里。
    @State private var clock = GrowthClock()

    /// 手指是否按着。
    @State private var isPressing = false

    /// 松手时已经过了不回头的进度，正在自己长完。
    @State private var isFinishing = false

    /// 是否已经种下。
    @State private var isPlanted = false

    /// 闪光短线的书写进度。
    @State private var sparkleProgress: CGFloat = 0

    /// 没按够就松了手，提示再按久一点。
    @State private var isHoldTooShort = false

    /// 写入失败。
    @State private var hasFailed = false

    /// 长满后种下、缩回后归零的计时。
    @State private var growthTask: Task<Void, Never>?

    var body: some View {
        OnboardingPage {
            OnboardingInkText(
                text: text(isPlanted ? "onboarding.plant.done.title" : "onboarding.plant.title"),
                haptics: haptics,
                onWritten: { isDetailVisible = true }
            )
            .accessibilityAddTraits(.isHeader)

            summary
                .padding(.top, 20)
        } actions: {
            plantingBed
        }
        .onChange(of: isDetailVisible) { _, isVisible in
            guard isVisible else { return }
            Task { await inkSummary() }
        }
        .onDisappear {
            growthTask?.cancel()
            haptics.endHold()
        }
    }

    /// 减弱动态效果或 VoiceOver 下改为点按种下。
    private var isTapMode: Bool {
        reduceMotion || isVoiceOverEnabled
    }

    // MARK: - 清单

    /// 前面每一行的回答，墨色重写一遍，每行前面一个小对勾；种下前可以点回去改。
    private var summary: some View {
        let items = OnboardingSummary.items(draft: store.draft, displayName: authStore.displayName, locale: locale)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button {
                    onRevise(item.step)
                } label: {
                    HStack(spacing: 10) {
                        HandDrawnTick(progress: index < inkedCount ? 1 : 0)
                            .frame(width: 18)
                            .animation(.easeInOut(duration: 0.3), value: inkedCount)
                        Text(item.text)
                            .font(.subheadline)
                            .foregroundStyle(Color.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if !isPlanted {
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(minHeight: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isPlanted || isPressing || isFinishing)
                .opacity(index < inkedCount ? 1 : 0)
                .offset(x: index < inkedCount || reduceMotion ? 0 : -6)
                .animation(.easeOut(duration: 0.3), value: inkedCount)
                .accessibilityHint(Text(text("onboarding.plant.revise.hint")))
            }
            Text(text("onboarding.plant.note"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
                .opacity(inkedCount >= items.count ? 1 : 0)
                .animation(.easeOut(duration: 0.3), value: inkedCount)
        }
    }

    /// 一行一行写出清单，每写一行一下。
    private func inkSummary() async {
        let count = OnboardingSummary.items(draft: store.draft, displayName: authStore.displayName, locale: locale).count
        guard inkedCount == 0 else { return }
        if reduceMotion {
            inkedCount = count
            return
        }
        for index in 0..<count {
            inkedCount = index + 1
            haptics.tick()
            try? await Task.sleep(for: .milliseconds(180))
        }
    }

    // MARK: - 种植区

    /// 一块地和地上的豆子，按住这块地就是按住豆子；下方一行提示，点按模式下是种下按钮。
    private var plantingBed: some View {
        VStack(spacing: 4) {
            TimelineView(.animation(paused: isPlanted || isTapMode)) { context in
                sprout(progress: clock.value(at: context.date), date: context.date)
            }
            .frame(width: Self.bedSize, height: Self.bedSize)
            .contentShape(Rectangle())
            .gesture(holdGesture)
            .accessibilityElement()
            .accessibilityLabel(text("onboarding.plant.tap"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { plantAtOnce() }
            .accessibilityHidden(isTapMode)
            .accessibilityIdentifier("onboarding-plant-bed")

            footer
                .onboardingReveal(isDetailVisible, delay: 0.4)
        }
        .frame(maxWidth: .infinity)
    }

    /// 某一进度下的芽：地面一直在；根、茎、两片叶子按各自的区间长出；豆子的停放处跟着芽尖走。
    ///
    /// - Parameters:
    ///   - progress: 按住进度，0...1。
    ///   - date: 当前帧的时刻，用来画等待按下时的波纹。
    private func sprout(progress: Double, date: Date) -> some View {
        let size = Self.bedSize
        let scale = size / SproutGeometry.canvas
        let line = StrokeStyle(lineWidth: 4.8 * scale, lineCap: .round, lineJoin: .round)
        let beanDiameter = SproutGeometry.beanRadius * 2 * scale
        let bean = OnboardingSproutGrowth.beanCenter(at: progress)
        let isStill = reduceMotion
        return ZStack(alignment: .topLeading) {
            OnboardingSproutStroke(stroke: SproutLinePart.groundPath, progress: 1)
                .stroke(Color.primary, style: line)

            // 根在土里，墨色淡一些
            OnboardingSproutStroke(stroke: SproutLinePart.rootsPath, progress: OnboardingSproutGrowth.roots(at: progress))
                .stroke(Color.primary.opacity(0.45), style: line)

            OnboardingSproutStroke(stroke: SproutLinePart.stemPath, progress: OnboardingSproutGrowth.stem(at: progress))
                .stroke(Color.primary, style: line)

            soilFlecks(progress: progress, scale: scale)

            ForEach([SproutLinePart.leftLeaf, .rightLeaf], id: \.self) { part in
                let unfold = OnboardingSproutGrowth.leaf(part, at: progress)
                OnboardingSproutStroke(stroke: part.path, progress: unfold)
                    .stroke(Color.primary, style: line)
                    // 叶子贴着茎合拢着长出来，边长边展开
                    .rotationEffect(.degrees(part.liftDirection * 30 * Double(1 - unfold)), anchor: part.anchor)
                    // 种下的那一刻两片叶子一起上甩，再回弹落定
                    .keyframeAnimator(initialValue: 0.0, trigger: isPlanted) { content, wobble in
                        content.rotationEffect(.degrees(isStill ? 0 : wobble * part.liftDirection), anchor: part.anchor)
                    } keyframes: { _ in
                        SpringKeyframe(8, duration: 0.12)
                        SpringKeyframe(-3, duration: 0.18)
                        SpringKeyframe(0, duration: 0.5, spring: .bouncy)
                    }
            }

            SproutSparkleShape()
                .trim(from: 0, to: sparkleProgress)
                .stroke(Color.primary.opacity(0.5), style: StrokeStyle(lineWidth: 2.8 * scale, lineCap: .round))

            if showsRipple(progress: progress) {
                ripple(date: date, diameter: beanDiameter)
                    .position(x: bean.x * scale, y: bean.y * scale)
            }

            Color.clear
                .frame(width: beanDiameter, height: beanDiameter)
                .onboardingBeanSlot(isTracking: !isPlanted && (isPressing || progress > 0))
                .position(x: bean.x * scale, y: bean.y * scale)
        }
        .frame(width: size, height: size)
    }

    /// 破土的一瞬，茎两侧各溅起一小粒土，往外飞一点就消失。
    private func soilFlecks(progress: Double, scale: CGFloat) -> some View {
        let burst = OnboardingSproutGrowth.soilBurst(at: progress)
        let base = SproutLinePart.stemBase
        return ForEach([-1.0, 1.0], id: \.self) { side in
            Capsule()
                .fill(Color.primary.opacity(0.55 * (1 - burst)))
                .frame(width: 7 * scale, height: 2.6 * scale)
                .rotationEffect(.degrees(side * -28))
                .position(
                    x: (base.x + side * (9 + 16 * burst)) * scale,
                    y: (base.y - 4 - 12 * burst + 8 * burst * burst) * scale
                )
                .opacity(burst > 0 && burst < 1 ? 1 : 0)
        }
    }

    /// 等待按下时，豆子周围一圈账本红的波纹往外扩散，告诉用户按这里。
    private func ripple(date: Date, diameter: CGFloat) -> some View {
        let period = 1.8
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        let spread = min(phase / 0.7, 1)
        return Circle()
            .stroke(Color(.ledgerRed).opacity(0.5 * (1 - spread)), lineWidth: 1.5)
            .frame(width: diameter, height: diameter)
            .scaleEffect(1 + 0.9 * UnitCurve.easeOut.value(at: spread))
    }

    /// 标题和清单写完、还没按下也没种下时才有波纹。
    private func showsRipple(progress: Double) -> Bool {
        isDetailVisible && !isTapMode && !isPressing && !isPlanted && progress == 0
    }

    /// 种植区下方：按住模式下是一行提示，按着时隐去；点按模式下是种下按钮。
    @ViewBuilder
    private var footer: some View {
        if isTapMode {
            if hasFailed {
                Text(text("onboarding.plant.failed"))
                    .font(.footnote)
                    .foregroundStyle(Color(.ledgerRed))
            }
            Button(text(isPlanted ? "onboarding.plant.done" : "onboarding.plant.tap")) {
                plantAtOnce()
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
            .disabled(!isDetailVisible || isPlanted)
            .accessibilityIdentifier("onboarding-plant")
        } else {
            Text(text(hintKey))
                .font(.subheadline)
                .foregroundStyle(hasFailed ? AnyShapeStyle(Color(.ledgerRed)) : AnyShapeStyle(.secondary))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentTransition(.opacity)
                .opacity(isPressing || isFinishing || isPlanted ? 0 : 1)
                .animation(.easeOut(duration: 0.2), value: isPressing)
                .animation(.easeOut(duration: 0.2), value: hintKey)
                .accessibilityHidden(true)
        }
    }

    /// 按住模式下的提示：失败时说没写进去，没按够时说再按久一点，平时说按住豆子。
    private var hintKey: String {
        if hasFailed { return "onboarding.plant.failed" }
        if isHoldTooShort { return "onboarding.plant.holdLonger" }
        return "onboarding.plant.hold"
    }

    // MARK: - 按住

    /// 手指落下即按下，抬起即松手；手指移动不影响。
    private var holdGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if !isPressing { press() }
            }
            .onEnded { _ in
                release()
            }
    }

    /// 按下：豆子压进土里，芽从当前进度接着长；长满时由计时种下。
    private func press() {
        guard isDetailVisible, !isTapMode, !isPlanted, !isFinishing else { return }
        let current = clock.value(at: .now)
        let remaining = Self.holdDuration * (1 - current)
        isPressing = true
        hasFailed = false
        isHoldTooShort = false
        clock = GrowthClock(value: current, date: .now, rate: 1 / Self.holdDuration)
        haptics.press()
        haptics.beginHold(from: current, duration: remaining, accents: holdAccents(from: current))
        schedule(after: remaining) { complete() }
    }

    /// 松手：叶子已经开始展开时自己长完；更早松手芽缩回土里。
    private func release() {
        guard isPressing else { return }
        isPressing = false
        haptics.endHold()
        let current = clock.value(at: .now)
        if current >= OnboardingSproutGrowth.pointOfNoReturn {
            isFinishing = true
            clock = GrowthClock(value: current, date: .now, rate: Self.finishSpeed / Self.holdDuration)
            schedule(after: Self.holdDuration * (1 - current) / Self.finishSpeed) { complete() }
        } else {
            retract(from: current)
            withAnimation(.easeOut(duration: 0.2)) {
                isHoldTooShort = current > 0.08
            }
        }
    }

    /// 芽从某个进度缩回土里，豆子回到地面上。
    private func retract(from current: Double) {
        let duration = Self.holdDuration * current / Self.retractSpeed
        clock = GrowthClock(value: current, date: .now, rate: -Self.retractSpeed / Self.holdDuration)
        haptics.retract(duration: min(duration, 0.4))
        schedule(after: duration) { clock = GrowthClock() }
    }

    /// 取消上一个计时，过一段时间后执行。
    private func schedule(after seconds: Double, _ action: @escaping @MainActor () -> Void) {
        growthTask?.cancel()
        growthTask = Task {
            try? await Task.sleep(for: .seconds(max(seconds, 0)))
            guard !Task.isCancelled else { return }
            action()
        }
    }

    /// 扎根、破土、两片叶子展开的时刻，相对这次按下；已经过去的不再震。
    private func holdAccents(from current: Double) -> [OnboardingHaptics.HoldAccent] {
        OnboardingSproutGrowth.accents.compactMap { accent -> OnboardingHaptics.HoldAccent? in
            guard accent.progress > current else { return nil }
            return OnboardingHaptics.HoldAccent(
                time: (accent.progress - current) * Self.holdDuration,
                intensity: accent.intensity,
                sharpness: accent.sharpness
            )
        }
    }

    /// 点按模式：芽直接长满并种下。
    private func plantAtOnce() {
        guard isDetailVisible, !isPlanted else { return }
        growthTask?.cancel()
        clock = GrowthClock(value: 1)
        complete()
    }

    /// 长满：写入草稿；成功后豆子在芽尖上落定、闪一下，停一会儿再往下走；失败时芽缩回。
    private func complete() {
        guard !isPlanted else { return }
        growthTask?.cancel()
        haptics.endHold()
        isPressing = false
        isFinishing = false
        guard onPlant() else {
            AppHaptics.play(.error)
            withAnimation(.easeOut(duration: 0.2)) {
                hasFailed = true
            }
            if isTapMode {
                clock = GrowthClock()
            } else {
                retract(from: 1)
            }
            return
        }
        clock = GrowthClock(value: 1)
        isPlanted = true
        Task {
            onBeanLanded()
            withAnimation(.easeOut(duration: 0.35)) {
                sparkleProgress = 1
            }
            haptics.ripple(count: 3, interval: 0.1)
            try? await Task.sleep(for: .milliseconds(350))
            haptics.success()
            try? await Task.sleep(for: .milliseconds(1300))
            onContinue()
        }
    }

    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 按住进度随时间线性变化的记录：按开始时的值、时间和速度推算任一时刻的进度。
private struct GrowthClock {
    /// 记录时的进度。
    var value: Double = 0
    /// 记录的时刻。
    var date = Date.now
    /// 每秒的变化量，长出为正、缩回为负，静止为 0。
    var rate: Double = 0

    /// 推算某一时刻的进度，限制在 0...1。
    func value(at now: Date) -> Double {
        min(max(value + rate * now.timeIntervalSince(date), 0), 1)
    }
}

/// 按住进度怎样分给芽的各部分：先压进土里、往下扎根，再破土长茎把豆子顶上去，最后两片叶子依次展开。
///
/// 各段的区间互相叠一点，长出来是连着的；坐标都在 `SproutGeometry` 的设计画布上。
private enum OnboardingSproutGrowth {
    /// 豆子压进土里。
    static let sinkRange: ClosedRange<Double> = 0...0.08
    /// 往下扎根。
    static let rootsRange: ClosedRange<Double> = 0.03...0.28
    /// 破土长茎，把豆子顶上去。
    static let stemRange: ClosedRange<Double> = 0.2...0.62
    /// 左叶展开。
    static let leftLeafRange: ClosedRange<Double> = 0.56...0.8
    /// 右叶展开。
    static let rightLeafRange: ClosedRange<Double> = 0.7...0.94
    /// 叶子已经开始展开，过了这里松手也会自己长完。
    static let pointOfNoReturn = 0.62

    /// 途中各一下：扎根轻而闷，破土清脆，两片叶子依次一下。
    static let accents: [(progress: Double, intensity: Float, sharpness: Float)] = [
        (rootsRange.lowerBound, 0.3, 0.2),
        (stemRange.lowerBound + 0.02, 0.85, 0.9),
        (leftLeafRange.lowerBound, 0.6, 0.6),
        (rightLeafRange.lowerBound, 0.7, 0.7),
    ]

    /// 根须的书写进度。
    static func roots(at progress: Double) -> CGFloat {
        CGFloat(UnitCurve.easeOut.value(at: local(progress, in: rootsRange)))
    }

    /// 茎的书写进度：破土时快，越往上越慢。
    static func stem(at progress: Double) -> CGFloat {
        CGFloat(UnitCurve.easeOut.value(at: local(progress, in: stemRange)))
    }

    /// 叶子的书写与展开进度。
    static func leaf(_ part: SproutLinePart, at progress: Double) -> CGFloat {
        let range = part == .leftLeaf ? leftLeafRange : rightLeafRange
        return CGFloat(UnitCurve.easeInOut.value(at: local(progress, in: range)))
    }

    /// 破土溅起的土粒飞出的进度，0 为还没破土，1 为已经消失。
    static func soilBurst(at progress: Double) -> Double {
        min(local(progress, in: stemRange) / 0.35, 1)
    }

    /// 豆子的圆心：躺在地面上 → 压进土里 → 被茎尖顶着往上走，到顶时正好停在插画里芽尖的位置。
    static func beanCenter(at progress: Double) -> CGPoint {
        let radius = SproutGeometry.beanRadius
        let base = SproutLinePart.stemBase
        // 压进土里时豆子下沉到地面线穿过它下半部
        let pressedDepth = 0.35
        let stemProgress = local(progress, in: stemRange)
        guard stemProgress > 0 else {
            let sink = UnitCurve.easeOut.value(at: local(progress, in: sinkRange))
            let restY = base.y - radius - 1
            let pressedY = base.y - radius * pressedDepth
            return CGPoint(x: base.x, y: restY + (pressedY - restY) * sink)
        }
        let tip = SproutLinePart.stemPath
            .trimmedPath(from: 0, to: UnitCurve.easeOut.value(at: stemProgress))
            .currentPoint ?? base
        // 刚破土时豆子还陷在土里，茎长到三成时豆子整个托在茎尖上
        let lift = pressedDepth + (1 - pressedDepth) * UnitCurve.easeInOut.value(at: min(stemProgress / 0.3, 1))
        return CGPoint(x: tip.x, y: tip.y - radius * lift)
    }

    /// 进度在某个区间里走到了几成。
    private static func local(_ progress: Double, in range: ClosedRange<Double>) -> Double {
        min(max((progress - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }
}

/// 设计画布上的一段墨线，按进度从头画到某处，缩放到所在区域。
private struct OnboardingSproutStroke: Shape {
    /// 设计画布上的路径。
    let stroke: Path
    /// 书写进度，0 为未落笔，1 为写完。
    var progress: CGFloat

    func path(in rect: CGRect) -> Path {
        guard progress > 0 else { return Path() }
        return SproutGeometry.fit(stroke, in: rect).trimmedPath(from: 0, to: min(progress, 1))
    }
}

/// 小结里的一行：写的是什么，点它回到哪一行改。
struct OnboardingSummaryItem: Identifiable, Equatable {
    /// 点这一行回到的引导行。
    let step: OnboardingStep
    /// 已本地化的内容。
    let text: String

    var id: String { step.rawValue + text }
}

/// 把回答草稿写成一句句人话，供上方的灰色小字和小结共用。
enum OnboardingSummary {
    /// 小结清单：账本存在哪里一定有一行，其余按回答情况列出。
    ///
    /// - Parameters:
    ///   - draft: 回答草稿。
    ///   - displayName: 已登录账号的名称。
    ///   - locale: 文案语言。
    static func items(draft: OnboardingDraft, displayName: String?, locale: Locale) -> [OnboardingSummaryItem] {
        var items = [OnboardingSummaryItem(step: .account, text: storageText(draft: draft, locale: locale))]
        if draft.accountOutcome == .signedIn {
            items.append(OnboardingSummaryItem(step: .account, text: accountText(draft: draft, displayName: displayName, locale: locale)))
        }
        if let text = startPageText(draft: draft, locale: locale) {
            items.append(OnboardingSummaryItem(step: .startPage, text: text))
        }
        if let text = accountsText(draft: draft, locale: locale) {
            items.append(OnboardingSummaryItem(step: draft.hasCloudAccounts ? .account : .accounts, text: text))
        }
        return items
    }

    /// 上方灰色小字：已经答过的这一行写成一句话；演示行没有回答，返回 nil。
    static func historyText(for step: OnboardingStep, draft: OnboardingDraft, displayName: String?, locale: Locale) -> String? {
        switch step {
        case .privacy:
            return string("onboarding.history.privacy", locale)
        case .account:
            guard draft.accountOutcome != nil else { return nil }
            var parts = [accountText(draft: draft, displayName: displayName, locale: locale)]
            if draft.accountOutcome == .signedIn {
                parts.append(storageText(draft: draft, locale: locale))
            }
            return parts.joined(separator: " · ")
        case .startPage:
            return startPageText(draft: draft, locale: locale)
        case .accounts:
            return accountsText(draft: draft, locale: locale)
        case .opening, .voiceDemo, .insight, .plant, .signIn, .landing:
            return nil
        }
    }

    /// 账本存在哪里。
    static func storageText(draft: OnboardingDraft, locale: Locale) -> String {
        string(draft.syncChoice == .cloud ? "onboarding.summary.storage.cloud" : "onboarding.summary.storage.local", locale)
    }

    /// 芽豆账号的情况。
    static func accountText(draft: OnboardingDraft, displayName: String?, locale: Locale) -> String {
        switch draft.accountOutcome {
        case .signedIn:
            displayName.map { AccountLocalization.formatted("onboarding.summary.account.signedIn", value: $0, locale: locale) }
                ?? string("onboarding.summary.account.signedIn.noname", locale)
        case .offline:
            string("onboarding.account.offline", locale)
        case .firstTime, nil:
            string("onboarding.summary.account.firstTime", locale)
        }
    }

    /// 打开先看哪一页；还没答时为 nil。
    static func startPageText(draft: OnboardingDraft, locale: Locale) -> String? {
        draft.startPage.map {
            AccountLocalization.formatted("onboarding.summary.startPage", value: $0.tab.title(locale: locale), locale: locale)
        }
    }

    /// 建了哪些账户；还没答时为 nil。
    static func accountsText(draft: OnboardingDraft, locale: Locale) -> String? {
        if draft.hasCloudAccounts {
            return string("onboarding.summary.accounts.cloud", locale)
        }
        guard draft.hasAnsweredAccounts else { return nil }
        guard !draft.accounts.isEmpty else { return string("onboarding.summary.accounts.none", locale) }
        let formatter = ListFormatter()
        formatter.locale = locale
        let names = draft.accounts.map { $0.title(locale: locale) }
        return AccountLocalization.formatted(
            "onboarding.summary.accounts",
            value: formatter.string(from: names) ?? names.joined(separator: ", "),
            locale: locale
        )
    }

    private static func string(_ key: String, _ locale: Locale) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}
