import SwiftUI

// MARK: - 单条线的画面

/// 某个槽位在某一时刻的画面：点的位置、可见长度、颜色和书写进度。
nonisolated struct LineAvatarStrokeFrame: Equatable, Sendable {
    /// 线上的点（设计画布坐标）。
    var points: [CGPoint]
    /// 可见长度比例：1 为完整，0 为缩成一点看不见；以线的中点为中心伸缩。
    var presence: CGFloat
    /// 颜色混合比例：0 为墨色，1 为红色。
    var accentMix: CGFloat
    /// 书写进度：从起点写出的比例，只在 logo 书写阶段小于 1。
    var reveal: CGFloat

    /// 一条线完整显示时的画面。
    /// - Parameters:
    ///   - stroke: 取样后的线。
    ///   - points: 替换用的点（如对齐过方向和起点的点）；nil 时用线本身的点。
    init(stroke: LineAvatarStroke, points: [CGPoint]? = nil) {
        self.points = points ?? stroke.points
        presence = 1
        accentMix = stroke.tint == .accent ? 1 : 0
        reveal = 1
    }

    /// 一幅画面静止时各槽位的画面。
    static func resting(_ figure: LineAvatarFigure) -> [LineAvatarSlot: LineAvatarStrokeFrame] {
        figure.strokes.mapValues { LineAvatarStrokeFrame(stroke: $0) }
    }

    /// 按进度混合两帧。
    ///
    /// - Parameters:
    ///   - from: 起始帧。
    ///   - to: 目标帧。
    ///   - progress: 动画进度；可以超出 0...1，点的位置随之过冲产生回弹，比例类属性仍限制在 0...1。
    static func blend(_ from: Self, _ to: Self, progress: CGFloat) -> Self {
        var result = to
        if from.points.count == to.points.count {
            result.points = zip(from.points, to.points).map {
                LineAvatarGeometry.interpolate($0, $1, progress)
            }
        }
        let clamped = min(max(progress, 0), 1)
        result.presence = from.presence + (to.presence - from.presence) * clamped
        result.accentMix = from.accentMix + (to.accentMix - from.accentMix) * clamped
        result.reveal = from.reveal + (to.reveal - from.reveal) * clamped
        return result
    }

    /// 按可见长度和书写进度裁出要画的那一段。
    /// - Returns: 设计画布坐标下的路径；完全不可见时为 nil。
    func visiblePath() -> Path? {
        let presence = min(max(presence, 0), 1)
        let reveal = min(max(reveal, 0), 1)
        guard presence > 0.001, reveal > 0.001, points.count > 1 else { return nil }
        let path = LineAvatarGeometry.smoothPath(through: points)
        let start = (1 - presence) / 2
        let end = start + presence * reveal
        guard start > 0.0001 || end < 0.9999 else { return path }
        return path.trimmedPath(from: start, to: end)
    }
}

// MARK: - 过渡

/// 一个槽位从一帧到另一帧的过渡。
nonisolated struct LineAvatarTransition: Sendable {
    /// 过渡的节奏。
    nonisolated enum Timing: Sendable {
        /// 立即到位。
        case instant
        /// 带轻微回弹的弹簧，时长为秒。
        case spring(duration: TimeInterval)
        /// 按 logo 的书写节奏写出这个槽位对应的那一段。
        case logo(LineAvatarSlot)
    }

    /// 起始帧。
    var from: LineAvatarStrokeFrame
    /// 目标帧。
    var to: LineAvatarStrokeFrame
    /// 开始时间（`Date.timeIntervalSinceReferenceDate`），已包含错开的延迟。
    var startTime: TimeInterval
    /// 过渡节奏。
    var timing: Timing

    /// 结束时间。
    var endTime: TimeInterval {
        switch timing {
        case .instant: startTime
        case let .spring(duration): startTime + duration
        case .logo: startTime + LineAvatarLogo.drawDuration
        }
    }

    /// 某一时刻的画面；开始前停在起始帧，结束后停在目标帧。
    func frame(at time: TimeInterval) -> LineAvatarStrokeFrame {
        let elapsed = time - startTime
        switch timing {
        case .instant:
            return to
        case let .spring(duration):
            guard elapsed > 0 else { return from }
            guard elapsed < duration else { return to }
            return .blend(from, to, progress: LineAvatarSpring.progress(elapsed / duration))
        case let .logo(slot):
            var frame = to
            frame.reveal = LineAvatarLogo.reveal(of: slot, elapsed: elapsed)
            return frame
        }
    }
}

/// 归一化的欠阻尼弹簧：把 0...1 的时间进度映射成带轻微回弹的动画进度。
nonisolated enum LineAvatarSpring {
    /// 阻尼比；0.68 约有 5% 的过冲，线条落位时会轻轻弹一下。
    static let damping: CGFloat = 0.68
    /// 归一化固有频率；时间进度到 1 时残差约 0.1%，可以直接落到终点不留跳变。
    static let frequency: CGFloat = 10.5

    /// 时间进度 `x` 对应的动画进度。
    static func progress(_ x: CGFloat) -> CGFloat {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        let decay = damping * frequency
        let dampedFrequency = frequency * (1 - damping * damping).squareRoot()
        return 1 - exp(-decay * x) * (cos(dampedFrequency * x) + decay / dampedFrequency * sin(dampedFrequency * x))
    }
}

// MARK: - 动画时间线

/// 线条头像的动画时间线：记录每个槽位当前的过渡，按时间算出任意时刻的画面。
///
/// 不依赖 SwiftUI 的隐式动画，视图用 `TimelineView` 逐帧取 `frames(at:)` 绘制。
/// 新的变形可以在上一段途中开始，会从当下的画面接着变，不会跳。
nonisolated struct LineAvatarAnimator: Sendable {
    /// 每条线的变形时长（秒）。
    static let morphDuration: TimeInterval = 0.9
    /// 相邻槽位开始变形的时间差（秒），让线条依次动起来。
    static let morphStagger: TimeInterval = 0.035

    /// 每个槽位当前的过渡；没有的槽位不画。
    private var transitions: [LineAvatarSlot: LineAvatarTransition] = [:]

    /// 所有过渡都结束的时间；之后画面静止，可以停止逐帧刷新。
    private(set) var endTime: TimeInterval = 0

    /// 空白画面。
    init() {}

    /// 直接停在某幅画面上。
    init(resting figure: LineAvatarFigure) {
        jump(to: figure)
    }

    /// 某一时刻各槽位的画面。
    func frames(at time: TimeInterval) -> [LineAvatarSlot: LineAvatarStrokeFrame] {
        transitions.mapValues { $0.frame(at: time) }
    }

    /// 从头书写 yado logo，书写节奏见 `LineAvatarLogo`。
    mutating func startLogoDrawing(at time: TimeInterval) {
        transitions = LineAvatarLogo.figure.strokes.reduce(into: [LineAvatarSlot: LineAvatarTransition]()) { result, entry in
            let frame = LineAvatarStrokeFrame(stroke: entry.value)
            result[entry.key] = LineAvatarTransition(from: frame, to: frame, startTime: time, timing: .logo(entry.key))
        }
        endTime = time + LineAvatarLogo.drawDuration
    }

    /// 从当前画面变成另一幅画面。
    ///
    /// 同一槽位的线互相变形，变形前会对齐方向和起点；目标里没有的线缩成一点消失，
    /// 原本看不见的线直接在目标位置长出来。
    /// - Parameters:
    ///   - figure: 目标画面。
    ///   - time: 开始时间（`Date.timeIntervalSinceReferenceDate`）。
    ///   - duration: 每条线的变形时长。
    ///   - stagger: 相邻槽位开始的时间差。
    mutating func morph(
        to figure: LineAvatarFigure,
        at time: TimeInterval,
        duration: TimeInterval = LineAvatarAnimator.morphDuration,
        stagger: TimeInterval = LineAvatarAnimator.morphStagger
    ) {
        var next: [LineAvatarSlot: LineAvatarTransition] = [:]
        for slot in LineAvatarSlot.allCases {
            let current = transitions[slot]?.frame(at: time)
            let target = figure.strokes[slot]
            let from: LineAvatarStrokeFrame
            let to: LineAvatarStrokeFrame

            switch (current, target) {
            case (nil, nil):
                continue
            case let (nil, target?):
                to = LineAvatarStrokeFrame(stroke: target)
                var hidden = to
                hidden.presence = 0
                from = hidden
            case let (current?, nil):
                from = current
                var hidden = current
                hidden.presence = 0
                to = hidden
            case let (current?, target?):
                if current.presence < 0.01 || current.reveal < 0.01 {
                    // 原本看不见：直接挪到目标位置再长出来，免得从别处飞过来
                    var moved = current
                    moved.points = target.points
                    from = moved
                    to = LineAvatarStrokeFrame(stroke: target)
                } else {
                    from = current
                    let points = LineAvatarGeometry.aligned(target.points, isClosed: target.isClosed, to: current.points)
                    to = LineAvatarStrokeFrame(stroke: target, points: points)
                }
            }

            next[slot] = LineAvatarTransition(
                from: from,
                to: to,
                startTime: time + Double(slot.rawValue) * stagger,
                timing: .spring(duration: duration)
            )
        }
        transitions = next
        endTime = next.values.map(\.endTime).max() ?? time
    }

    /// 立即换成另一幅画面，没有动画；用于「减少动态效果」。
    mutating func jump(to figure: LineAvatarFigure) {
        transitions = figure.strokes.mapValues { stroke in
            let frame = LineAvatarStrokeFrame(stroke: stroke)
            return LineAvatarTransition(from: frame, to: frame, startTime: 0, timing: .instant)
        }
        endTime = 0
    }
}

// MARK: - 换一换的出牌顺序

/// 「换一换」的出牌顺序：每轮把头像洗一次，一轮内不重复，也不会连着出现同一个。
nonisolated struct LineAvatarDeck: Sendable {
    /// 参与洗牌的头像 ID。
    private let ids: [String]
    /// 本轮还没出的 ID，从末尾往前出。
    private var remaining: [String] = []

    init(ids: [String] = LineAvatarCatalog.presets.map(\.id)) {
        self.ids = ids
    }

    /// 取下一个头像 ID。
    /// - Parameters:
    ///   - current: 当前显示的头像 ID，不会被立刻再选中。
    ///   - generator: 随机数来源，测试时可固定。
    /// - Returns: 下一个 ID；只有一个头像时返回它本身，没有头像时为 nil。
    mutating func next<Generator: RandomNumberGenerator>(after current: String?, using generator: inout Generator) -> String? {
        guard !ids.isEmpty else { return nil }
        remaining.removeAll { $0 == current }
        if remaining.isEmpty {
            remaining = ids.filter { $0 != current }.shuffled(using: &generator)
        }
        return remaining.popLast() ?? current
    }

    /// 用系统随机数取下一个头像 ID。
    mutating func next(after current: String?) -> String? {
        var generator = SystemRandomNumberGenerator()
        return next(after: current, using: &generator)
    }
}
