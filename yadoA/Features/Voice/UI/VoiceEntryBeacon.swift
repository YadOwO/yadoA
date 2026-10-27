import Observation
import SwiftUI

/// 语音记账入口对外的位置、“跳一下”信号和一句提示。
///
/// 首次引导撕下最后一页后，语音入口跳一下，旁边浮出一句怎么用的提示。入口可能在 Tab Bar 附属栏里，
/// 也可能悬浮在记账页里，和引导不在同一棵视图下，因此由入口把自己在窗口中的位置报上来，提示按位置摆放，引导只发信号。
@MainActor
@Observable
final class VoiceEntryBeacon {
    /// 应用内唯一的入口信号。
    static let shared = VoiceEntryBeacon()

    /// 入口在窗口坐标系中的位置；入口不在屏幕上时为 nil。
    private(set) var frame: CGRect?

    /// 最近一次报告位置的入口；首页重建时新旧入口可能交错出现和消失，只有它消失时才清掉位置。
    private var reporterID: UUID?

    /// 每加 1，入口跳一下。
    private(set) var pulseCount = 0

    /// 入口旁边的提示是否显示。
    private(set) var isHintVisible = false

    /// 自动收起提示的计时。
    private var hintTask: Task<Void, Never>?

    private init() {}

    /// 入口报告自己的位置。
    ///
    /// - Parameters:
    ///   - frame: 入口在窗口坐标系中的位置。
    ///   - reporter: 报告位置的入口标识。
    func report(_ frame: CGRect, from reporter: UUID) {
        self.frame = frame
        reporterID = reporter
    }

    /// 入口离开屏幕；不是最近报告位置的那个入口时忽略。
    ///
    /// - Parameter reporter: 离开屏幕的入口标识。
    func withdraw(from reporter: UUID) {
        guard reporterID == reporter else { return }
        frame = nil
        reporterID = nil
    }

    /// 让入口跳一下。
    func pulse() {
        pulseCount += 1
    }

    /// 在入口旁边显示一会儿提示，然后自动收起。
    ///
    /// - Parameter duration: 显示多久。
    func showHint(for duration: Duration = .seconds(4)) {
        hintTask?.cancel()
        withAnimation(.spring(duration: 0.45, bounce: 0.25)) {
            isHintVisible = true
        }
        hintTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            hideHint()
        }
    }

    /// 收起提示。
    func hideHint() {
        hintTask?.cancel()
        withAnimation(.easeOut(duration: 0.3)) {
            isHintVisible = false
        }
    }
}

/// 语音入口旁边的一句提示：浮在入口正上方，入口不在屏幕上时不显示；不拦截点按。
///
/// 挂在首页最外层，坐标按窗口换算，入口在 Tab Bar 附属栏或记账页里都能对上。
struct VoiceEntryHint: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 入口信号。
    @State private var beacon = VoiceEntryBeacon.shared

    var body: some View {
        GeometryReader { proxy in
            if beacon.isHintVisible, let frame = beacon.frame {
                let origin = proxy.frame(in: .global).origin
                // 提示比入口宽，左右各留出页边距，不超出屏幕
                let halfWidth: CGFloat = 120
                let x = min(max(frame.midX - origin.x, halfWidth + 16), proxy.size.width - halfWidth - 16)
                Text(AccountLocalization.string("onboarding.landing.hint", locale: locale))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background {
                        Capsule().fill(Color(.paperBackground))
                    }
                    .overlay {
                        HandDrawnBox(cornerRadius: 18, seed: 41)
                            .stroke(Color.primary.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                    }
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
                    .frame(maxWidth: halfWidth * 2)
                    .position(x: x, y: frame.minY - origin.y - 30)
                    .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 8)))
                    .accessibilityHidden(true)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onChange(of: beacon.isHintVisible) { _, isVisible in
            guard isVisible else { return }
            AccessibilityNotification.Announcement(
                AccountLocalization.string("onboarding.landing.hint", locale: locale)
            ).post()
        }
    }
}

/// 让语音入口报告自己的位置，并在收到信号时跳一下。
private struct VoiceEntryBeaconModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 入口信号。
    @State private var beacon = VoiceEntryBeacon.shared

    /// 这个入口的标识。
    @State private var reporterID = UUID()

    func body(content: Content) -> some View {
        let isStill = reduceMotion
        content
            .keyframeAnimator(initialValue: CGFloat(1), trigger: beacon.pulseCount) { content, scale in
                content.scaleEffect(isStill ? 1 : scale)
            } keyframes: { _ in
                // 先压一下，再弹起回到原大小
                SpringKeyframe(0.9, duration: 0.1)
                SpringKeyframe(1.08, duration: 0.18)
                SpringKeyframe(1, duration: 0.45, spring: .bouncy)
            }
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                beacon.report(frame, from: reporterID)
            }
            .onDisappear {
                beacon.withdraw(from: reporterID)
            }
    }
}

extension View {
    /// 把这个视图登记为语音记账入口：报告位置，收到信号时跳一下。
    func voiceEntryBeacon() -> some View {
        modifier(VoiceEntryBeaconModifier())
    }
}
