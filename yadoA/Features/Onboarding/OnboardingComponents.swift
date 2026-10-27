import SwiftUI

// MARK: - 墨水写字

/// 逐字写出的墨水：每个字从模糊、偏下的淡墨渐渐落定，前一个字还没干透下一个字就开始写。
nonisolated struct OnboardingInkRenderer: TextRenderer {
    /// 整行的书写进度，0 为一个字都没写，1 为全部写完。
    var progress: Double

    /// 同时处在“未干”状态的字数，越大笔迹越连贯。
    private let overlap: Double = 3

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let slices = layout.flatMap { line in line.flatMap { run in run } }
        let count = Double(max(slices.count, 1))
        for (index, slice) in slices.enumerated() {
            // 第 index 个字在 [start, start + overlap] 字长的区间里从无到有
            let local = min(max((progress * (count + overlap) - Double(index)) / overlap, 0), 1)
            guard local > 0 else { continue }
            var copy = context
            copy.opacity = local
            if local < 1 {
                copy.addFilter(.blur(radius: (1 - local) * 2.4))
                copy.translateBy(x: 0, y: (1 - local) * 3)
            }
            copy.draw(slice)
        }
    }
}

/// 用墨水一字一字写出来的一行文字，写的同时有一层很轻的笔尖纹理。
///
/// 同一段文字只写一次；文字变了才重新写。开启“减弱动态效果”时直接显示写好的样子。
struct OnboardingInkText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 要写的文字。
    let text: String

    /// 字体。
    var font: Font = .system(size: 26, weight: .regular, design: .serif)

    /// 出现后等多久开始写，单位为秒。
    var delay: Double = 0

    /// 笔尖纹理；为空时不震。
    var haptics: OnboardingHaptics?

    /// 写完时调用。
    var onWritten: (() -> Void)?

    /// 书写进度。
    @State private var progress: Double = 0

    /// 已经写过的文字，避免视图重新出现时又写一遍。
    @State private var writtenText: String?

    var body: some View {
        Text(text)
            .font(font)
            .fixedSize(horizontal: false, vertical: true)
            .textRenderer(OnboardingInkRenderer(progress: progress))
            .task(id: text) {
                await write()
            }
    }

    /// 一行字的书写时长：每个字 0.05 秒，太短太长都收住。
    ///
    /// - Parameter text: 要写的文字。
    static func duration(for text: String) -> Double {
        min(max(Double(text.count) * 0.05, 0.35), 1.6)
    }

    /// 等待、写字、通知写完。
    private func write() async {
        guard writtenText != text else { return }
        if reduceMotion {
            progress = 1
            writtenText = text
            onWritten?()
            return
        }
        progress = 0
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled else { return }
        let duration = Self.duration(for: text)
        haptics?.pen(duration: duration)
        withAnimation(.linear(duration: duration)) {
            progress = 1
        }
        writtenText = text
        try? await Task.sleep(for: .seconds(duration))
        guard !Task.isCancelled else { return }
        onWritten?()
    }
}

// MARK: - 豆子

/// 豆子要停的位置：某一行里的一处小空位，豆子全程是同一个视图，从一处滚到下一处。
nonisolated struct OnboardingBeanSlot {
    /// 停放位置，在引导根视图里解析为具体坐标。
    let anchor: Anchor<CGRect>

    /// 多处同时标出位置时取优先级高的；顶部横线上的默认停放位置为 0。
    let priority: Int

    /// 豆子是否显示；落地前藏在纸外，交给别的视图画时隐藏。
    let isVisible: Bool

    /// 豆子是否紧跟这个位置逐帧移动、不走弹簧；按住种下时豆子跟着芽尖往上走。
    let isTracking: Bool
}

/// 收集当前要停放豆子的位置。
nonisolated struct OnboardingBeanSlotKey: PreferenceKey {
    static var defaultValue: OnboardingBeanSlot? { nil }

    static func reduce(value: inout OnboardingBeanSlot?, nextValue: () -> OnboardingBeanSlot?) {
        guard let next = nextValue() else { return }
        if let current = value, current.priority > next.priority { return }
        value = next
    }
}

extension View {
    /// 把这个视图的位置标为豆子的停放处；豆子会以弹簧落过来，大小跟着变成这个视图的大小。
    ///
    /// - Parameters:
    ///   - priority: 优先级，步骤里的位置用默认的 1，盖过顶部横线上的停放位置。
    ///   - isActive: 为 false 时不标记。
    ///   - isVisible: 豆子停在这里时是否显示。
    ///   - isTracking: 为 true 时豆子逐帧紧跟这个位置，不走弹簧。
    func onboardingBeanSlot(
        priority: Int = 1,
        isActive: Bool = true,
        isVisible: Bool = true,
        isTracking: Bool = false
    ) -> some View {
        anchorPreference(key: OnboardingBeanSlotKey.self, value: .bounds) { anchor in
            isActive
                ? OnboardingBeanSlot(anchor: anchor, priority: priority, isVisible: isVisible, isTracking: isTracking)
                : nil
        }
    }
}

/// 贯穿引导的那颗账本红的豆子：位置和大小变化都用同一个弹簧，落定时压扁一下再弹回。
struct OnboardingBean: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 豆子当前的位置与大小，坐标在引导根视图中。
    let frame: CGRect

    /// 是否显示。
    let isVisible: Bool

    /// 每加 1 压扁一下，对应一次落定。
    let squashCount: Int

    /// 是否逐帧紧跟位置；为 true 时位置变化不走弹簧。
    var isTracking = false

    var body: some View {
        let diameter = min(frame.width, frame.height)
        let isStill = reduceMotion
        Circle()
            .fill(Color(.ledgerRed))
            .frame(width: diameter, height: diameter)
            .keyframeAnimator(initialValue: CGSize(width: 1, height: 1), trigger: squashCount) { content, scale in
                content.scaleEffect(isStill ? CGSize(width: 1, height: 1) : scale, anchor: .bottom)
            } keyframes: { _ in
                SpringKeyframe(CGSize(width: 1.28, height: 0.74), duration: 0.08)
                SpringKeyframe(CGSize(width: 0.92, height: 1.1), duration: 0.14)
                SpringKeyframe(CGSize(width: 1, height: 1), duration: 0.4, spring: .bouncy)
            }
            .opacity(isVisible ? 1 : 0)
            .position(x: frame.midX, y: frame.midY)
            .animation(isTracking ? nil : reduceMotion ? .easeInOut(duration: 0.25) : Self.travel, value: frame)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// 豆子从一处落到另一处的弹簧，回弹明显，像真的豆子落在纸上。
    static let travel = Animation.spring(duration: 0.7, bounce: 0.38)

    /// 弹簧开始到豆子第一次到位的大致时刻，落定的触感和压扁放在这里。
    static let landingDelay: Duration = .milliseconds(330)
}

// MARK: - 按钮

/// 引导的主按钮：iOS 26 是墨色的液态玻璃胶囊，更早的系统是墨色实底胶囊；按下时柔和地震一下。
struct OnboardingPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .onAccentForeground()
            .frame(maxWidth: .infinity, minHeight: 52)
            .modifier(OnboardingPrimarySurface())
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
            .appHaptic(.press, trigger: configuration.isPressed) { _, pressed in pressed }
            .contentShape(Capsule())
    }
}

/// 主按钮的底：iOS 26 用墨色着色的交互玻璃，iOS 18 用墨色实底加一点投影。
private struct OnboardingPrimarySurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular.tint(Color.accentColor).interactive(), in: Capsule())
        } else {
            content
                .background(Capsule().fill(Color.accentColor))
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        }
    }
}

/// 并列的选项按钮：手画的圆角框，选中时框里铺一层淡墨、边框加重。几个选项同样醒目，不预先选中任何一个。
struct OnboardingChoiceButtonStyle: ButtonStyle {
    /// 是否选中。
    var isSelected = false

    /// 笔迹种子，让并排的几个框各不相同。
    var seed: UInt64 = 0

    /// 是否撑满一行；放在流式布局里的小选项传 false。
    var fillsWidth = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(Color.primary)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: fillsWidth ? 52 : 44)
            .padding(.horizontal, 12)
            .background {
                HandDrawnBox(cornerRadius: 18, seed: seed)
                    .fill(Color.accentColor.opacity(isSelected ? 0.1 : 0))
                HandDrawnBox(cornerRadius: 18, seed: seed)
                    .stroke(
                        Color.primary.opacity(isSelected ? 0.9 : 0.45),
                        style: StrokeStyle(lineWidth: isSelected ? 1.8 : 1.3, lineCap: .round, lineJoin: .round)
                    )
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.2), value: isSelected)
            .contentShape(Rectangle())
    }
}

// MARK: - 版式

/// 引导一行的版式：上面是可滚动的内容，按钮固定在底部。
struct OnboardingPage<Content: View, Actions: View>: View {
    /// 这一行的内容。
    @ViewBuilder let content: () -> Content

    /// 底部按钮。
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)

            VStack(spacing: 10) {
                actions()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
    }
}

/// 出现时淡入并上浮到位；用于跟在墨水标题后面出现的说明和按钮。
struct OnboardingReveal: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 是否已出现。
    let isVisible: Bool

    /// 相对 `isVisible` 变为 true 的延迟，单位为秒。
    var delay: Double = 0

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible || reduceMotion ? 0 : 14)
            .animation(.spring(duration: 0.55, bounce: 0.18).delay(reduceMotion ? 0 : delay), value: isVisible)
    }
}

extension View {
    /// 出现时淡入并上浮到位。
    ///
    /// - Parameters:
    ///   - isVisible: 是否已出现。
    ///   - delay: 延迟，单位为秒。
    func onboardingReveal(_ isVisible: Bool, delay: Double = 0) -> some View {
        modifier(OnboardingReveal(isVisible: isVisible, delay: delay))
    }
}

/// 示例数据的小标签，提醒用户这里不是自己的账。
struct OnboardingSampleBadge: View {
    @Environment(\.locale) private var locale

    var body: some View {
        Text(AccountLocalization.string("onboarding.sample.badge", locale: locale))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .overlay {
                HandDrawnBox(cornerRadius: 6, seed: 3)
                    .stroke(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            }
    }
}
