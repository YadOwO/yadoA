import SwiftUI

/// 第一页：前面的回答重新写成一份清单，每写一行，旁边的芽长一节；写完时豆子落到芽尖上。
///
/// 芽是用户自己的回答长出来的，只是插画，不需要操作。底部只有一个按钮：点下去一次写入所有草稿，
/// 撕下这页纸露出首页，豆子落到语音记账入口上——引导结束在“记第一笔”这个真实动作上，而不是一个庆祝页。
/// 写入失败时留在这一页提示，可以再点一次。
struct OnboardingPlantStep: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AuthStore.self) private var authStore

    /// 引导状态。
    let store: OnboardingStore

    /// 触感。
    let haptics: OnboardingHaptics

    /// 一次写入所有草稿；成功返回 true。
    let onPlant: () -> Bool

    /// 豆子在芽尖上落定。
    let onBeanLanded: () -> Void

    /// 写入成功后撕下这页纸、结束引导。
    let onFinish: () async -> Void

    /// 点清单里的一行，回到那一行改。
    let onRevise: (OnboardingStep) -> Void

    /// 插画边长。
    private static let sproutSize: CGFloat = 170

    /// 标题写完后依次写出清单。
    @State private var isDetailVisible = false

    /// 已经写出的清单行数。
    @State private var inkedCount = 0

    /// 芽的生长进度，0 为只有地面，1 为长满。
    @State private var growth: Double = 0

    /// 清单写完，豆子开始往芽尖落。
    @State private var isBeanCalled = false

    /// 豆子已经落在芽尖上，叶子随之一颤。
    @State private var isBeanLanded = false

    /// 闪光短线的书写进度。
    @State private var sparkleProgress: CGFloat = 0

    /// 豆子落定后出现底部按钮。
    @State private var isReady = false

    /// 写入失败。
    @State private var hasFailed = false

    /// 已经写入，正在撕下这页纸。
    @State private var isFinishing = false

    var body: some View {
        OnboardingPage {
            OnboardingInkText(
                text: text("onboarding.plant.title"),
                font: .system(size: 30, weight: .regular, design: .serif),
                haptics: haptics,
                onWritten: { isDetailVisible = true }
            )
            .accessibilityAddTraits(.isHeader)

            summary
                .padding(.top, 20)

            sprout
                .frame(maxWidth: .infinity)
                .padding(.top, 16)

            Text(text(store.mode == .replay ? "onboarding.plant.note.replay" : "onboarding.plant.note"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .onboardingReveal(isReady)
        } actions: {
            if hasFailed {
                Text(text("onboarding.plant.failed"))
                    .font(.footnote)
                    .foregroundStyle(Color(.ledgerRed))
                    .transition(.opacity)
            }
            Button(text(finishTitleKey), action: finish)
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .onboardingReveal(isReady)
                .disabled(!isReady || isFinishing)
                .accessibilityIdentifier("onboarding-finish")
        }
        .onChange(of: isDetailVisible) { _, isVisible in
            guard isVisible else { return }
            Task { await growWithSummary() }
        }
    }

    /// 底部按钮：重看时“写好了”；打开先看记账时直接去记第一笔，先看账户时进入芽豆资产。
    private var finishTitleKey: String {
        if store.mode == .replay { return "onboarding.plant.replayDone" }
        return store.draft.startPage == .accounts ? "onboarding.opening.enter" : "onboarding.plant.start"
    }

    // MARK: - 清单

    /// 前面每一行的回答，墨色重写一遍，每行前面一个小对勾；点按钮之前可以点回去改。
    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(summaryItems.enumerated()), id: \.element.id) { index, item in
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
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .opacity(isReady ? 1 : 0)
                    }
                    .frame(minHeight: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isFinishing)
                .opacity(index < inkedCount ? 1 : 0)
                .offset(x: index < inkedCount || reduceMotion ? 0 : -6)
                .animation(.easeOut(duration: 0.3), value: inkedCount)
                .accessibilityHint(Text(text("onboarding.plant.revise.hint")))
            }
        }
    }

    /// 清单的各行；重看时没有问账号和同步，不写账本存在哪里和账号这两行，免得和实际情况对不上。
    private var summaryItems: [OnboardingSummaryItem] {
        let items = OnboardingSummary.items(draft: store.draft, displayName: authStore.displayName, locale: locale)
        return store.mode == .replay ? items.filter { $0.step != .account } : items
    }

    /// 一行一行写出清单：每写一行打一个勾、芽长一节；写完后豆子落到芽尖上，再出现按钮。
    private func growWithSummary() async {
        guard inkedCount == 0 else { return }
        let count = summaryItems.count
        if reduceMotion {
            inkedCount = count
            growth = 1
            await callBean()
            return
        }
        for index in 0..<count {
            try? await Task.sleep(for: .milliseconds(index == 0 ? 150 : 480))
            inkedCount = index + 1
            haptics.tick()
            haptics.pen(duration: 0.5)
            withAnimation(.easeOut(duration: 0.55)) {
                growth = Double(index + 1) / Double(count)
            }
        }
        if growth < 1 {
            withAnimation(.easeOut(duration: 0.55)) {
                growth = 1
            }
        }
        try? await Task.sleep(for: .milliseconds(500))
        await callBean()
    }

    /// 豆子从顶部横线落到芽尖上：落定时最重的一下，闪一下、叶子一颤，然后出现按钮。
    private func callBean() async {
        isBeanCalled = true
        try? await Task.sleep(for: reduceMotion ? .zero : OnboardingBean.landingDelay)
        onBeanLanded()
        isBeanLanded = true
        withAnimation(.easeOut(duration: 0.35)) {
            sparkleProgress = 1
        }
        haptics.ripple(count: 3, interval: 0.1)
        try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 450))
        isReady = true
    }

    // MARK: - 芽

    /// 发芽插画；豆子不在这里画，由引导里那颗豆子落到芽尖上。
    private var sprout: some View {
        let size = Self.sproutSize
        let scale = size / SproutGeometry.canvas
        let beanDiameter = SproutGeometry.beanRadius * 2 * scale
        return ZStack(alignment: .topLeading) {
            OnboardingSprout(
                progress: growth,
                sparkleProgress: sparkleProgress,
                wobbleTrigger: isBeanLanded
            )

            Color.clear
                .frame(width: beanDiameter, height: beanDiameter)
                .onboardingBeanSlot(isActive: isBeanCalled)
                .position(x: SproutGeometry.beanCenter.x * scale, y: SproutGeometry.beanCenter.y * scale)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    // MARK: - 结束

    /// 写入草稿；成功后撕下这页纸，失败时留在这一页提示。
    private func finish() {
        guard !isFinishing else { return }
        guard onPlant() else {
            AppHaptics.play(.error)
            withAnimation(.easeOut(duration: 0.2)) {
                hasFailed = true
            }
            return
        }
        hasFailed = false
        isFinishing = true
        Task { await onFinish() }
    }

    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 第一页上的芽：地面一直在；根、茎、两片叶子按生长进度依次长出。生长进度可以动画。
private struct OnboardingSprout: View, Animatable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 生长进度，0 为只有地面，1 为长满。
    var progress: Double

    /// 闪光短线的书写进度。
    var sparkleProgress: CGFloat

    /// 变化时两片叶子一起上甩，再回弹落定。
    var wobbleTrigger: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width, proxy.size.height) / SproutGeometry.canvas
            let line = StrokeStyle(lineWidth: 4.8 * scale, lineCap: .round, lineJoin: .round)
            let isStill = reduceMotion
            ZStack(alignment: .topLeading) {
                OnboardingSproutStroke(canvasPath: SproutLinePart.groundPath, progress: 1)
                    .stroke(Color.primary, style: line)

                // 根在土里，墨色淡一些
                OnboardingSproutStroke(canvasPath: SproutLinePart.rootsPath, progress: OnboardingSproutGrowth.roots(at: progress))
                    .stroke(Color.primary.opacity(0.45), style: line)

                OnboardingSproutStroke(canvasPath: SproutLinePart.stemPath, progress: OnboardingSproutGrowth.stem(at: progress))
                    .stroke(Color.primary, style: line)

                soilFlecks(scale: scale)

                ForEach([SproutLinePart.leftLeaf, .rightLeaf], id: \.self) { part in
                    let unfold = OnboardingSproutGrowth.leaf(part, at: progress)
                    OnboardingSproutStroke(canvasPath: part.path, progress: unfold)
                        .stroke(Color.primary, style: line)
                        // 叶子贴着茎合拢着长出来，边长边展开
                        .rotationEffect(.degrees(part.liftDirection * 30 * Double(1 - unfold)), anchor: part.anchor)
                        .keyframeAnimator(initialValue: 0.0, trigger: wobbleTrigger) { content, wobble in
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
            }
        }
    }

    /// 破土的一瞬，茎两侧各溅起一小粒土，往外飞一点就消失。
    private func soilFlecks(scale: CGFloat) -> some View {
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
}

/// 生长进度怎样分给芽的各部分：先往下扎根，再破土长茎，最后两片叶子依次展开。
///
/// 各段的区间互相叠一点，长出来是连着的；坐标都在 `SproutGeometry` 的设计画布上。
private enum OnboardingSproutGrowth {
    /// 往下扎根。
    static let rootsRange: ClosedRange<Double> = 0...0.25
    /// 破土长茎。
    static let stemRange: ClosedRange<Double> = 0.18...0.6
    /// 左叶展开。
    static let leftLeafRange: ClosedRange<Double> = 0.52...0.8
    /// 右叶展开。
    static let rightLeafRange: ClosedRange<Double> = 0.72...1

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

    /// 进度在某个区间里走到了几成。
    private static func local(_ progress: Double, in range: ClosedRange<Double>) -> Double {
        min(max((progress - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }
}

/// 设计画布上的一段墨线，按进度从头画到某处，缩放到所在区域。
private struct OnboardingSproutStroke: Shape {
    /// 设计画布上的路径。
    let canvasPath: Path
    /// 书写进度，0 为未落笔，1 为写完。
    var progress: CGFloat

    func path(in rect: CGRect) -> Path {
        guard progress > 0 else { return Path() }
        return SproutGeometry.fit(canvasPath, in: rect).trimmedPath(from: 0, to: min(progress, 1))
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
        case .opening, .voiceDemo, .insight, .plant, .signIn:
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
