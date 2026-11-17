import SwiftUI

/// 选择线条头像：先写出 yado logo，再由这几笔变成一个预制头像，用户可以「换一换」或「就这个」。
///
/// 动画由 `LineAvatarAnimator` 按时间计算，`TimelineView` 只在线条动的时候逐帧刷新。
/// 打开「减少动态效果」时跳过书写和变形，直接显示头像，切换时淡入淡出。
/// 选定后只回调，不负责保存和关闭页面。
struct LineAvatarPickerView: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 点「就这个」时回调选中的头像。
    let onConfirm: (LineAvatarPreset) -> Void

    /// 动画时间线。
    @State private var animator = LineAvatarAnimator()
    /// 当前显示（或正在变成）的头像；logo 书写阶段为 nil。
    @State private var current: LineAvatarPreset?
    /// 换一换的出牌顺序。
    @State private var deck = LineAvatarDeck()
    /// 是否需要逐帧刷新；动画结束后关掉，避免空转耗电。
    @State private var isAnimating = false
    /// 开场动画是否已开始，避免页面重新出现时重播。
    @State private var hasStarted = false
    /// 等动画结束后停止刷新的任务；新动画开始时取消重排。
    @State private var settleTask: Task<Void, Never>?

    /// 画布直径。
    private static let canvasSize: CGFloat = 240
    /// logo 写完后停顿多久再变成头像。
    private static let logoHold: Duration = .milliseconds(350)

    var body: some View {
        VStack(spacing: 0) {
            Text(text("lineAvatar.picker.title"))
                .font(.system(.title3, design: .serif, weight: .semibold))
                .padding(.top, 36)

            Spacer(minLength: 24)

            canvas

            Text(current.map { text($0.nameKey) } ?? " ")
                .font(.headline)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: current?.id)
                .padding(.top, 20)
                .accessibilityHidden(true)

            Spacer(minLength: 24)

            actions
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(.paperBackground))
        .appHaptic(.selection, trigger: current?.id)
        .task { await start() }
        .onDisappear { settleTask?.cancel() }
    }

    // MARK: - 子视图

    /// 头像画布；静止时按终态绘制，不再逐帧刷新。
    private var canvas: some View {
        TimelineView(.animation(paused: !isAnimating)) { context in
            let time = isAnimating ? context.date.timeIntervalSinceReferenceDate : .greatestFiniteMagnitude
            LineAvatarCanvas(frames: animator.frames(at: time))
        }
        .frame(width: Self.canvasSize, height: Self.canvasSize)
        .background(LineAvatarBackground())
        // 减少动态效果时整张画布按头像淡入淡出；平时 id 不变，靠线条变形过渡
        .id(reduceMotion ? current?.id : nil)
        .transition(.opacity)
        .accessibilityElement()
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel(current.map { text($0.nameKey) } ?? text("lineAvatar.picker.drawing"))
    }

    /// 换一换、就这个、取消。
    private var actions: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button(action: shuffle) {
                    Label(text("lineAvatar.picker.shuffle"), systemImage: "arrow.triangle.2.circlepath")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                        .contentShape(Capsule())
                }
                .accessibilityIdentifier("line-avatar-shuffle")

                Button(action: confirm) {
                    Text(text("lineAvatar.picker.confirm"))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Capsule().fill(Color.primary))
                        .contentShape(Capsule())
                }
                .accessibilityIdentifier("line-avatar-confirm")
            }
            .buttonStyle(.plain)
            .disabled(current == nil)
            .opacity(current == nil ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.2), value: current == nil)

            Button(text("common.cancel")) {
                dismiss()
            }
            .font(.body.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("line-avatar-cancel")
        }
    }

    // MARK: - 动画流程

    /// 开场：写出 logo，停顿片刻后变成第一个头像。
    private func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        guard let first = deck.next(after: nil).flatMap(LineAvatarCatalog.preset(id:)) else { return }

        if reduceMotion {
            animator.jump(to: first.figure)
            current = first
            return
        }

        animator.startLogoDrawing(at: Self.now)
        runClock()
        try? await Task.sleep(for: .seconds(LineAvatarLogo.drawDuration) + Self.logoHold)
        guard !Task.isCancelled, current == nil else { return }
        show(first)
    }

    /// 点「换一换」：换成下一个头像，线条从当前画面接着变。
    private func shuffle() {
        guard let next = deck.next(after: current?.id).flatMap(LineAvatarCatalog.preset(id:)) else { return }
        show(next)
    }

    /// 点「就这个」。
    private func confirm() {
        guard let current else { return }
        onConfirm(current)
    }

    /// 变成指定头像。
    private func show(_ preset: LineAvatarPreset) {
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.25)) {
                animator.jump(to: preset.figure)
                current = preset
            }
            return
        }
        current = preset
        animator.morph(to: preset.figure, at: Self.now)
        runClock()
    }

    /// 开始逐帧刷新，到动画结束时自动停止。
    private func runClock() {
        settleTask?.cancel()
        isAnimating = true
        let remaining = max(animator.endTime - Self.now, 0)
        settleTask = Task {
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            isAnimating = false
        }
    }

    /// 动画时间基准，与 `TimelineView` 的时间同源。
    private static var now: TimeInterval {
        Date.now.timeIntervalSinceReferenceDate
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            LineAvatarPickerView { _ in }
        }
}
