import Observation
import SwiftUI

/// 语音记账入口对外的位置与“跳一下”信号。
///
/// 首次引导结束时，豆子要落到语音入口上，入口再跳一下。入口可能在 Tab Bar 附属栏里，也可能悬浮在记账页里，
/// 和引导不在同一棵视图下，因此由入口把自己在窗口中的位置报上来，引导读位置、发信号。
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
                // 豆子落上来先压一下，再弹起回到原大小
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
