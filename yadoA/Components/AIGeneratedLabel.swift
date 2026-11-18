import SwiftUI

/// 「内容由 AI 生成，请核对」标注：一行灰色小字，加一个星光图标。
///
/// 按《人工智能生成合成内容标识办法》，凡是显示 AI 写出来的文字，都要明确标出内容由 AI 生成。
/// 使用规则：
/// - 只放在 AI 写的文字下面：聊天回复、追问、查账卡片，以及用模型原话做标题的结果纸条。
/// - 不放在失败提示、处理中状态和用户自己说的话下面。
/// - 是否显示由调用方用 `AIChatCopy.showsModelText(in:locale:)` 等条件决定，这里不做地区或语言判断，显示就一直显示。
///
/// 它是和正文并列的兄弟视图，不放进 `conversationTextSelection()` 里，也不加 `contextMenu`：
/// 长按选中、拷贝正文的行为和以前一样，标注本身不参与选中。
struct AIGeneratedLabel: View {
    @Environment(\.locale) private var locale

    var body: some View {
        Label(AccountLocalization.string("ai.generated.label", locale: locale), systemImage: "sparkles")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            // 合并成一个读屏元素，朗读完整句子，图标不单独读
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("ai-generated-label")
    }
}
