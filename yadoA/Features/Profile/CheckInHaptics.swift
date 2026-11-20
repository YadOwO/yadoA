import CoreHaptics
import Observation
import SwiftUI

/// 每日签到的触感：用 Core Haptics 编排“点数滚动”和“落定”。
///
/// - 滚动：数字递增期间每跳一次给一下很轻的点按，叠一层很轻的持续纹理；
/// - 落定：数字停下时一下清脆的点按，叠一小段低沉的持续震动；抽到高档点数（bonus）时更重，并多一次回弹余震。
/// - 开礼包：蓄力、开盖和年度礼包的盖章，按 `CheckInGiftCeremony.Level` 一级比一级重。
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

    // MARK: - 开礼包

    /// 播放开礼包时数字滚动的触感：每跳一下很轻的点按，叠一层很轻的持续纹理；需在数字开始滚动的同一刻调用。
    ///
    /// 与 `playRoll(steps:duration:)` 不同，每跳的时刻由调用方给出，数字先快后慢时点按也跟着放慢。
    ///
    /// - Parameter times: 每一跳的时刻（从开始滚动起算），单位为秒，递增。
    func playRoll(times: [Double]) {
        guard AppHaptics.isEnabled(), engine != nil, let last = times.last, last > 0 else { return }
        var events = times.map { transient(at: $0, intensity: 0.18, sharpness: 0.5) }
        events.append(continuous(at: 0, duration: last, intensity: 0.1, sharpness: 0.2))
        play(events)
    }

    /// 播放开礼包时礼盒蓄力（晃动）的触感；需在晃动开始的同一刻调用。
    ///
    /// - 周礼包：一串均匀的轻点按，与签到滚动相同；
    /// - 月礼包：点按由轻到重、越来越密，叠一层逐渐变强的低沉震动；
    /// - 年度礼包：更久、更密、更重，最后一小段收住不震，留给礼盒落地后开盖的那一下。
    ///
    /// - Parameters:
    ///   - level: 仪式级别。
    ///   - duration: 晃动时长，单位为秒。
    func playCharge(_ level: CheckInGiftCeremony.Level, duration: Double) {
        guard level > .light else {
            playRoll(steps: 12, duration: duration)
            return
        }
        guard AppHaptics.isEnabled(), engine != nil, duration > 0 else { return }
        let isEpic = level == .epic
        let tapCount = isEpic ? 26 : 16
        // 年度礼包最后 10% 不震：礼盒落回地面，紧接着开盖
        let active = duration * (isEpic ? 0.9 : 1)
        var events = (0..<tapCount).map { index in
            let progress = Double(index) / Double(tapCount)
            // 时刻按平方根分布：前面稀、后面密
            return transient(
                at: active * progress.squareRoot(),
                intensity: Float(0.3 + (isEpic ? 0.7 : 0.5) * progress),
                sharpness: Float(0.35 + 0.3 * progress)
            )
        }
        events.append(continuous(at: 0, duration: active, intensity: isEpic ? 0.75 : 0.55, sharpness: isEpic ? 0.08 : 0.15))
        // 整段由弱到强；强度控制同时作用于点按和持续震动
        let ramp = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [
                CHHapticParameterCurve.ControlPoint(relativeTime: 0, value: 0.35),
                CHHapticParameterCurve.ControlPoint(relativeTime: active, value: 1),
            ],
            relativeTime: 0
        )
        play(events, curves: [ramp])
    }

    /// 播放开盖那一刻的触感。
    ///
    /// - 周礼包：与签到抽到高档点数时的落定相同；
    /// - 月礼包：一下重击加一段闷响，两次余震，随后几下彩纸落地般的轻响；
    /// - 年度礼包：更重的重击和更长的低频轰鸣，三次余震，随后一阵像礼炮炸开的噼啪声。
    ///
    /// - Parameter level: 仪式级别。
    func playBurst(_ level: CheckInGiftCeremony.Level) {
        guard level > .light else {
            playLanding(isBonus: true)
            return
        }
        guard AppHaptics.isEnabled() else { return }
        let isEpic = level == .epic
        guard engine != nil else {
            AppHaptics.play(.landing)
            AppHaptics.play(.success)
            return
        }
        var events = [
            transient(at: 0, intensity: 1, sharpness: isEpic ? 0.22 : 0.3),
            CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: isEpic ? 1 : 0.85),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.06),
                    CHHapticEventParameter(parameterID: .attackTime, value: 0),
                    CHHapticEventParameter(parameterID: .decayTime, value: isEpic ? 0.55 : 0.25),
                    CHHapticEventParameter(parameterID: .sustained, value: 0),
                ],
                relativeTime: 0,
                duration: isEpic ? 0.65 : 0.32
            ),
        ]
        let aftershocks: [(time: Double, intensity: Float)] = isEpic
            ? [(0.16, 0.8), (0.34, 0.55), (0.56, 0.35)]
            : [(0.15, 0.6), (0.32, 0.35)]
        events += aftershocks.map { transient(at: $0.time, intensity: $0.intensity, sharpness: 0.25) }
        // 噼啪声：时刻用黄金分割数列打散，既不规整也每次一样
        let crackleCount = isEpic ? 16 : 6
        let crackleStart = isEpic ? 0.45 : 0.4
        let crackleSpan = isEpic ? 1.2 : 0.6
        events += (0..<crackleCount).map { index in
            let spread = (Double(index) * 0.618_034).truncatingRemainder(dividingBy: 1)
            let loudness = (Double(index) * 0.377).truncatingRemainder(dividingBy: 1)
            return transient(
                at: crackleStart + crackleSpan * spread,
                intensity: Float(0.2 + 0.22 * loudness),
                sharpness: Float(0.85 + 0.15 * loudness)
            )
        }
        play(events)
    }

    /// 播放年度礼包盖章的触感：印章落下的一下重击和一小段闷响；需在印章开始落下的同一刻调用，触感在落到纸面时（约 0.16 秒后）响起。
    func playSeal() {
        guard AppHaptics.isEnabled() else { return }
        guard engine != nil else {
            AppHaptics.play(.landing)
            return
        }
        let impact = CheckInHaptics.sealImpactDelay
        play([
            transient(at: impact, intensity: 1, sharpness: 0.45),
            CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.7),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.1),
                    CHHapticEventParameter(parameterID: .attackTime, value: 0),
                    CHHapticEventParameter(parameterID: .decayTime, value: 0.12),
                    CHHapticEventParameter(parameterID: .sustained, value: 0),
                ],
                relativeTime: impact,
                duration: 0.15
            ),
            transient(at: impact + 0.13, intensity: 0.3, sharpness: 0.3),
        ])
    }

    /// 印章从开始落下到压在纸面上的时长，动画和触感共用。
    static let sealImpactDelay = 0.16

    // MARK: - 事件

    /// 生成一个持续触感事件。
    ///
    /// - Parameters:
    ///   - time: 相对整段触感开始的时刻，单位为秒。
    ///   - duration: 持续时长，单位为秒。
    ///   - intensity: 强度，0...1。
    ///   - sharpness: 锐度，0...1，越低越低沉。
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
    ///
    /// - Parameters:
    ///   - events: 触感事件。
    ///   - curves: 随时间变化的参数曲线，例如由弱到强的强度控制。
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
