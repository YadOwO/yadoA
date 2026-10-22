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

    /// 「按住说"……"」形式的引导文字。
    ///
    /// - Parameters:
    ///   - index: 轮换到的示例下标，超出范围时取模。
    ///   - locale: 文案使用的语言环境。
    /// - Returns: 带示例说法的按住提示。
    static func holdPrompt(index: Int, locale: Locale) -> String {
        let examples = examples(locale: locale)
        let example = examples[((index % examples.count) + examples.count) % examples.count]
        return AccountLocalization.formatted("voice.guide.hold_format", value: example, locale: locale)
    }
}

/// 麦克风空闲时轮换显示的「按住说"午饭 28……"」引导；按着或忙碌时由调用方换成状态文字。
struct VoiceRotatingHoldPrompt: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 是否轮换；按住、处理中或页面不可见时停在当前一条。
    let isRotating: Bool

    /// 当前轮换到的示例下标。
    @State private var index = 0

    var body: some View {
        Text(VoiceSpeakingGuide.holdPrompt(index: index, locale: locale))
            .id(index)
            .transition(reduceMotion ? .opacity : .push(from: .bottom))
            .task(id: isRotating) {
                guard isRotating else { return }
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: VoiceSpeakingGuide.rotationInterval)
                    } catch {
                        return
                    }
                    withAnimation(.easeInOut(duration: 0.35)) {
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
        VStack(alignment: .leading, spacing: 6) {
            Text(AccountLocalization.string("voice.guide.title", locale: locale))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(VoiceSpeakingGuide.examples(locale: locale), id: \.self) { example in
                Label {
                    Text(example)
                } icon: {
                    Image(systemName: "quote.opening")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("voice-speaking-examples")
    }
}
