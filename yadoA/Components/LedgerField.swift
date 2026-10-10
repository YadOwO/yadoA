import SwiftUI

/// 手记卡片里的一行"名称 — 内容"：名称在左、用次要色，内容在右、可换行。
///
/// 用来代替系统表单行，写在手绘方框里时不需要额外的行底和分隔线。
struct LedgerField: View {
    /// 已本地化的字段名称。
    let title: String

    /// 已本地化或用户输入的字段内容。
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        // 合并后播报为"名称, 内容"，与原先的系统表单行一致。
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    VStack(spacing: 12) {
        LedgerField(title: "类型", value: "支出")
        LedgerField(title: "备注", value: "和同事一起吃的午饭，回头记得找他们平摊一下")
    }
    .padding(24)
    .paperPage()
}
