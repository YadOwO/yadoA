import CoreHaptics
import Observation
import SwiftUI

/// 每日签到的触感：用 Core Haptics 编排“点数滚动”和“落定”。
///
/// - 滚动：数字递增期间每跳一次给一下很轻的点按，叠一层很轻的持续纹理；
/// - 落定：数字停下时一下清脆的点按，叠一小段低沉的持续震动；抽到高档点数（bonus）时更重，并多一次回弹余震。
///
/// 设备不支持 Core Haptics 或引擎启动失败时 `isAvailable` 为 false，滚动不震，落定退回 `AppHaptics`。
/// 所有播放都受设置里的触感开关控制（见 `AppHaptics`）。
@Observable
final class CheckInHaptics {
    /// Core Haptics 是否可用；为 false 时由 `AppHaptics` 兜底。
    private(set) var isAvailable = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    /// 触感引擎，气泡出现时创建，消失时停止。
    @ObservationIgnored private var engine: CHHapticEngine?

    // MARK: - 生命周期

    /// 创建并启动引擎；失败时标记为不可用。设置里关闭了触感时不创建引擎。
    func start() {
        guard isAvailable, engine == nil, AppHaptics.isEnabled() else { return }
        do {
            let engine = try CHHapticEngine()
            engine.isAutoShutdownEnabled = true
            // 系统重置引擎（如音频服务重启）后重新启动，保证之后仍有触感
            engine.resetHandler = { @Sendable [weak self] in
                Task { @MainActor in
                    try? self?.engine?.start()
                }
            }
            try engine.start()
            self.engine = engine
        } catch {
            isAvailable = false
        }
    }

    /// 停止引擎并释放。
    func stop() {
        engine?.stop()
        engine = nil
    }

    // MARK: - 播放

    /// 播放点数滚动的触感；需在数字开始递增的同一刻调用。
    ///
    /// - Parameters:
    ///   - steps: 数字跳动的次数。
    ///   - duration: 滚动总时长，单位为秒。
    func playRoll(steps: Int, duration: Double) {
        guard AppHaptics.isEnabled(), engine != nil, steps > 0 else { return }
        var events = (0..<steps).map { index in
            transient(at: duration * Double(index) / Double(steps), intensity: 0.18, sharpness: 0.5)
        }
        events.append(
            CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.1),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.2),
                ],
                relativeTime: 0,
                duration: duration
            )
        )
        play(events)
    }

    /// 播放数字停下时的落定触感。
    ///
    /// - Parameter isBonus: 是否抽到了高档点数；为 true 时更重并多一次回弹余震。
    func playLanding(isBonus: Bool) {
        guard AppHaptics.isEnabled() else { return }
        guard engine != nil else {
            AppHaptics.play(.landing)
            if isBonus { AppHaptics.play(.success) }
            return
        }
        var events = [
            transient(at: 0, intensity: isBonus ? 1 : 0.8, sharpness: 0.3),
            CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: isBonus ? 0.7 : 0.5),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.1),
                    // 起震即到顶，随后迅速衰减，像实物落下后的闷响
                    CHHapticEventParameter(parameterID: .attackTime, value: 0),
                    CHHapticEventParameter(parameterID: .decayTime, value: 0.08),
                    CHHapticEventParameter(parameterID: .sustained, value: 0),
                ],
                relativeTime: 0,
                duration: 0.1
            ),
        ]
        if isBonus {
            events.append(transient(at: 0.16, intensity: 0.5, sharpness: 0.25))
        }
        play(events)
    }

    // MARK: - 事件

    /// 生成一个瞬时触感事件。
    ///
    /// - Parameters:
    ///   - time: 相对整段触感开始的时刻，单位为秒。
    ///   - intensity: 强度，0...1。
    ///   - sharpness: 锐度，0...1，越高越清脆。
    private func transient(at time: Double, intensity: Float, sharpness: Float) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ],
            relativeTime: time
        )
    }

    /// 立即播放一段触感；引擎不可用或播放失败时静默跳过，触感不影响动画。
    private func play(_ events: [CHHapticEvent]) {
        guard let engine else { return }
        do {
            let pattern = try CHHapticPattern(events: events, parameterCurves: [])
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        } catch {
            // 触感只是点缀，失败时不打断动画
        }
    }
}
