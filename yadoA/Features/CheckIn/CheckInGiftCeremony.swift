import CoreGraphics
import Foundation

/// 开礼包仪式的分量：周礼包、月礼包、年度礼包一级比一级重，档位越高，等待、晃动、开盖、数字和触感都越重。
///
/// - 周礼包（基准）：晃一下，盒盖飞起，光芒转开，一把彩纸，数字滚到获得的点数。
/// - 月礼包：没打开时周围就有星光闪烁；晃得更久更猛，盒盖被顶得直跳，盒缝里的光越来越亮；
///   开盖时整屏闪一下，一圈冲击波，彩纸分两波喷出，数字滚到最后变慢，停下时放大一下。
/// - 年度礼包：没打开时盒缝就在发光；晃到后段礼盒离地悬起，砸回地面后才开盖；开盖时画面震动，
///   两圈冲击波，两侧礼炮齐发，星星从屏幕顶上飘落；数字滚得最久，停下时一圈光环，最后盖上一枚印章。
///
/// 这里只放纯数值，动画和触感由 `CheckInGiftOpeningView`、`CheckInHaptics` 按它编排。
nonisolated struct CheckInGiftCeremony: Equatable {
    /// 仪式的级别，周、月、年依次加重。
    nonisolated enum Level: Int, Comparable, Sendable {
        /// 周礼包。
        case light
        /// 月礼包。
        case grand
        /// 年度礼包。
        case epic

        static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// 某一刻礼盒的姿态：待开时的起伏和点开后的蓄力都换算成它。
    nonisolated struct BoxPose: Equatable, Sendable {
        /// 以盒底为轴的倾斜角度，单位为度。
        var angle: Double = 0
        /// 竖直位移，负数向上。
        var offsetY: CGFloat = 0
        /// 盒盖被顶起的程度，与 `CheckInGiftBox.lidLift` 同一个刻度。
        var lidLift: CGFloat = 0
        /// 盒缝透出的光，0 到 1。
        var glow: CGFloat = 0

        /// 静止：不倾斜、不位移、盒盖盖好、不透光。
        static let rest = BoxPose()
    }

    /// 仪式级别。
    let level: Level

    /// 按礼包档位取仪式；服务端以后新增、客户端还不认识的档位按周礼包处理。
    ///
    /// - Parameter tier: 礼包档位。
    init(tier: AICheckInGiftTier) {
        switch tier {
        case .weekly, .unknown: level = .light
        case .monthly: level = .grand
        case .yearly: level = .epic
        }
    }

    /// 按周、月、年取三个值中的一个。
    private func pick<Value>(_ light: Value, _ grand: Value, _ epic: Value) -> Value {
        switch level {
        case .light: light
        case .grand: grand
        case .epic: epic
        }
    }

    // MARK: - 待开

    /// 礼盒边长。
    var boxSize: CGFloat { pick(188, 200, 212) }

    /// 待开时礼盒周围闪烁的星光数量；周礼包没有。
    var sparkleCount: Int { pick(0, 6, 12) }

    /// 整屏背后那团主色光的浓淡；周礼包没有，开盖后再加亮 `ambientBoost`。
    var ambientGlow: Double { pick(0, 0.07, 0.11) }

    /// 开盖后背后那团光再加亮多少。
    var ambientBoost: Double { pick(0, 0.07, 0.12) }

    /// 待开时盒缝就透出的光；只有年度礼包有。
    var idleGlow: CGFloat { pick(0, 0, 0.22) }

    /// 待开时轻晃一次的间隔，档位越高越不安分。
    var idleTiltInterval: Double { pick(3, 2.6, 2.2) }

    /// 待开时某一刻的姿态：±5pt、约 2.4 秒一个周期的上下起伏，每隔一会儿轻晃一下，像里面有东西在动；年度礼包的盒缝还会一明一暗。
    ///
    /// - Parameter time: 任意连续的时刻，单位为秒，例如 `timeIntervalSinceReferenceDate`。
    func idlePose(time: Double) -> BoxPose {
        var pose = BoxPose()
        pose.offsetY = CGFloat(5 * sin(time / 2.4 * 2 * .pi))
        let wobble = 0.6
        let local = time.truncatingRemainder(dividingBy: idleTiltInterval)
        if local >= 0, local < wobble {
            let progress = local / wobble
            pose.angle = 5 * sin(progress * 2 * .pi * 2) * (1 - progress)
        }
        if idleGlow > 0 {
            pose.glow = idleGlow * CGFloat(0.7 + 0.3 * sin(time / 1.8 * 2 * .pi))
        }
        return pose
    }

    // MARK: - 蓄力

    /// 点开后礼盒蓄力（晃动）的时长；请求更快回来也等蓄力结束再揭晓。
    var chargeDuration: Double { pick(1.1, 1.6, 2.3) }

    /// 蓄力开始时晃动的幅度，单位为度。
    private var shakeStart: Double { pick(2, 2, 1.5) }

    /// 蓄力结束前晃动的幅度，单位为度。
    private var shakeEnd: Double { pick(12, 15, 17) }

    /// 蓄力期间一共晃几个来回；越到后面越快。
    private var shakeCycles: Double { pick(5.5, 9.5, 14) }

    /// 盒盖被顶起的最大幅度；周礼包盒盖不动。
    private var lidRattle: CGFloat { pick(0, 0.05, 0.08) }

    /// 蓄力期间盒盖被顶起几次。
    private var rattleCount: Double { pick(0, 7, 11) }

    /// 蓄力结束时盒缝透出的光；周礼包不透光。
    var chargeGlow: CGFloat { pick(0, 0.75, 1) }

    /// 盒缝射出的光束条数；周礼包没有。
    var beamCount: Int { pick(0, 3, 5) }

    /// 蓄力后段礼盒离地悬起的高度；只有年度礼包会悬起。
    private var levitation: CGFloat { pick(0, 0, 18) }

    /// 请求比蓄力慢时，礼盒原地颤动的幅度，单位为度；周礼包停住不动。
    private var holdTremble: Double { pick(0, 1.5, 2.5) }

    /// 蓄力的最后这一段晃动归零、礼盒落回原地，像屏住一口气再开盖。
    private static let settlePortion = 0.1

    /// 蓄力期间某一刻的姿态：由轻到重、越来越快地晃，盒盖一下下被顶起，盒缝的光越来越亮，年度礼包在后段离地悬起；
    /// 最后一小段晃动归零、礼盒落回原地。蓄力结束后请求还没回来时转为原地颤动，见 `holdPose(elapsed:)`。
    ///
    /// - Parameter elapsed: 从点开起算的秒数。
    func chargePose(elapsed: Double) -> BoxPose {
        guard elapsed >= 0 else { return .rest }
        guard elapsed < chargeDuration else { return holdPose(elapsed: elapsed - chargeDuration) }

        let progress = elapsed / chargeDuration
        let settleStart = 1 - Self.settlePortion
        let settle = progress < settleStart ? 1 : (1 - progress) / Self.settlePortion
        var pose = BoxPose()

        let amplitude = shakeStart + (shakeEnd - shakeStart) * progress
        let cycles = shakeCycles * (0.75 * progress + 0.25 * progress * progress)
        pose.angle = amplitude * sin(2 * .pi * cycles) * settle

        if lidRattle > 0, progress > 0.35 {
            let bump = max(0, sin(2 * .pi * rattleCount * progress))
            let ramp = min(1, (progress - 0.35) / 0.2)
            pose.lidLift = lidRattle * CGFloat(pow(bump, 6) * ramp * settle)
        }

        if levitation > 0 {
            let rise = Self.smoothstep((progress - 0.45) / 0.35)
            // 最后一段加速落回，像砸在地上
            let drop = progress < settleStart ? 1 : 1 - pow((progress - settleStart) / Self.settlePortion, 2)
            pose.offsetY = -levitation * CGFloat(rise * drop)
        }

        pose.glow = idleGlow + (chargeGlow - idleGlow) * CGFloat(progress * progress)
        return pose
    }

    /// 蓄力结束、请求还没回来时的姿态：原地小幅快速颤动，盒缝的光保持在最亮附近明暗起伏；周礼包停住不动。
    ///
    /// - Parameter elapsed: 从蓄力结束起算的秒数。
    func holdPose(elapsed: Double) -> BoxPose {
        var pose = BoxPose()
        guard holdTremble > 0 else { return pose }
        let ramp = min(1, max(0, elapsed) / 0.2)
        pose.angle = holdTremble * ramp * sin(2 * .pi * 13 * elapsed)
        pose.glow = chargeGlow * CGFloat(0.85 + 0.15 * sin(2 * .pi * 2 * elapsed))
        pose.lidLift = lidRattle * 0.5 * CGFloat(pow(max(0, sin(2 * .pi * 3 * elapsed)), 6) * ramp)
        return pose
    }

    // MARK: - 开盖

    /// 开盖时整屏闪一下的最大不透明度；周礼包不闪。
    var flashPeak: Double { pick(0, 0.22, 0.36) }

    /// 开盖时从礼盒扩散出的冲击波圈数；周礼包没有。
    var shockwaveCount: Int { pick(0, 1, 2) }

    /// 开盖时画面震动的幅度，单位为点；周礼包不震。
    var screenShake: CGFloat { pick(0, 4, 10) }

    /// 开盖时盒身向下沉到多少（竖直缩放），越小越沉。
    var popSquash: CGFloat { pick(0.86, 0.82, 0.76) }

    /// 沉下后弹起到多高（竖直缩放）。
    var popStretch: CGFloat { pick(1.08, 1.12, 1.17) }

    /// 盒盖飞起时的回弹。
    var lidBounce: Double { pick(0.35, 0.42, 0.48) }

    /// 背后光芒的直径。
    var sunburstSize: CGFloat { pick(300, 340, 380) }

    /// 光芒的条数。
    var rayCount: Int { pick(14, 18, 22) }

    /// 光芒每秒转多少度。
    var raySpeed: Double { pick(12, 14, 16) }

    /// 是否在光芒里再叠一层反向旋转的短光芒；只有年度礼包有。
    var hasInnerRays: Bool { level == .epic }

    /// 光芒展开后的大小。
    var burstScale: CGFloat { pick(1.1, 1.12, 1.15) }

    /// 舞台中央喷出的彩纸。
    var stageConfetti: [CheckInConfettiEmitter] {
        switch level {
        case .light:
            [
                CheckInConfettiEmitter(
                    count: 40, speed: 300...560, lifetime: 1.9, gravity: 820, seed: 20_261_118
                ),
            ]
        case .grand:
            [
                CheckInConfettiEmitter(
                    spread: 1.3, count: 60, speed: 340...680, lifetime: 2.4,
                    gravity: 520, drag: 1, sway: 10, flutter: true, seed: 20_261_130
                ),
                CheckInConfettiEmitter(
                    spread: 0.75, count: 20, speed: 380...660, delay: 0.3...0.42, lifetime: 2.2,
                    gravity: 480, drag: 1.1, sway: 8, kind: .star, palette: .golden, seed: 20_261_131
                ),
            ]
        case .epic:
            [
                CheckInConfettiEmitter(
                    spread: 1.35, count: 72, speed: 380...720, lifetime: 2.8,
                    gravity: 480, drag: 1.2, sway: 12, flutter: true, seed: 20_261_365
                ),
                CheckInConfettiEmitter(
                    spread: 0.9, count: 28, speed: 420...760, delay: 0.25...0.4, lifetime: 2.6,
                    gravity: 440, drag: 1.2, sway: 10, kind: .star, palette: .golden, seed: 20_261_366
                ),
            ]
        }
    }

    /// 铺满整屏的彩纸：年度礼包两侧的礼炮和从顶上飘落的星星；周礼包、月礼包没有。
    var screenConfetti: [CheckInConfettiEmitter] {
        guard level == .epic else { return [] }
        return [
            // 左下角斜向右上
            CheckInConfettiEmitter(
                origin: CGPoint(x: 0, y: 1.02), direction: -.pi / 2 + 0.5, spread: 0.25,
                count: 40, speed: 1150...1550, delay: 0.18...0.3, lifetime: 3,
                gravity: 400, drag: 2, sway: 14, flutter: true, seed: 20_261_367
            ),
            // 右下角斜向左上
            CheckInConfettiEmitter(
                origin: CGPoint(x: 1, y: 1.02), direction: -.pi / 2 - 0.5, spread: 0.25,
                count: 40, speed: 1150...1550, delay: 0.18...0.3, lifetime: 3,
                gravity: 400, drag: 2, sway: 14, flutter: true, seed: 20_261_368
            ),
            // 从顶边各处慢慢飘落的星星
            CheckInConfettiEmitter(
                origin: CGPoint(x: 0.5, y: -0.03), originWidth: 1, direction: .pi / 2, spread: 0.3,
                count: 34, speed: 40...120, delay: 0.6...2.2, lifetime: 4.5,
                gravity: 260, drag: 1.6, sway: 18, kind: .star, palette: .golden, seed: 20_261_369
            ),
        ]
    }

    // MARK: - 数字

    /// 开盖后等多久数字开始滚动。
    var rollDelay: Double { pick(0.25, 0.35, 0.5) }

    /// 数字滚动的时长。
    var rollDuration: Double { pick(0.9, 1.4, 2) }

    /// 数字最多跳几下；点数比它少时每次加 1。
    var maxRollSteps: Int { pick(24, 32, 40) }

    /// 数字滚动的减速程度：1 为匀速；越大越是先快后慢，像老虎机停下前的那几格。
    private var rollEasing: Double { pick(1, 1.6, 2) }

    /// 点数的字号。
    var numberFontSize: CGFloat { pick(60, 68, 76) }

    /// 数字停下时放大多少；周礼包不放大。
    var landingPunch: CGFloat { pick(0, 0.2, 0.32) }

    /// 点数文字的光晕浓淡；周礼包没有。
    var numberGlow: Double { pick(0, 0.3, 0.45) }

    /// 数字停下时是否从数字后面扩散一圈光环；只有年度礼包有。
    var hasLandingRipple: Bool { level == .epic }

    /// 数字停下后是否盖一枚印章；只有年度礼包有。
    var hasSeal: Bool { level == .epic }

    /// 数字停下后多久盖章。
    var sealDelay: Double { 0.45 }

    /// 数字滚动时每一跳的时刻（从开始滚动起算），共 `steps` 个、严格递增，最后一个正好是 `rollDuration`。
    ///
    /// 每跳加的点数相同；档位越高，后面几跳间隔越长，数字慢慢停下。
    ///
    /// - Parameter steps: 跳动次数，至少为 1。
    func rollTimes(steps: Int) -> [Double] {
        let count = max(1, steps)
        return (1...count).map { step in
            rollDuration * pow(Double(step) / Double(count), rollEasing)
        }
    }

    /// 第 `step` 跳显示的点数：均匀地从 0 增加，最后一跳正好是获得的点数。
    ///
    /// - Parameters:
    ///   - points: 获得的点数。
    ///   - step: 第几跳，从 1 开始。
    ///   - steps: 一共跳几下。
    static func rolledValue(points: Int, step: Int, of steps: Int) -> Int {
        guard steps > 0, step < steps else { return points }
        return Int((Double(points) * Double(max(step, 0)) / Double(steps)).rounded())
    }

    /// 0 到 1 之间平滑过渡，超出范围时取端点。
    private static func smoothstep(_ value: Double) -> Double {
        let clamped = min(1, max(0, value))
        return clamped * clamped * (3 - 2 * clamped)
    }
}

/// 一路彩纸的喷法：从哪儿、朝哪儿、喷多少、飞多久，以及受重力和空气阻力的程度。
///
/// 每片的方向、速度、转速、大小和颜色由 `seed` 决定，重放时一模一样。
nonisolated struct CheckInConfettiEmitter: Equatable {
    /// 碎片的样子。
    nonisolated enum Kind: Equatable, Sendable {
        /// 长条纸片。
        case strip
        /// 圆点。
        case dot
        /// 五角星。
        case star
    }

    /// 配色。
    nonisolated enum Palette: Equatable, Sendable {
        /// 主色加几种节日色。
        case festive
        /// 主色加黄、橙，像金色的星。
        case golden
    }

    /// 喷出的位置，相对彩纸视图的大小，0 到 1；可以超出边界，例如从屏幕底边以下喷上来。
    var origin = CGPoint(x: 0.5, y: 0.45)

    /// 喷出位置沿水平方向随机散开的宽度，相对视图宽度；0 为从一点喷出，1 为整条边。
    var originWidth: CGFloat = 0

    /// 主方向，弧度；`-π/2` 为正上方，`π/2` 为正下方。
    var direction: Double = -.pi / 2

    /// 向主方向两侧各偏多少弧度。
    var spread: Double = 1.22

    /// 片数。
    var count: Int

    /// 初速度范围，pt/s。
    var speed: ClosedRange<Double>

    /// 每片在多久之后喷出，范围内随机；默认一起喷出。
    var delay: ClosedRange<Double> = 0...0

    /// 每片从喷出到消失的时长；最后 0.5 秒淡出。
    var lifetime: Double

    /// 重力加速度，pt/s²。
    var gravity: Double = 820

    /// 空气阻力系数，1/s；0 为不受阻力，越大越像纸片一样飘。
    var drag: Double = 0

    /// 左右飘摆的幅度，pt；0 为不飘。
    var sway: Double = 0

    /// 纸片是否翻转（忽宽忽窄），看上去像在空中翻面。
    var flutter = false

    /// 碎片的样子。
    var kind: Kind = .strip

    /// 配色。
    var palette: Palette = .festive

    /// 决定每片样子的种子。
    var seed: UInt64

    /// 这一路从开始到最后一片消失的时长。
    var totalDuration: Double {
        delay.upperBound + lifetime
    }
}

extension AICheckInGiftTier {
    /// 打开这档礼包的仪式分量。
    nonisolated var ceremony: CheckInGiftCeremony {
        CheckInGiftCeremony(tier: self)
    }
}
