import CoreHaptics
import Observation
import SwiftUI

/// 芽豆插画的触感：用 Core Haptics 把震动对齐到插画的每一笔。
///
/// 入场触感按 `SproutTimeline` 分两段排好，每段都与对应动画在同一刻启动，避免长时间计时累积误差：
/// - 书写墨线时一层很轻的“笔尖划纸”持续纹理，强弱随书写速度变化；
/// - 每落一笔给一下细小的轻点；
/// - 豆子弹出时整段最重的一下“落定”，带一点低沉的分量，紧跟一次回弹的余震；
/// - 三道闪光短线各一下清脆的细点。
///
/// 设备不支持 Core Haptics 或引擎启动失败时 `isAvailable` 为 false，由插画退回 `appHaptic`。
/// 同样受设置里的触感开关控制（见 `AppHaptics`）。
@Observable
final class SproutHaptics {
    /// Core Haptics 是否可用；为 false 时由调用方使用系统触感兜底。
    private(set) var isAvailable = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    /// 触感引擎，插画出现时创建，消失时停止。
    @ObservationIgnored private var engine: CHHapticEngine?

    // MARK: - 强度参数

    /// 笔尖划纸纹理的基础强度，书写最快时达到；整体保持很轻，只做背景质感。
    private let penIntensity: Float = 0.2
    /// 笔尖划纸纹理的锐度，偏低更像纸面的沙沙感。
    private let penSharpness: Float = 0.1
    /// 纹理在书写起止最慢处保留的最低比例，避免两端完全断掉。
    private let penFloor: Float = 0.3

    // MARK: - 生命周期

    /// 创建并启动引擎；失败时标记为不可用。设置里关闭了触感时不创建引擎，之后的播放都静默跳过。
    func start() {
        guard isAvailable, engine == nil, AppHaptics.isEnabled() else { return }
        do {
            let engine = try CHHapticEngine()
            engine.isAutoShutdownEnabled = true
            // 系统重置引擎（如音频服务重启）后重新启动，保证之后的点按仍有触感
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

    /// 播放书写墨线的触感：笔尖纹理与每一笔的落笔轻点；需在墨线开始书写的同一刻调用。
    func playLine() {
        var events = [penTexture()]
        events += SproutTimeline.strokeStartTimes.enumerated().map { index, time in
            // 第一笔是落笔，比之后的换笔稍重
            transient(at: time, intensity: index == 0 ? 0.42 : 0.28, sharpness: 0.45)
        }
        play(events, curves: [penIntensityCurve()])
    }

    /// 播放豆子弹出与闪光短线的触感；需在豆子弹出动画启动的同一刻调用，时间都相对这一刻。
    func playBean() {
        var events = beanPopEvents(
            landing: SproutTimeline.beanLandingOffset,
            rebound: SproutTimeline.beanReboundOffset
        )
        events += SproutTimeline.sparkleStrokeTimes.map { time in
            transient(at: time - SproutTimeline.beanStart, intensity: 0.3, sharpness: 0.95)
        }
        play(events)
    }

    /// 只播放豆子落定的一下，用于“减弱动态效果”下豆子直接出现、没有弹簧过程的情况。
    func playBeanAppearance() {
        play(beanPopEvents(landing: 0, rebound: nil))
    }

    /// 点按豆子：按下一下轻弹，豆子回落时一次很轻的余震，与弹跳关键帧对齐。
    func playTap() {
        play([
            transient(at: 0, intensity: 0.55, sharpness: 0.6),
            transient(at: 0.16, intensity: 0.2, sharpness: 0.3),
        ])
    }

    // MARK: - 事件

    /// 豆子弹出：整段里最重的一下。放大到原大小时满强度、偏低锐度的“咚”，
    /// 叠一小段低沉的持续震动给出分量，冲过头后回落到原大小时再一次余震。
    ///
    /// - Parameters:
    ///   - landing: 豆子第一次放大到原大小的时刻。
    ///   - rebound: 豆子冲过头后回落到原大小的时刻；没有弹簧过程时为 nil。
    /// - Returns: 落定、分量，以及可选的余震事件。
    private func beanPopEvents(landing: Double, rebound: Double?) -> [CHHapticEvent] {
        var events = [
            transient(at: landing, intensity: 1, sharpness: 0.3),
            CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.6),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.1),
                    // 起震即到顶，随后迅速衰减，像实物落下后的闷响
                    CHHapticEventParameter(parameterID: .attackTime, value: 0),
                    CHHapticEventParameter(parameterID: .decayTime, value: 0.08),
                    CHHapticEventParameter(parameterID: .sustained, value: 0),
                ],
                relativeTime: landing,
                duration: 0.1
            ),
        ]
        if let rebound {
            events.append(transient(at: rebound, intensity: 0.45, sharpness: 0.25))
        }
        return events
    }

    /// 书写墨线全程的持续纹理。
    private func penTexture() -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: penIntensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: penSharpness),
            ],
            relativeTime: 0,
            duration: SproutTimeline.lineDuration
        )
    }

    /// 纹理强度随书写速度变化：按 `easeInOut` 的速度采样，最快处为 1，两端不低于 `penFloor`。
    private func penIntensityCurve() -> CHHapticParameterCurve {
        let curve = UnitCurve.easeInOut
        // Core Haptics 单条曲线最多 16 个控制点
        let samples = 12
        let velocities = (0...samples).map { curve.velocity(at: Double($0) / Double(samples)) }
        let peak = velocities.max() ?? 1
        let points = velocities.enumerated().map { index, velocity in
            CHHapticParameterCurve.ControlPoint(
                relativeTime: SproutTimeline.lineDuration * Double(index) / Double(samples),
                value: max(penFloor, Float(velocity / peak))
            )
        }
        return CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: points, relativeTime: 0)
    }

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
    private func play(_ events: [CHHapticEvent], curves: [CHHapticParameterCurve] = []) {
        guard let engine else { return }
        do {
            let pattern = try CHHapticPattern(events: events, parameterCurves: curves)
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        } catch {
            // 触感只是点缀，失败时不打断动画
        }
    }
}
