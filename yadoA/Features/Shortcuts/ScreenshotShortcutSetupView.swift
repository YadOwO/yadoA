import SwiftUI

/// 截图记账引导页：用一张示意图和三步卡片说明如何添加快捷指令并绑定轻点背面。
struct ScreenshotShortcutSetupView: View {
    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL
    @State private var cannotOpenShortcuts = false

    /// 系统设置中到达「轻点两下」的逐级路径，按顺序展示为面包屑。
    private static let backTapPathKeys = [
        "shortcut.screenshot.setup.path.settings",
        "shortcut.screenshot.setup.path.accessibility",
        "shortcut.screenshot.setup.path.touch",
        "shortcut.screenshot.setup.path.back_tap",
        "shortcut.screenshot.setup.path.double_tap"
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                hero
                steps
                privacyNote

                #if DEBUG
                if ScreenshotShortcutUITestFixture.isEnabled {
                    Button("UITest screenshot") {
                        Task { await ScreenshotShortcutUITestFixture.invoke() }
                    }
                    .accessibilityIdentifier("screenshot-shortcut-test-invoke")
                }
                #endif
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(text("shortcut.screenshot.title"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(text("shortcut.screenshot.setup.open_failed"), isPresented: $cannotOpenShortcuts) {
            Button(text("common.done"), role: .cancel) { }
        }
    }

    // MARK: - 头图

    /// 一句话说明功能价值，配合示意图让用户不读步骤也能理解效果。
    private var hero: some View {
        VStack(spacing: 18) {
            ScreenshotShortcutIllustration()

            VStack(spacing: 6) {
                Text(text("shortcut.screenshot.setup.hero.title"))
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(text("shortcut.screenshot.setup.hero.subtitle"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // MARK: - 步骤

    /// 三步放在同一张卡片内，用左侧序号和连线表达先后顺序。
    private var steps: some View {
        VStack(spacing: 0) {
            ScreenshotShortcutStep(
                number: 1,
                title: text("shortcut.screenshot.setup.create"),
                detail: text("shortcut.screenshot.setup.create.detail")
            ) {
                addShortcutButton
            }

            ScreenshotShortcutStep(
                number: 2,
                title: text("shortcut.screenshot.setup.back_tap"),
                detail: text("shortcut.screenshot.setup.back_tap.detail")
            ) {
                backTapPath
            }

            ScreenshotShortcutStep(
                number: 3,
                title: text("shortcut.screenshot.setup.use"),
                detail: text("shortcut.screenshot.setup.use.detail"),
                isLast: true
            ) {
                Label(text("shortcut.screenshot.setup.use.note"), systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
    }

    /// 打开已发布的预设模板；新系统显示玻璃效果，iOS 18 保留原生实色按钮。
    @ViewBuilder
    private var addShortcutButton: some View {
        let button = Button {
            openURL(ScreenshotShortcutTemplate.url) { accepted in
                cannotOpenShortcuts = !accepted
            }
        } label: {
            Label(text("shortcut.screenshot.setup.open"), systemImage: "plus.circle.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .controlSize(.large)
        .accessibilityIdentifier("screenshot-shortcut-create")

        if #available(iOS 26, *) {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }

    /// 系统设置路径的面包屑；空间不足时自动换行，朗读时合并为一句。
    private var backTapPath: some View {
        let names = Self.backTapPathKeys.map(text)
        return ScreenshotShortcutFlowLayout(spacing: 6) {
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                HStack(spacing: 6) {
                    Text(name)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(uiColor: .tertiarySystemFill), in: .capsule)
                    if index < names.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(names.formatted(.list(type: .and, width: .narrow).locale(locale)))
    }

    // MARK: - 隐私

    /// 截图涉及支付信息，在页面底部用一句话交代图片去向。
    private var privacyNote: some View {
        Label(text("shortcut.screenshot.privacy"), systemImage: "lock.fill")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
    }

    /// 说明文案与快捷指令动作名称使用同一份原生本地化资源。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 引导页的单个步骤：左侧序号与连线，右侧标题、一句说明和该步骤的操作或提示。
private struct ScreenshotShortcutStep<Accessory: View>: View {
    /// 步骤序号，从 1 开始。
    let number: Int
    /// 步骤标题，保持为一个短语。
    let title: String
    /// 步骤说明，保持为一句话。
    let detail: String
    /// 最后一步不再绘制向下的连线和底部间距。
    var isLast = false
    /// 该步骤的操作按钮或补充提示。
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 6) {
                Text(number, format: .number)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor, in: .circle)
                    .accessibilityHidden(true)
                if !isLast {
                    Capsule()
                        .fill(Color(uiColor: .separator))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                accessory
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 3)
            .padding(.bottom, isLast ? 0 : 24)
        }
    }
}

/// 头部示意图：轻点手机背面后，截图进入 yadoA 的记账表单。
///
/// 全部用系统语义色绘制且不含文字，因此无需为语言和深浅色分别准备图片。
private struct ScreenshotShortcutIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 驱动轻点涟漪的循环动画；开启「减弱动态效果」时保持静止。
    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 16) {
            phoneBack
            Image(systemName: "arrow.right")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.tertiary)
            phoneFront
        }
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 28))
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                isPulsing = true
            }
        }
    }

    /// 手机背面：左上角摄像头模组，中部为轻点位置和两圈涟漪（对应轻点两下）。
    private var phoneBack: some View {
        phoneBody(fill: Color(uiColor: .secondarySystemGroupedBackground)) {
            ZStack {
                ripple(delay: 0)
                ripple(delay: 0.3)
                Image(systemName: "hand.tap.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .frame(width: 30, height: 30)
                    .overlay {
                        Circle()
                            .fill(Color(uiColor: .systemFill))
                            .frame(width: 14, height: 14)
                    }
                    .padding(9)
            }
        }
    }

    /// 手机正面：截图缩略图、金额和保存按钮的抽象版记账表单。
    private var phoneFront: some View {
        phoneBody(fill: Color(uiColor: .secondarySystemGroupedBackground)) {
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .frame(height: 44)
                    .overlay {
                        Image(systemName: "photo")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 46, height: 9)
                Capsule()
                    .fill(Color(uiColor: .systemFill))
                    .frame(height: 6)
                Capsule()
                    .fill(Color(uiColor: .systemFill))
                    .frame(width: 40, height: 6)
                Spacer(minLength: 0)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 20)
                    .overlay {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
            }
            .padding(10)
        }
    }

    /// 两台示意手机共用的圆角机身。
    private func phoneBody<Content: View>(
        fill: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(width: 88, height: 156)
            .background(fill, in: .rect(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(Color(uiColor: .separator), lineWidth: 1.5)
            }
    }

    /// 从轻点位置向外扩散并淡出的一圈涟漪。
    private func ripple(delay: Double) -> some View {
        Circle()
            .stroke(Color.accentColor, lineWidth: 2)
            .frame(width: 44, height: 44)
            .scaleEffect(isPulsing ? 1.7 : 0.7)
            .opacity(isPulsing ? 0 : 0.8)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 1.4).repeatForever(autoreverses: false).delay(delay),
                value: isPulsing
            )
    }
}

/// 按行排列子视图，宽度不足时换行；用于长度随语言变化的设置路径。
private struct ScreenshotShortcutFlowLayout: Layout {
    /// 同一行内及行与行之间的间距。
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, in: width)
        return CGSize(
            width: proposal.width ?? rows.map(\.width).max() ?? 0,
            height: rows.last.map { $0.y + $0.height } ?? 0
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, in: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: bounds.minY + row.y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
        }
    }

    /// 一行内的子视图下标及该行的位置和尺寸。
    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// 按可用宽度把子视图依次分配到各行。
    private func arrange(_ subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = needed
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

#Preview {
    NavigationStack { ScreenshotShortcutSetupView() }
}
