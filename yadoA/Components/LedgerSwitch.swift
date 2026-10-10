import SwiftUI

/// 手写在纸上的单选切换：几个衬线词并排，选中的那个用墨色并在下面划一道线。
///
/// 代替系统分段选择器，避免一整条灰色胶囊压在纸面上。每个词都是独立按钮，保留 44pt 点击区域；
/// 控件只占内容本身的宽度，居中还是靠边由使用处决定。
struct LedgerSwitch<Value: Hashable>: View {
    /// 一个可选项。
    struct Option {
        /// 选中后写回的值。
        let value: Value

        /// 已本地化的显示文字。
        let title: String

        /// 这个选项的自动化标识。
        let identifier: String
    }

    /// 字号层级：同一页有两组切换时，用大小区分主次。
    enum Size {
        /// 页面的主要切换，如支出 / 收入。
        case regular

        /// 从属的切换，如周 / 月 / 年。
        case compact
    }

    @Namespace private var underline

    /// 整组切换的无障碍名称。
    let label: String

    /// 当前选中的值。
    @Binding var selection: Value

    /// 从左到右排列的全部选项。
    let options: [Option]

    /// 字号层级，默认是主要切换。
    var size: Size = .regular

    var body: some View {
        HStack(spacing: size == .regular ? 28 : 16) {
            ForEach(options, id: \.value) { option in
                button(for: option)
            }
        }
        .animation(.snappy(duration: 0.25), value: selection)
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    /// 单个选项：选中时加粗并划线，未选中时退为灰色。
    private func button(for option: Option) -> some View {
        let isSelected = option.value == selection

        return Button {
            selection = option.value
        } label: {
            Text(option.title)
                .font(
                    .system(
                        size == .regular ? .title3 : .subheadline,
                        design: .serif,
                        weight: isSelected ? .semibold : .regular
                    )
                )
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .padding(.horizontal, size == .regular ? 6 : 4)
                .frame(minWidth: size == .regular ? 44 : 32, minHeight: 44)
                .overlay(alignment: .bottom) {
                    if isSelected {
                        HandDrawnRule(seed: 71)
                            .stroke(
                                Color.primary.opacity(0.85),
                                style: StrokeStyle(lineWidth: size == .regular ? 1.6 : 1.3, lineCap: .round)
                            )
                            .frame(height: 3)
                            .padding(.bottom, size == .regular ? 5 : 8)
                            .matchedGeometryEffect(id: "underline", in: underline)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(option.identifier)
    }
}

extension BookkeepingEntryType {
    /// "支出 / 收入"切换的选项，各页面共用；每个选项的标识为"前缀-方向"。
    ///
    /// - Parameters:
    ///   - identifier: 自动化标识前缀。
    ///   - locale: 用于解析标题的语言环境。
    static func ledgerSwitchOptions(
        identifier: String,
        locale: Locale
    ) -> [LedgerSwitch<BookkeepingEntryType>.Option] {
        allCases.map {
            .init(
                value: $0,
                title: $0.localizedTitle(locale: locale),
                identifier: "\(identifier)-\($0.rawValue)"
            )
        }
    }
}

#Preview {
    @Previewable @State var entryType = BookkeepingEntryType.expense

    LedgerSwitch(
        label: "Type",
        selection: $entryType,
        options: BookkeepingEntryType.ledgerSwitchOptions(identifier: "preview", locale: .current)
    )
    .padding(24)
    .paperPage()
}
