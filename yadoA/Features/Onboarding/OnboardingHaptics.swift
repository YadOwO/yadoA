import CoreHaptics
import SwiftUI

/// 首次引导的触感：每一下都对应纸面上的一笔，结构与 `SproutHaptics` 相同。
///
/// - 墨水写字时一层很轻的“笔尖划纸”纹理，长短跟着这一行的书写时长；
/// - 豆子落到纸上是整段最重的一下，紧跟一次回弹的余震；
/// - 记下一笔是清脆的一下，删掉一笔稍重稍闷；
/// - 按住种下时一段持续震动，强度和锐度随时间升高，叶子长出时各一下；松手立即停止；
/// - 撕下这页纸是一段由弱到强的纹理。
///
/// 设备不支持 Core Haptics 或引擎启动失败时退回 `AppHaptics`；同样受设置里的触感开关控制。
final class OnboardingHaptics {
    /// Core Haptics 是否可用。
    private(set) var isAvailable = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    /// 触感引擎，引导出现时创建，消失时停止。
    private var engine: CHHapticEngine?

    /// 按住种下时的持续震动；松手时停止。
    private var holdPlayer: CHHapticAdvancedPatternPlayer?

    // MARK: - 生命周期

    /// 创建并启动引擎；设置里关闭了触感时不创建，之后的播放都静默跳过。
    func start() {
        guard isAvailable, engine == nil, AppHaptics.isEnabled() else { return }
        do {
            let engine = try CHHapticEngine()
            engine.isAutoShutdownEnabled = true
            // 系统重置引擎后重新启动，保证之后的每一笔仍有触感
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
        try? holdPlayer?.stop(atTime: CHHapticTimeImmediate)
        holdPlayer = nil
        engine?.stop()
        engine = nil
    }

    // MARK: - 书写

    /// 墨水写出一行字或画出一笔线时的纹理，两端弱、中间强，跟书写速度一致；没有兜底，系统触感没有这么轻的纹理。
    ///
    /// - Parameter duration: 书写时长，单位为秒。
    func pen(duration: Double) {
        guard duration > 0.05 else { return }
        let curve = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [
                .init(relativeTime: 0, value: 0.35),
                .init(relativeTime: duration * 0.3, value: 1),
                .init(relativeTime: duration * 0.75, value: 0.8),
                .init(relativeTime: duration, value: 0.2),
            ],
            relativeTime: 0
        )
        play([continuous(at: 0, duration: duration, intensity: 0.18, sharpness: 0.1)], curves: [curve])
    }

    // MARK: - 豆子

    /// 豆子落定：满强度、偏低锐度的一下，叠一小段低沉的分量，再一次回弹余震。
    ///
    /// - Parameter rebound: 落定后多久回弹；减弱动态效果时传 nil，只震一下。
    func landing(rebound: Double? = 0.16) {
        var events = [
            transient(at: 0, intensity: 1, sharpness: 0.3),
            CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.6),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.1),
                    CHHapticEventParameter(parameterID: .attackTime, value: 0),
                    CHHapticEventParameter(parameterID: .decayTime, value: 0.08),
                    CHHapticEventParameter(parameterID: .sustained, value: 0),
                ],
                relativeTime: 0,
                duration: 0.1
            ),
        ]
        if let rebound {
            events.append(transient(at: rebound, intensity: 0.4, sharpness: 0.25))
        }
        play(events, fallback: .landing)
    }

    /// 豆子挪到下一处时轻轻一碰。
    func nudge() {
        play([transient(at: 0, intensity: 0.35, sharpness: 0.35)], fallback: .tap)
    }

    // MARK: - 账本

    /// 写好一笔：对勾收笔那一下，清脆。
    func tick() {
        play([transient(at: 0, intensity: 0.6, sharpness: 0.8)], fallback: .commit)
    }

    /// 划掉一笔：划线开始时一下稍重稍闷，跟着一小段划过纸面的纹理。
    ///
    /// - Parameter duration: 划线的书写时长。
    func strike(duration: Double) {
        play([
            transient(at: 0, intensity: 0.75, sharpness: 0.35),
            continuous(at: 0.02, duration: duration, intensity: 0.3, sharpness: 0.2),
        ], fallback: .destructive)
    }

    /// 一张卡片拍到纸上：比记一笔重、比豆子落定轻。
    func slap() {
        play([
            transient(at: 0, intensity: 0.75, sharpness: 0.45),
            transient(at: 0.09, intensity: 0.25, sharpness: 0.3),
        ], fallback: .tap)
    }

    /// 选择变化：翻卡、选中选项。
    func selection() {
        play([transient(at: 0, intensity: 0.45, sharpness: 0.6)], fallback: .selection)
    }

    /// 一组小东西依次出现，每个一下，越往后越轻。
    ///
    /// - Parameters:
    ///   - count: 个数。
    ///   - interval: 相邻两个出现的间隔，单位为秒。
    func ripple(count: Int, interval: Double) {
        guard count > 0 else { return }
        let events = (0..<count).map { index in
            transient(
                at: Double(index) * interval,
                intensity: max(0.2, 0.5 - Float(index) * 0.06),
                sharpness: 0.55
            )
        }
        play(events, fallback: .selection)
    }

    /// 完成：整段引导里的成功提示，使用系统的成功触感。
    func success() {
        AppHaptics.play(.success)
    }

    // MARK: - 种下

    /// 开始按住：一段持续震动，强度和锐度随时间升高；叶子长出的那一刻各一下。
    ///
    /// - Parameters:
    ///   - duration: 按满所需的时长。
    ///   - accents: 叶子长出的时刻，相对按下的那一刻。
    func beginHold(duration: Double, accents: [Double]) {
        guard let engine else {
            AppHaptics.play(.begin)
            return
        }
        var events = [continuous(at: 0, duration: duration, intensity: 1, sharpness: 0.5)]
        events += accents.map { transient(at: $0, intensity: 0.7, sharpness: 0.7) }
        let intensity = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [
                .init(relativeTime: 0, value: 0.12),
                .init(relativeTime: duration * 0.5, value: 0.4),
                .init(relativeTime: duration, value: 0.85),
            ],
            relativeTime: 0
        )
        let sharpness = CHHapticParameterCurve(
            parameterID: .hapticSharpnessControl,
            controlPoints: [
                .init(relativeTime: 0, value: -0.4),
                .init(relativeTime: duration, value: 0.3),
            ],
            relativeTime: 0
        )
        do {
            try? holdPlayer?.stop(atTime: CHHapticTimeImmediate)
            let pattern = try CHHapticPattern(events: events, parameterCurves: [intensity, sharpness])
            let player = try engine.makeAdvancedPlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
            holdPlayer = player
        } catch {
            // 触感只是点缀，失败时不打断按住
        }
    }

    /// 松手：立即停止持续震动。
    func endHold() {
        try? holdPlayer?.stop(atTime: CHHapticTimeImmediate)
        holdPlayer = nil
    }

    // MARK: - 撕纸

    /// 撕下这页纸：一段由弱到强、颗粒越来越粗的纹理，最后断开的一下。
    ///
    /// - Parameter duration: 撕纸动画的时长。
    func tear(duration: Double) {
        let intensity = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [
                .init(relativeTime: 0, value: 0.2),
                .init(relativeTime: duration * 0.7, value: 0.7),
                .init(relativeTime: duration, value: 1),
            ],
            relativeTime: 0
        )
        play(
            [
                continuous(at: 0, duration: duration, intensity: 0.7, sharpness: 0.75),
                transient(at: duration, intensity: 0.8, sharpness: 0.9),
            ],
            curves: [intensity],
            fallback: .commit
        )
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

    /// 生成一段持续触感事件。
    ///
    /// - Parameters:
    ///   - time: 相对整段触感开始的时刻，单位为秒。
    ///   - duration: 持续时长。
    ///   - intensity: 基础强度，可再由强度曲线调节。
    ///   - sharpness: 基础锐度。
    private func continuous(at time: Double, duration: Double, intensity: Float, sharpness: Float) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ],
            relativeTime: time,
            duration: duration
        )
    }

    /// 立即播放一段触感；引擎不可用时播放兜底的系统触感，没有兜底就静默跳过。
    ///
    /// - Parameters:
    ///   - events: 触感事件。
    ///   - curves: 参数曲线。
    ///   - fallback: Core Haptics 不可用时改播的系统触感。
    private func play(_ events: [CHHapticEvent], curves: [CHHapticParameterCurve] = [], fallback: AppHaptic? = nil) {
        guard let engine else {
            if let fallback, !isAvailable {
                AppHaptics.play(fallback)
            }
            return
        }
        do {
            let pattern = try CHHapticPattern(events: events, parameterCurves: curves)
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        } catch {
            // 触感只是点缀，失败时不打断动画
        }
    }
}
