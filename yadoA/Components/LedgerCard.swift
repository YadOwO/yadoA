import SwiftUI

/// 表单、设置和选择页共用的页面骨架：纸面上可滚动的一列卡片。
///
/// 首页、账户页那种"流水明细"直接一行行写在纸上；需要填写或点选的页面则把内容收进手绘方框，
/// 两类页面由此区分开。
struct LedgerFormPage<Content: View>: View {
    /// 从上到下排列的卡片、提示和按钮。
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .paperPage()
    }
}

/// 一张手绘方框的卡片：里面的每一行之间自动画一条手绘细线。
///
/// 行内容自行调用 `ledgerCardRow()` 留出内边距；可点击的行把它加在按钮标签上，保证整行可点。
struct LedgerCard<Content: View>: View {
    /// 方框和细线的笔迹种子，同一页的几张卡片各用一个。
    var seed: UInt64 = 0

    /// 卡片里的各行。
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.element.id) { index, subview in
                    if index > 0 {
                        HandDrawnRule(seed: seed &+ UInt64(index))
                            .stroke(
                                Color.primary.opacity(0.16),
                                style: StrokeStyle(lineWidth: 1, lineCap: .round)
                            )
                            .frame(height: 3)
                            .padding(.horizontal, 20)
                            .accessibilityHidden(true)
                    }
                    subview
                }
            }
        }
        .frame(maxWidth: .infinity)
        .ledgerFormBorder(seed: seed)
    }
}

/// 卡片里"左边名称、右边内容"的一行，右边可以是文字，也可以是输入框等控件。
struct LedgerFormRow<Content: View>: View {
    /// 左边灰色的项目名。
    let title: String

    /// 右边的内容或控件。
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
                .foregroundStyle(.secondary)
            content
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .ledgerCardRow()
    }
}

/// 卡片下方的实底提交按钮，保存中显示进度；删除这类不可撤销的操作改用账本红。
struct LedgerSubmitButton: View {
    /// 已本地化的按钮文字。
    let title: String

    /// 是否正在保存。
    let isSaving: Bool

    /// 是否为删除等不可撤销的操作。
    var isDestructive = false

    /// 点击后的提交动作。
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isSaving {
                    ProgressView()
                        .accessibilityHidden(true)
                }
                Text(title)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .modifier(SubmitLabelForeground(isDestructive: isDestructive))
        }
        .buttonStyle(.borderedProminent)
        .tint(isDestructive ? Color(.ledgerRed) : Color.accentColor)
    }
}

/// 提交按钮文字的颜色：墨色底上跟随外观切换，账本红底上固定用白字。
private struct SubmitLabelForeground: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    /// 是否画在账本红的底色上。
    let isDestructive: Bool

    func body(content: Content) -> some View {
        if isDestructive {
            content.foregroundStyle(isEnabled ? Color.white : Color(uiColor: .tertiaryLabel))
        } else {
            content.onAccentForeground()
        }
    }
}

/// 卡片里可点击行右侧的箭头。
struct LedgerChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

/// 卡片里"图标 + 标题"的整行标签，用于设置类入口。
struct LedgerCardRowLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon
                .font(.body)
                .frame(width: 28)
                .accessibilityHidden(true)
            configuration.title
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.primary)
        .ledgerCardRow()
    }
}

extension View {
    /// 表单方框的边线：比展示卡片的墨线更细、更淡，圆角也收小一点。
    ///
    /// 首页汇总、账户卡、流水票据这些"读"的卡片用粗墨线；需要填写或点选的方框用这道铅笔线，
    /// 让输入内容本身比边框更显眼。
    ///
    /// - Parameter seed: 方框的笔迹种子。
    func ledgerFormBorder(seed: UInt64) -> some View {
        background {
            HandDrawnBox(cornerRadius: 16, seed: seed)
                .stroke(
                    Color.primary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round)
                )
        }
    }

    /// 卡片里一行的内边距、最小高度和整行点击区域。
    func ledgerCardRow() -> some View {
        padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .contentShape(Rectangle())
    }
}

#Preview {
    LedgerFormPage {
        LedgerCard(seed: 3) {
            LedgerFormRow(title: "Name") {
                Text(verbatim: "Cash")
            }
            LedgerFormRow(title: "Note") {
                TextField(String("Optional"), text: .constant(""))
            }
        }
        LedgerSubmitButton(title: "Save", isSaving: false) {}
    }
}
