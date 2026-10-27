import SwiftData
import SwiftUI

/// 首次引导：在一张纸上一问一答地写下用户的“第一页”。
///
/// 一次只写一行；答完的行缩成上方一行灰色小字，点它可以回去改。一颗账本红的豆子贯穿全程：
/// 落到纸上，跟着顶部横线往前滚，在每一行里停到对应的位置，种下后弹到芽尖，最后落到首页的语音记账入口。
/// 所有写入集中在“种下”那一刻；跳过、登录失败或中途退出，最后都落到能用的首页。
struct OnboardingView: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext
    @Environment(AuthStore.self) private var authStore

    /// 引导状态。
    let store: OnboardingStore

    /// 引导结束：正常走完、跳过或重看结束时调用，由外层移除引导。
    let onFinish: () -> Void

    /// 与每一笔对齐的触感。
    @State private var haptics = OnboardingHaptics()

    /// 豆子是否已经落到纸上；落下前藏在纸外。
    @State private var isBeanDropped = false

    /// 每加 1 豆子压扁一下。
    @State private var beanSquash = 0

    /// 这页纸是否正在被撕走。
    @State private var isTearing = false

    /// 撕纸时豆子要落到的语音入口位置，窗口坐标；入口不在屏幕上时为 nil。
    @State private var landingTarget: CGRect?

    /// 跳过时整页淡出。
    @State private var isDismissing = false

    var body: some View {
        GeometryReader { proxy in
            paper
                // 像便签一样从左上角撕下：先绕着左上角转一点，再整张落下去
                .rotationEffect(.degrees(isTearing && !reduceMotion ? 9 : 0), anchor: .topLeading)
                .offset(y: isTearing ? proxy.size.height * 1.15 : 0)
                .shadow(color: .black.opacity(isTearing ? 0.18 : 0), radius: 18, y: 8)
        }
        .overlayPreferenceValue(OnboardingBeanSlotKey.self) { slot in
            GeometryReader { proxy in
                let target = beanTarget(slot: slot, proxy: proxy)
                OnboardingBean(
                    frame: target.frame,
                    isVisible: target.isVisible,
                    squashCount: beanSquash,
                    isTracking: target.isTracking
                )
            }
            .ignoresSafeArea()
        }
        .opacity(isDismissing ? 0 : 1)
        .onAppear {
            haptics.start()
            // 中途退出后回来时不再重演开场，豆子直接落到这一行
            if store.step != .opening {
                dropBean()
            }
        }
        .onDisappear {
            haptics.stop()
        }
        // 换行时豆子滚到新位置，到位时轻轻一碰
        .onChange(of: store.step) { _, _ in
            guard isBeanDropped else { return }
            Task {
                try? await Task.sleep(for: OnboardingBean.landingDelay)
                haptics.nudge()
                beanSquash += 1
            }
        }
    }

    // MARK: - 纸面

    /// 整张纸：顶部横线与跳过、上方的灰色小字、当前这一行。
    private var paper: some View {
        VStack(spacing: 0) {
            topBar
            history
            // 新旧两行在过渡中叠在一起，不互相挤占高度
            ZStack {
                stepContent
                    .id(store.step)
                    .transition(stepTransition)
            }
            .frame(maxHeight: .infinity)
        }
        .background(Color(.paperBackground).ignoresSafeArea())
    }

    /// 顶部一条手画横线代替进度条，豆子在没有别处可停时停在横线上，随进度往前滚；右边是跳过。
    private var topBar: some View {
        HStack(spacing: 16) {
            GeometryReader { proxy in
                let progress = store.progress(isSignedIn: authStore.isAuthenticated)
                ZStack(alignment: .leading) {
                    HandDrawnRule(seed: 3)
                        .stroke(Color.primary.opacity(0.14), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                    HandDrawnRule(seed: 3)
                        .trim(from: 0, to: progress)
                        .stroke(Color.primary.opacity(0.6), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                        .animation(.easeInOut(duration: 0.6), value: progress)
                }
                .frame(height: 3)
                .frame(maxHeight: .infinity)

                Color.clear
                    .frame(width: 12, height: 12)
                    .onboardingBeanSlot(priority: 0, isVisible: isBeanDropped)
                    .position(x: max(6, proxy.size.width * progress), y: proxy.size.height / 2 - 7)
            }
            .frame(height: 24)

            if showsSkip {
                Button(text(store.mode == .replay ? "common.close" : "onboarding.skip"), action: skip)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("onboarding-skip")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .opacity(store.step == .opening || store.step == .landing ? 0 : 1)
        .animation(.easeOut(duration: 0.3), value: store.step == .opening)
    }

    /// 上方灰色小字：已经答过的行各一句，点它回到那一行。小结之后不再显示，由小结清单重写。
    @ViewBuilder
    private var history: some View {
        let items = historyItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items) { item in
                    Button {
                        withAnimation(.spring(duration: 0.5, bounce: 0.12)) {
                            store.goBack(to: item.step)
                        }
                        haptics.selection()
                    } label: {
                        Text(item.text)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text(text("onboarding.history.revise.hint")))
                    .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 12)))
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
        }
    }

    /// 当前这一行之前、答过并且有内容的行。
    private var historyItems: [OnboardingSummaryItem] {
        let steps = store.sequence(isSignedIn: authStore.isAuthenticated)
        guard let index = steps.firstIndex(of: store.step), store.step != .plant, !store.isCommitted else { return [] }
        return steps[..<index].compactMap { step -> OnboardingSummaryItem? in
            guard store.answered.contains(step),
                  let text = OnboardingSummary.historyText(
                    for: step,
                    draft: store.draft,
                    displayName: authStore.displayName,
                    locale: locale
                  )
            else { return nil }
            return OnboardingSummaryItem(step: step, text: text)
        }
    }

    /// 当前这一行。
    @ViewBuilder
    private var stepContent: some View {
        switch store.step {
        case .opening:
            OnboardingOpeningStep(haptics: haptics, onDropBean: dropBean, onContinue: next)
        case .privacy:
            OnboardingPrivacyStep(haptics: haptics, onBeanLanded: landBean, onContinue: next)
        case .account:
            OnboardingAccountStep(store: store, haptics: haptics, onContinue: next)
        case .voiceDemo:
            OnboardingVoiceDemoStep(haptics: haptics, onContinue: next)
        case .insight:
            OnboardingInsightStep(haptics: haptics, onContinue: next)
        case .startPage:
            OnboardingStartPageStep(store: store, haptics: haptics, onContinue: next)
        case .accounts:
            OnboardingAccountsStep(store: store, haptics: haptics, onContinue: next)
        case .plant:
            OnboardingPlantStep(
                store: store,
                haptics: haptics,
                onPlant: plant,
                onBeanLanded: landBean,
                onContinue: next,
                onRevise: { step in
                    withAnimation(.spring(duration: 0.5, bounce: 0.12)) {
                        store.goBack(to: step)
                    }
                }
            )
        case .signIn:
            OnboardingSignInStep(haptics: haptics, onContinue: next)
        case .landing:
            OnboardingLandingStep(haptics: haptics, onTear: tear)
        }
    }

    /// 往后写时新的一行从下方写上来、旧的一行往上收；回去改时方向相反。
    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let distance: CGFloat = store.isGoingBack ? -28 : 28
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: distance)),
            removal: .opacity.combined(with: .offset(y: -distance)).combined(with: .scale(scale: 0.98, anchor: .top))
        )
    }

    /// 种下之后、撕纸时都不能再跳过。
    private var showsSkip: Bool {
        store.mode == .replay || (!store.isCommitted && store.step != .landing)
    }

    // MARK: - 豆子

    /// 豆子此刻要停的位置：撕纸时落到语音入口；还没落下时在停放处正上方的纸外。
    private func beanTarget(
        slot: OnboardingBeanSlot?,
        proxy: GeometryProxy
    ) -> (frame: CGRect, isVisible: Bool, isTracking: Bool) {
        let window = proxy.frame(in: .global)
        if isTearing {
            guard let landingTarget else {
                // 没有语音入口可落时，豆子跟着纸一起掉出屏幕
                return (CGRect(x: proxy.size.width / 2 - 9, y: proxy.size.height + 80, width: 18, height: 18), true, false)
            }
            let diameter: CGFloat = 18
            return (
                CGRect(
                    x: landingTarget.midX - window.minX - diameter / 2,
                    y: landingTarget.midY - window.minY - diameter / 2,
                    width: diameter,
                    height: diameter
                ),
                true,
                false
            )
        }
        guard let slot else {
            return (CGRect(x: proxy.size.width / 2 - 10, y: -80, width: 20, height: 20), false, false)
        }
        let frame = proxy[slot.anchor]
        guard isBeanDropped else {
            return (frame.offsetBy(dx: 0, dy: -(frame.maxY + 80)), slot.isVisible, false)
        }
        return (frame, slot.isVisible, slot.isTracking)
    }

    /// 豆子从纸外落到纸上，落定时整段最重的一下。
    private func dropBean() {
        guard !isBeanDropped else { return }
        isBeanDropped = true
        Task {
            try? await Task.sleep(for: reduceMotion ? .zero : OnboardingBean.landingDelay)
            haptics.landing(rebound: reduceMotion ? nil : 0.16)
            beanSquash += 1
        }
    }

    /// 豆子在一行里换了位置、落定。
    private func landBean() {
        haptics.landing(rebound: reduceMotion ? nil : 0.16)
        beanSquash += 1
    }

    // MARK: - 流程

    /// 写下一行；已经是最后一行时结束引导。
    private func next() {
        let hasNext = withAnimation(.spring(duration: 0.55, bounce: 0.12)) {
            store.advance(isSignedIn: authStore.isAuthenticated)
        }
        if !hasNext {
            onFinish()
        }
    }

    /// 跳过：不写入任何草稿，直接进入首页；重看时直接关闭。
    private func skip() {
        store.skip()
        withAnimation(.easeOut(duration: 0.3)) {
            isDismissing = true
        }
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            onFinish()
        }
    }

    /// 种下：一次写入所有草稿。
    ///
    /// - Returns: 写入成功时为 true；失败时什么都没写，可以再按一次。
    private func plant() -> Bool {
        do {
            try store.commit(container: modelContext.container, locale: locale)
            return true
        } catch {
            return false
        }
    }

    /// 撕下这页纸：露出首页，豆子落到语音记账入口上，入口跳一下，然后移除引导。
    private func tear() async {
        landingTarget = VoiceEntryBeacon.shared.frame
        let duration = reduceMotion ? 0.3 : 0.75
        haptics.tear(duration: duration)
        withAnimation(.easeIn(duration: duration)) {
            isTearing = true
        }
        try? await Task.sleep(for: reduceMotion ? .milliseconds(300) : OnboardingBean.landingDelay)
        if landingTarget != nil {
            haptics.landing(rebound: reduceMotion ? nil : 0.16)
            beanSquash += 1
            VoiceEntryBeacon.shared.pulse()
        }
        try? await Task.sleep(for: .milliseconds(reduceMotion ? 200 : 650))
        onFinish()
    }

    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}
