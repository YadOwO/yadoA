import SwiftUI

/// 手记卡片里的一行"名称 — 内容"：名称在左、用次要色，内容在右、可换行。
///
/// 用来代替系统表单行，写在手绘方框里时不需要额外的行底和分隔线。
/// 内容前面可以带一个小图标（例如账户图标），让人不读字也能认出是哪一项。
struct LedgerField<ValueLeading: View>: View {
    /// 已本地化的字段名称。
    let title: String

    /// 已本地化或用户输入的字段内容。
    let value: String

    /// 紧挨在内容前面的附加视图，例如账户图标；没有时为 `EmptyView`。
    private let valueLeading: ValueLeading

    /// 附加视图中心比文字基线高出的距离，约为半个大写字母高；随动态字体缩放，让图标落在第一行文字的中线上。
    @ScaledMetric(relativeTo: .subheadline) private var leadingBaselineOffset: CGFloat = 5

    /// 创建内容前带附加视图的一行。
    ///
    /// - Parameters:
    ///   - title: 已本地化的字段名称。
    ///   - value: 已本地化或用户输入的字段内容。
    ///   - valueLeading: 紧挨在内容前面的附加视图；只做装饰，不参与辅助功能播报。
    init(title: String, value: String, @ViewBuilder valueLeading: () -> ValueLeading) {
        self.title = title
        self.value = value
        self.valueLeading = valueLeading()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                valueLeading
                    // 图片没有文字基线；把它的中心对到第一行文字的中线，内容换行时图标仍跟着第一行。
                    .alignmentGuide(.firstTextBaseline) { dimensions in
                        dimensions[VerticalAlignment.center] + leadingBaselineOffset
                    }
                    .accessibilityHidden(true)
                Text(value)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.subheadline)
        // 合并后播报为"名称, 内容"，与原先的系统表单行一致。
        .accessibilityElement(children: .combine)
    }
}

extension LedgerField where ValueLeading == EmptyView {
    /// 创建只有名称和内容的一行。
    ///
    /// - Parameters:
    ///   - title: 已本地化的字段名称。
    ///   - value: 已本地化或用户输入的字段内容。
    init(title: String, value: String) {
        self.init(title: title, value: value) { EmptyView() }
    }
}

#Preview {
    VStack(spacing: 12) {
        LedgerField(title: "类型", value: "支出")
        LedgerField(title: "所属账户", value: "招商银行") {
            Image(systemName: "building.columns.fill")
                .foregroundStyle(.tint)
        }
        LedgerField(title: "备注", value: "和同事一起吃的午饭，回头记得找他们平摊一下")
    }
    .padding(24)
    .paperPage()
}
