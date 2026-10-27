import SwiftUI

/// 小结与种下：前面的回答重新写成一份清单；按住按钮，豆子埋进地里，芽随时间长出，长满时豆子弹到芽尖。
///
/// 长满的那一刻一次写入所有草稿；失败时在纸上提示，可以再按一次。松手就缩回，什么都不写。
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

    /// 豆子弹到芽尖、落定。
    let onBeanLanded: () -> Void

    /// 种下之后进入下一行。
    let onContinue: () -> Void

    /// 点清单里的一行，回到那一行改。
    let onRevise: (OnboardingStep) -> Void

    /// 按满所需的时长。
    static let holdDuration: Double = 1.8

    /// 松手后缩回比长出快的倍数。
    private static let retractSpeed: Double = 2.4

    /// 标题写完后依次写出清单。
    @State private var isDetailVisible = false

    /// 已经写出的清单行数。
    @State private var inkedCount = 0

    /// 芽的生长进度，0 为只有地面，1 为长满。
    @State private var growth: CGFloat = 0

    /// 当前的实际生长进度与变化速度，用来在动画进行中算出“现在长到哪了”。
    @State private var growthClock = GrowthClock()

    /// 手指是否按着。
    @State private var isPressing = false

    /// 是否已经种下。
    @State private var isPlanted = false

    /// 闪光短线的书写进度。
    @State private var sparkleProgress: CGFloat = 0

    /// 写入失败。
    @State private var hasFailed = false

    /// 按满后种下的计时。
    @State private var holdTask: Task<Void, Never>?

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

            sprout
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
        } actions: {
            if hasFailed {
                Text(text("onboarding.plant.failed"))
                    .font(.footnote)
                    .foregroundStyle(Color(.ledgerRed))
                    .transition(.opacity)
            }
            holdButton
                .onboardingReveal(isDetailVisible, delay: 0.4)
                .disabled(!isDetailVisible || isPlanted)
        }
        .onChange(of: isDetailVisible) { _, isVisible in
            guard isVisible else { return }
            Task { await inkSummary() }
        }
        .onDisappear {
            holdTask?.cancel()
            haptics.endHold()
        }
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
                .disabled(isPlanted)
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

    // MARK: - 芽

    /// 发芽插画的墨线，按生长进度一笔一笔画出；豆子不在这里画，由引导里那颗豆子停到这里。
    private var sprout: some View {
        let size: CGFloat = 190
        let scale = size / SproutGeometry.canvas
        let line = StrokeStyle(lineWidth: 4.8 * scale, lineCap: .round, lineJoin: .round)
        let beanDiameter = SproutGeometry.beanRadius * 2 * scale
        return ZStack(alignment: .topLeading) {
            // 还没长时先露出一道地面，告诉用户豆子要埋在这里
            HandDrawnRule(seed: 91)
                .stroke(Color.primary.opacity(0.3), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                .frame(width: size * 0.62, height: 3)
                .position(x: size * 0.49, y: 198 * scale)
                .opacity(growth > 0.05 ? 0 : 1)

            ForEach(SproutLinePart.allCases, id: \.self) { part in
                SproutStrokePart(part: part, progress: growth)
                    .stroke(Color.primary, style: line)
            }

            SproutSparkleShape()
                .trim(from: 0, to: sparkleProgress)
                .stroke(Color.primary.opacity(0.5), style: StrokeStyle(lineWidth: 2.8 * scale, lineCap: .round))

            Color.clear
                .frame(width: beanDiameter, height: beanDiameter)
                .onboardingBeanSlot()
                .position(beanPosition(scale: scale, diameter: beanDiameter))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// 豆子的位置：没按时躺在地面上，按住时埋进地里一半，种下后弹到芽尖。
    private func beanPosition(scale: CGFloat, diameter: CGFloat) -> CGPoint {
        if isPlanted {
            return CGPoint(x: SproutGeometry.beanCenter.x * scale, y: SproutGeometry.beanCenter.y * scale)
        }
        let groundY = 197 * scale
        let y = isPressing ? groundY + 2 : groundY - diameter / 2
        return CGPoint(x: 118 * scale, y: y)
    }

    // MARK: - 按住

    /// 按住种下的按钮：按着时墨色从左往右铺满；减弱动态效果或 VoiceOver 下改为点按。
    @ViewBuilder
    private var holdButton: some View {
        let title = text(isPlanted ? "onboarding.plant.done" : "onboarding.plant.hold")
        if reduceMotion || isVoiceOverEnabled {
            Button(title) {
                complete()
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
            .accessibilityIdentifier("onboarding-plant")
        } else {
            Text(title)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(Color.accentColor.opacity(0.16))
                            .frame(width: max(52, proxy.size.width * growth))
                            .opacity(growth > 0 ? 1 : 0)
                    }
                }
                .background {
                    HandDrawnBox(cornerRadius: 26, seed: 97)
                        .stroke(Color.primary.opacity(0.85), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                }
                .scaleEffect(isPressing ? 0.97 : 1)
                .animation(.spring(duration: 0.25, bounce: 0.4), value: isPressing)
                .contentShape(Capsule())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !isPressing { pressChanged(true) }
                        }
                        .onEnded { _ in
                            pressChanged(false)
                        }
                )
                .accessibilityElement()
                .accessibilityLabel(title)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { complete() }
                .accessibilityIdentifier("onboarding-plant")
        }
    }

    /// 按下开始长，松手缩回；按满由计时触发种下。
    private func pressChanged(_ pressing: Bool) {
        guard !isPlanted else { return }
        let current = growthClock.value(at: .now)
        if pressing {
            isPressing = true
            hasFailed = false
            let remaining = Self.holdDuration * (1 - current)
            growthClock = GrowthClock(value: current, date: .now, rate: 1 / Self.holdDuration)
            haptics.beginHold(duration: remaining, accents: leafAccents(from: current))
            withAnimation(.linear(duration: remaining)) {
                growth = 1
            }
            holdTask?.cancel()
            holdTask = Task {
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled else { return }
                complete()
            }
        } else {
            isPressing = false
            holdTask?.cancel()
            haptics.endHold()
            let duration = Self.holdDuration * current / Self.retractSpeed
            growthClock = GrowthClock(value: current, date: .now, rate: -Self.retractSpeed / Self.holdDuration)
            withAnimation(.easeOut(duration: max(duration, 0.15))) {
                growth = 0
            }
        }
    }

    /// 两片叶子开始长出的时刻，相对这次按下。
    private func leafAccents(from current: Double) -> [Double] {
        [SproutLinePart.leftLeaf, .rightLeaf].compactMap { part -> Double? in
            let start = part.drawRange.lowerBound
            return start > current ? (start - current) * Self.holdDuration : nil
        }
    }

    /// 长满：写入草稿；成功后豆子弹到芽尖并发出闪光，停一下再往下走。
    private func complete() {
        guard !isPlanted else { return }
        holdTask?.cancel()
        haptics.endHold()
        isPressing = false
        guard onPlant() else {
            AppHaptics.play(.error)
            growthClock = GrowthClock()
            withAnimation(.easeOut(duration: 0.4)) {
                hasFailed = true
                growth = 0
            }
            return
        }
        withAnimation(.easeOut(duration: 0.2)) {
            growth = 1
        }
        isPlanted = true
        Task {
            try? await Task.sleep(for: OnboardingBean.landingDelay)
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

/// 生长进度随时间线性变化的记录：动画进行中界面拿不到实际进度，按开始时的值、时间和速度推算。
private struct GrowthClock {
    /// 记录时的进度。
    var value: Double = 0
    /// 记录的时刻。
    var date = Date.now
    /// 每秒的变化量，长出为正、缩回为负。
    var rate: Double = 0

    /// 推算某一时刻的进度，限制在 0...1。
    func value(at now: Date) -> Double {
        min(max(value + rate * now.timeIntervalSince(date), 0), 1)
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
