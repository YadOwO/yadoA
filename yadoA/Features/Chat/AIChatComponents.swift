import SwiftUI

// MARK: - 顶部状态胶囊

/// 顶部的状态胶囊：红豆加一句状态，宽度随文字弹性变化；空闲时显示今日支出，账记上时数字跟着滚动。
struct AIChatStatusPill: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 当前状态。
    let status: AIChatStatus

    /// 要显示的文字。
    let text: String

    /// 提供音量，说话时红豆跟着声音跳。
    let recognizer: any VoiceSpeechRecognizing

    /// 每加 1，红豆泛开一圈，表示这一轮结束。
    let completionPulse: Int

    var body: some View {
        HStack(spacing: 9) {
            AIChatBean(status: status, recognizer: recognizer, completionPulse: completionPulse)
            Text(text)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(reduceMotion ? .identity : .numericText())
        }
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .frame(height: 40)
        .voiceFloatingSurface(in: Capsule())
        .animation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.25), value: text)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("voice-chat-status")
    }
}

/// 胶囊里的红豆：空闲时呼吸，处理中上下跳，说话时跟着音量变大变小。
private struct AIChatBean: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 当前状态。
    let status: AIChatStatus

    /// 提供音量。
    let recognizer: any VoiceSpeechRecognizing

    /// 每加 1，泛开一圈。
    let completionPulse: Int

    /// 红豆的边长。
    private static let size: CGFloat = 12

    var body: some View {
        bean
            .frame(width: Self.size, height: Self.size)
            .overlay {
                // 只在这一刻短暂出现，其余时间透明
                Circle()
                    .stroke(Color(.ledgerRed), lineWidth: 1.5)
                    .keyframeAnimator(initialValue: AIChatRing(), trigger: completionPulse) { content, ring in
                        content
                            .scaleEffect(ring.scale)
                            .opacity(ring.opacity)
                    } keyframes: { _ in
                        KeyframeTrack(\.scale) {
                            MoveKeyframe(1)
                            CubicKeyframe(2.4, duration: 0.9)
                        }
                        KeyframeTrack(\.opacity) {
                            MoveKeyframe(0.55)
                            CubicKeyframe(0, duration: 0.9)
                        }
                    }
                    .accessibilityHidden(true)
            }
            .accessibilityHidden(true)
    }

    /// 按状态选动作；开启“减弱动态效果”时是一个静止的圆点。
    @ViewBuilder
    private var bean: some View {
        let circle = Circle().fill(Color(.ledgerRed))
        if reduceMotion {
            circle
        } else {
            switch status {
            case .today:
                circle.phaseAnimator([CGFloat(1), 0.82]) { content, scale in
                    content.scaleEffect(scale)
                } animation: { _ in
                    .easeInOut(duration: 1.6)
                }
            case .listening:
                AIChatListeningBean(recognizer: recognizer)
            case .thinking, .readingImage, .searching, .writing:
                circle.phaseAnimator([false, true]) { content, isUp in
                    content
                        .scaleEffect(x: isUp ? 0.93 : 1.12, y: isUp ? 1.06 : 0.86)
                        .offset(y: isUp ? -5 : 4)
                } animation: { _ in
                    .easeInOut(duration: 0.31)
                }
            }
        }
    }
}

/// 红豆泛开一圈时的动画值。
private struct AIChatRing {
    /// 放大倍数。
    var scale: CGFloat = 1

    /// 透明度；不播放时为 0。
    var opacity: Double = 0
}

/// 说话时的红豆；单独成一个视图，音量每秒变化几十次，只重绘这一小块。
private struct AIChatListeningBean: View {
    /// 提供音量。
    let recognizer: any VoiceSpeechRecognizing

    var body: some View {
        Circle()
            .fill(Color(.ledgerRed))
            .scaleEffect(1 + CGFloat(recognizer.audioLevel) * 0.5)
            .animation(.easeOut(duration: 0.08), value: recognizer.audioLevel)
    }
}

// MARK: - 处理中

/// 处理中的提示：一笔墨线上滚动的红豆，旁边一句当前在做什么。
struct AIChatThinkingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 当前在做什么。
    let text: String

    /// 走完一程的时长。
    private static let period: TimeInterval = 1.5

    var body: some View {
        HStack(spacing: 10) {
            TimelineView(.animation(paused: reduceMotion)) { timeline in
                Canvas { context, size in
                    let progress = reduceMotion ? 1 : Self.progress(at: timeline.date)
                    let path = Self.inkLine(in: CGRect(origin: .zero, size: size))
                    let drawn = path.trimmedPath(from: 0, to: progress)
                    context.stroke(
                        drawn,
                        with: .color(.secondary),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                    if let point = drawn.currentPoint {
                        let bean = CGRect(x: point.x - 4.5, y: point.y - 4.5, width: 9, height: 9)
                        context.fill(Path(ellipseIn: bean), with: .color(Color(.ledgerRed)))
                    }
                }
            }
            .frame(width: 96, height: 26)
            .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.2), value: text)
        }
        .accessibilityElement(children: .combine)
    }

    /// 这一刻墨线写到哪里：来回走，两端放慢。
    private static func progress(at date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period * 2) / period
        let linear = phase <= 1 ? phase : 2 - phase
        return max(0.02, linear * linear * (3 - 2 * linear))
    }

    /// 手写感的一笔波浪线。
    private static func inkLine(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x / 96, y: rect.minY + rect.height * y / 26)
        }
        var path = Path()
        path.move(to: point(2, 15))
        path.addCurve(to: point(44, 13), control1: point(16, 5), control2: point(26, 23))
        path.addCurve(to: point(94, 15), control1: point(62, 3), control2: point(74, 7))
        return path
    }
}

// MARK: - 气泡

/// 用户发出的一句话：墨色实心气泡，靠右。
struct AIChatUserBubble: View {
    /// 气泡文字。
    let text: String

    /// 这一轮是否已撤销。
    var isUndone = false

    var body: some View {
        Text(text)
            .font(.body)
            .strikethrough(isUndone)
            .foregroundStyle(Color(.onAccent))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Color.accentColor.opacity(isUndone ? 0.45 : 1),
                in: UnevenRoundedRectangle(
                    topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 6, topTrailingRadius: 20,
                    style: .continuous
                )
            )
            .padding(.leading, 48)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// 正在说的这句话：虚线气泡，转写文字直接长在对话里；上滑取消时变红。
struct AIChatLiveBubble: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 截至目前的转写文字。
    let transcript: String

    /// 是否已上滑到取消区域。
    let isCancelArmed: Bool

    var body: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 6, topTrailingRadius: 20,
            style: .continuous
        )
        Text(transcript.isEmpty ? AccountLocalization.string("voice.recording.listening", locale: locale) : transcript)
            .font(.body)
            .foregroundStyle(isCancelArmed ? Color(.ledgerRed) : Color.secondary)
            .contentTransition(reduceMotion ? .identity : .opacity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: transcript)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .overlay {
                shape.stroke(
                    isCancelArmed ? Color(.ledgerRed) : Color.secondary.opacity(0.5),
                    style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])
                )
            }
            .padding(.leading, 48)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityIdentifier("voice-transcript")
    }
}

// MARK: - 回复文字

/// 把文字一个字一个字淡入：响应是一次性回来的，这里只是展示节奏，不假装在生成。
private struct AIChatTextReveal: TextRenderer {
    /// 淡入进度，0～1。
    var progress: Double

    /// 同时在淡入的字数，越大过渡越柔和。
    private static let softness = 8.0

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let slices = layout.flatMap { line in line.flatMap { run in Array(run) } }
        let reach = progress * (Double(slices.count) + Self.softness)
        for (index, slice) in slices.enumerated() {
            var copy = context
            copy.opacity = min(1, max(0, (reach - Double(index)) / Self.softness))
            copy.draw(slice)
        }
    }
}

/// 一段回复：新的一轮逐字淡入，历史记录直接显示。
struct AIChatRevealText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 回复文字。
    let text: String

    /// 是否播放淡入。
    let animates: Bool

    /// 淡入结束。
    let onFinished: () -> Void

    /// 淡入进度。
    @State private var progress = 0.0

    var body: some View {
        Text(text)
            .textRenderer(AIChatTextReveal(progress: animates ? progress : 1))
            .task(id: animates) {
                guard animates else { return }
                guard !reduceMotion else {
                    progress = 1
                    onFinished()
                    return
                }
                let duration = min(0.9, Double(text.count) * 0.014 + 0.15)
                withAnimation(.linear(duration: duration)) {
                    progress = 1
                }
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }
                onFinished()
            }
    }
}

// MARK: - 手写笔迹

/// 手写感的一道横线，撤销时用来划掉一行。
struct AIChatHandStrike: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.65))
        path.addCurve(
            to: CGPoint(x: rect.minX + rect.width * 0.6, y: rect.minY + rect.height * 0.4),
            control1: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.minY + rect.height * 0.15),
            control2: CGPoint(x: rect.minX + rect.width * 0.4, y: rect.minY + rect.height * 0.9)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.35),
            control1: CGPoint(x: rect.minX + rect.width * 0.75, y: rect.minY + rect.height * 0.15),
            control2: CGPoint(x: rect.minX + rect.width * 0.9, y: rect.minY + rect.height * 0.65)
        )
        return path
    }
}

// MARK: - 声波

/// 按住说话时输入栏里的声波：真实音量从右往左滚动。
struct AIChatWaveform: View {
    /// 提供音量。
    let recognizer: any VoiceSpeechRecognizing

    /// 最近的音量，旧的在前。
    @State private var samples = [CGFloat](repeating: 0, count: 48)

    /// 一根声波的宽度。
    private static let barWidth: CGFloat = 3

    /// 声波之间的间距。
    private static let barSpacing: CGFloat = 2.5

    var body: some View {
        Canvas { context, size in
            let count = min(samples.count, Int(size.width / (Self.barWidth + Self.barSpacing)))
            for (index, sample) in samples.suffix(count).enumerated() {
                let height = max(4, sample * size.height)
                let bar = CGRect(
                    x: CGFloat(index) * (Self.barWidth + Self.barSpacing),
                    y: (size.height - height) / 2,
                    width: Self.barWidth,
                    height: height
                )
                context.fill(
                    Path(roundedRect: bar, cornerRadius: Self.barWidth / 2),
                    with: .color(Color(.onAccent))
                )
            }
        }
        .frame(height: 30)
        .onChange(of: recognizer.audioLevel) { _, level in
            samples.removeFirst()
            samples.append(CGFloat(level))
        }
        .accessibilityHidden(true)
    }
}
