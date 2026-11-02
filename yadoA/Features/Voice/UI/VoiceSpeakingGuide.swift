import SwiftUI

/// 语音记账的说法示例：告诉用户按住后可以怎么说，覆盖记一笔、一句多笔、改账和查询。
enum VoiceSpeakingGuide {
    /// 示例说法的本地化键，按展示顺序排列。
    static let exampleKeys = [
        "voice.guide.example.add",
        "voice.guide.example.multiple",
        "voice.guide.example.update",
        "voice.guide.example.query"
    ]

    /// 麦克风空闲时轮换示例的间隔。
    static let rotationInterval: Duration = .seconds(4)

    /// 当前语言下的全部示例说法。
    ///
    /// - Parameter locale: 文案使用的语言环境。
    /// - Returns: 按展示顺序排列的示例。
    static func examples(locale: Locale) -> [String] {
        exampleKeys.map { AccountLocalization.string($0, locale: locale) }
    }

    /// 加上引号的示例说法，用来跟在「按住说话」后面。
    ///
    /// - Parameters:
    ///   - index: 轮换到的示例下标，超出范围时取模。
    ///   - locale: 文案使用的语言环境。
    /// - Returns: 带引号的示例说法。
    static func quotedExample(index: Int, locale: Locale) -> String {
        let examples = examples(locale: locale)
        let example = examples[((index % examples.count) + examples.count) % examples.count]
        return AccountLocalization.formatted("voice.guide.quote_format", value: example, locale: locale)
    }
}

/// 麦克风空闲时的引导：「按住说话」照常显示，后面跟一句轮换的示例说法。
///
/// 示例只是顺带一提：用常规字重和更淡一级的颜色，轮换时只淡入淡出，不跳动，不和操作本身抢注意力。
struct VoiceRotatingHoldPrompt: View {
    @Environment(\.locale) private var locale

    /// 是否轮换；按住、处理中或页面不可见时停在当前一条。
    let isRotating: Bool

    /// 示例说法的颜色，比「按住说话」淡一级。
    var exampleStyle: HierarchicalShapeStyle = .tertiary

    /// 当前轮换到的示例下标。
    @State private var index = 0

    var body: some View {
        HStack(spacing: 6) {
            Text(AccountLocalization.string("voice.mic.holdHint", locale: locale))
                .layoutPriority(1)
            Text(VoiceSpeakingGuide.quotedExample(index: index, locale: locale))
                .fontWeight(.regular)
                .foregroundStyle(exampleStyle)
                .truncationMode(.tail)
                .id(index)
                .transition(.opacity)
        }
        .lineLimit(1)
        .task(id: isRotating) {
            guard isRotating else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: VoiceSpeakingGuide.rotationInterval)
                } catch {
                    return
                }
                withAnimation(.easeInOut(duration: 0.6)) {
                    index += 1
                }
            }
        }
    }
}

/// 第一次按住、还没识别到文字时，在「正在听…」下面列出几种说法，帮用户开口。
struct VoiceSpeakingExamples: View {
    @Environment(\.locale) private var locale

    var body: some View {
        // 只是给不知道怎么开口的人参考：小一号字、淡色、没有图标，用户一开口就消失。
        VStack(alignment: .leading, spacing: 4) {
            Text(AccountLocalization.string("voice.guide.title", locale: locale))
                .foregroundStyle(.tertiary)
            ForEach(VoiceSpeakingGuide.examples(locale: locale), id: \.self) { example in
                Text(AccountLocalization.formatted("voice.guide.quote_format", value: example, locale: locale))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("voice-speaking-examples")
    }
}
