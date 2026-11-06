import SwiftUI

/// 「我的」页头里签到气泡的随机位置：落在头像左侧或右侧的空白里，高度只在头像所在的竖向带内取值。
struct ProfileCheckInPlacement: Equatable {
    /// 是否在头像左侧；为 false 时在右侧。
    var isLeading: Bool

    /// 在头像竖向带内的相对高度，0 在最上，1 在最下。
    var verticalFraction: CGFloat

    /// 每次进入页面重新随机一个位置。
    static func random() -> Self {
        Self(isLeading: Bool.random(), verticalFraction: CGFloat.random(in: 0...1))
    }
}

/// 点击气泡后由页面给出的结果。
enum CheckInTapOutcome {
    /// 签到请求成功（含今天已签过的重复结果）。
    case success(AICheckInResult)

    /// 签到请求失败。
    case failure(AIBillingAPIError)

    /// 未登录，已打开登录页，气泡不做任何反馈。
    case signInRequired
}

/// 「我的」页头里的手绘芽豆签到气泡。
///
/// 待签到时缓慢上下漂浮并隔几秒轻晃一下；点击后下压、等待时轻抖，
/// 成功时冒芽、点数从 0 滚到获得的数值再向上飘走，失败时摇头并在下方显示一句原因。
/// 开启「减弱动态效果」时不漂浮、不晃、不抖、不滚数字，只做淡入淡出。
/// 触感受设置里的触感开关控制；滚动与落定由 `CheckInHaptics` 编排。
struct ProfileCheckInBadge: View {
    /// 气泡所处的阶段。
    private enum Phase: Equatable {
        /// 待签到。
        case idle
        /// 请求进行中。
        case waiting
        /// 成功后的庆祝：`shown` 是当前显示的滚动数字。
        case celebrating(points: Int, isBonus: Bool, shown: Int)
        /// 向上飘走并淡出，或（重复签到时）直接淡出。
        case leaving
    }

    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 随机位置；这里用来让每次进入页面的气泡形状也略有不同。
    let placement: ProfileCheckInPlacement

    /// 错误文案的最大宽度，即头像一侧的空白宽度。
    var messageWidth: CGFloat = 96

    /// 点击后执行签到，由页面提供。
    let onTap: () async -> CheckInTapOutcome

    /// 庆祝或淡出动画结束，页面可以移除气泡。
    let onFinished: () -> Void

    @State private var phase: Phase = .idle
    @State private var errorKey: String?
    @State private var shakeCount = 0
    @State private var bounceCount = 0
    @State private var sparkle: CGFloat = 0
    @State private var risesOnLeave = false
    @State private var haptics = CheckInHaptics()
    @State private var flow: Task<Void, Never>?
    @State private var errorClearing: Task<Void, Never>?

    /// 数字滚动总时长。
    private static let rollDuration = 0.8

    var body: some View {
        TimelineView(.animation(paused: !isMoving)) { context in
            bubbleButton
                .offset(y: driftOffset(at: context.date))
                .rotationEffect(.degrees(tilt(at: context.date)))
        }
        .keyframeAnimator(initialValue: CGFloat(0), trigger: shakeCount) { content, x in
            content.offset(x: x)
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(-6, duration: 0.06)
                LinearKeyframe(6, duration: 0.1)
                LinearKeyframe(-6, duration: 0.1)
                LinearKeyframe(6, duration: 0.1)
                LinearKeyframe(-6, duration: 0.1)
                LinearKeyframe(0, duration: 0.06)
            }
        }
        .offset(y: phase == .leaving && risesOnLeave && !reduceMotion ? -24 : 0)
        .opacity(phase == .leaving ? 0 : 1)
        .overlay(alignment: .top) { errorMessage }
        .onAppear { haptics.start() }
        .onDisappear {
            flow?.cancel()
            errorClearing?.cancel()
            haptics.stop()
        }
    }

    // MARK: - 外观

    /// 点击区域至少 72pt 的按钮。
    private var bubbleButton: some View {
        Button(action: handleTap) {
            bubble
                .frame(width: 72, height: 72)
                .contentShape(Rectangle())
        }
        .buttonStyle(CheckInPressStyle())
        .disabled(phase != .idle)
        .accessibilityLabel(text("profile.checkIn.accessibilityLabel"))
        .accessibilityIdentifier("profile-check-in")
    }

    /// 约 64×64 的手绘气泡：淡强调色底、手绘描边，里面是嫩芽和文字。
    private var bubble: some View {
        let seed = UInt64(placement.verticalFraction * 100) &+ (placement.isLeading ? 7 : 3)
        return ZStack {
            HandDrawnBlob(seed: seed)
                .fill(Color.accentColor.opacity(0.14))
            HandDrawnBlob(seed: seed)
                .stroke(Color.primary.opacity(0.55), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))

            VStack(spacing: 2) {
                Image(systemName: "leaf.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color(.ledgerGreen))
                    .keyframeAnimator(initialValue: CGFloat(1), trigger: bounceCount) { content, scale in
                        content.scaleEffect(scale)
                    } keyframes: { _ in
                        KeyframeTrack {
                            SpringKeyframe(1.4, duration: 0.18, spring: .bouncy)
                            SpringKeyframe(1, duration: 0.4, spring: .bouncy)
                        }
                    }
                labelText
                    .font(.system(.caption, design: .serif, weight: .semibold))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 6)

            if case .celebrating(_, true, _) = phase {
                BonusSparkle(progress: sparkle)
                    .stroke(Color(.ledgerGreen), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 88, height: 88)
                    .opacity(1 - sparkle * 0.6)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: 64, height: 64)
    }

    /// 气泡里的文字：平时是「签到」，庆祝时是滚动的「+N 点」。
    @ViewBuilder
    private var labelText: some View {
        if case let .celebrating(_, _, shown) = phase {
            Text(String(format: text("profile.checkIn.gained"), locale: locale, shown.formatted(.number.locale(locale))))
                .contentTransition(.numericText(value: Double(shown)))
                .monospacedDigit()
        } else {
            Text(text("profile.checkIn.label"))
        }
    }

    /// 气泡下方的一行失败原因。
    @ViewBuilder
    private var errorMessage: some View {
        if let errorKey {
            Text(text(errorKey))
                .font(.caption2)
                .foregroundStyle(Color(.ledgerRed))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: messageWidth)
                .offset(y: 74)
                .transition(.opacity)
                .accessibilityIdentifier("profile-check-in-error")
        }
    }

    // MARK: - 动态

    /// 是否需要逐帧刷新漂浮与轻晃：待签到或等待中，且没有开启减弱动态效果。
    private var isMoving: Bool {
        !reduceMotion && (phase == .idle || phase == .waiting)
    }

    /// 待签到时 ±4pt、约 2.6 秒一个周期的上下漂浮。
    private func driftOffset(at date: Date) -> CGFloat {
        guard isMoving, phase == .idle else { return 0 }
        let time = date.timeIntervalSinceReferenceDate
        return CGFloat(4 * sin(time / 2.6 * 2 * .pi))
    }

    /// 待签到时每 4 秒一次 ±8° 的招手式轻晃；等待时 ±3° 的快速轻抖。
    private func tilt(at date: Date) -> Double {
        guard isMoving else { return 0 }
        let time = date.timeIntervalSinceReferenceDate
        if phase == .waiting {
            return 3 * sin(time * 2 * .pi * 5)
        }
        let local = time.truncatingRemainder(dividingBy: 4)
        let wobbleDuration = 0.7
        guard local < wobbleDuration else { return 0 }
        let progress = local / wobbleDuration
        return 8 * sin(progress * 2 * .pi * 2) * (1 - progress)
    }

    // MARK: - 交互

    /// 点击：清掉上次的错误，进入等待并执行签到。
    private func handleTap() {
        guard phase == .idle else { return }
        errorClearing?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { errorKey = nil }
        phase = .waiting
        flow = Task {
            let outcome = await onTap()
            guard !Task.isCancelled else { return }
            await handle(outcome)
        }
    }

    /// 按签到结果播放对应反馈。
    private func handle(_ outcome: CheckInTapOutcome) async {
        switch outcome {
        case .signInRequired:
            phase = .idle
        case let .failure(error):
            fail(error)
        case let .success(result):
            if result.isDuplicate {
                risesOnLeave = false
                withAnimation(.easeOut(duration: 0.3)) { phase = .leaving }
                try? await Task.sleep(for: .seconds(0.3))
                guard !Task.isCancelled else { return }
                onFinished()
            } else {
                await celebrate(result)
            }
        }
    }

    /// 失败：error 触感、摇头，保留按钮并显示原因，4 秒后清除。
    private func fail(_ error: AIBillingAPIError) {
        AppHaptics.play(.error)
        phase = .idle
        if !reduceMotion { shakeCount += 1 }
        withAnimation(.easeOut(duration: 0.2)) { errorKey = Self.failureKey(for: error) }
        errorClearing = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { errorKey = nil }
        }
    }

    /// 成功：冒芽，点数从 0 滚到 N，落定后停留片刻向上飘走。
    private func celebrate(_ result: AICheckInResult) async {
        let points = result.points
        let isBonus = result.isBonus
        phase = .celebrating(points: points, isBonus: isBonus, shown: reduceMotion ? points : 0)
        if !reduceMotion {
            bounceCount += 1
            let steps = max(1, min(points, 15))
            haptics.playRoll(steps: steps, duration: Self.rollDuration)
            for step in 1...steps {
                try? await Task.sleep(for: .seconds(Self.rollDuration / Double(steps)))
                guard !Task.isCancelled else { return }
                let value = step == steps ? points : Int((Double(points) * Double(step) / Double(steps)).rounded())
                withAnimation(.snappy(duration: 0.15)) {
                    phase = .celebrating(points: points, isBonus: isBonus, shown: value)
                }
            }
        }
        haptics.playLanding(isBonus: isBonus)
        if isBonus && !reduceMotion {
            withAnimation(.easeOut(duration: 0.5)) { sparkle = 1 }
        }
        announce(result)

        try? await Task.sleep(for: .seconds(0.6))
        guard !Task.isCancelled else { return }
        risesOnLeave = true
        withAnimation(.easeOut(duration: 0.45)) { phase = .leaving }
        try? await Task.sleep(for: .seconds(0.45))
        guard !Task.isCancelled else { return }
        onFinished()
    }

    /// VoiceOver 播报「获得 N 点，24 小时内有效」。
    private func announce(_ result: AICheckInResult) {
        let hours = max(1, Int((result.expiresAt.timeIntervalSince(result.createdAt) / 3600).rounded()))
        AccessibilityNotification.Announcement(
            String(
                format: text("profile.checkIn.announcement"),
                locale: locale,
                result.points.formatted(.number.locale(locale)),
                hours.formatted(.number.locale(locale))
            )
        ).post()
    }

    /// 错误对应的文案 key。
    ///
    /// - Parameter error: 签到失败的原因。
    static func failureKey(for error: AIBillingAPIError) -> String {
        switch error {
        case .notSignedIn, .sessionExpired, .unauthorized:
            "profile.checkIn.failure.signIn"
        case .network, .timeout:
            "profile.checkIn.failure.network"
        case .serviceUnavailable, .invalidContract:
            "profile.checkIn.failure.unavailable"
        }
    }

    /// 按应用当前语言解析文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 气泡的按压效果：按下时下压并播放 press 触感。
private struct CheckInPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .offset(y: configuration.isPressed ? 2 : 0)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
            .appHaptic(.press, trigger: configuration.isPressed) { _, pressed in pressed }
    }
}

/// 抽到高档点数时气泡外圈的放射状闪光短线；`progress` 从 0 到 1，短线向外延伸。
private struct BonusSparkle: Shape {
    /// 闪光进度。
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    /// 短线数量。
    private let count = 8

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        for index in 0..<count {
            // 每根线长短、角度略有错落，像手画的
            let angle = (CGFloat(index) + (index.isMultiple(of: 2) ? 0.08 : -0.08)) / CGFloat(count) * 2 * .pi
            let length: CGFloat = index.isMultiple(of: 2) ? 8 : 5
            let start = outer - 12 + progress * 6
            let end = start + length
            path.move(to: CGPoint(x: center.x + cos(angle) * start, y: center.y + sin(angle) * start))
            path.addLine(to: CGPoint(x: center.x + cos(angle) * end, y: center.y + sin(angle) * end))
        }
        return path
    }
}
