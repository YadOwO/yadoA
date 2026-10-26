import SwiftUI

/// “我的”与“设置”共用的分组卡片：可选的分组标题加手绘边框卡片，支持浅色、深色及动态字号。
struct ProfileSettingsSection<Content: View>: View {
    @Environment(\.locale) private var locale

    /// 分组标题的本地化 key；为 `nil` 时只显示卡片。
    let titleKey: String?
    /// 手绘边框的随机种子，保证同一分组每次绘制一致。
    let seed: String
    /// 卡片内的行。
    @ViewBuilder let content: Content

    /// 创建分组卡片。
    ///
    /// - Parameters:
    ///   - titleKey: 分组标题的本地化 key；无标题时传 `nil`。
    ///   - seed: 手绘边框的种子；默认使用标题 key。无标题分组需传入各自不同的种子。
    ///   - content: 卡片内的行。
    init(_ titleKey: String?, seed: String? = nil, @ViewBuilder content: () -> Content) {
        self.titleKey = titleKey
        self.seed = seed ?? titleKey ?? ""
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let titleKey {
                Text(AccountLocalization.string(titleKey, locale: locale))
                    .font(.system(.subheadline, design: .serif, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
                    .accessibilityAddTraits(.isHeader)
            }

            VStack(spacing: 0) { content }
                .ledgerFormBorder(seed: seed.handDrawnSeed)
        }
    }
}

/// 图标、标题、当前值与导航箭头组成的整行点击区域。
struct ProfileSettingsRow: View {
    @Environment(\.locale) private var locale

    /// 标题的本地化 key。
    let titleKey: String
    /// SF Symbols 图标名。
    let symbol: String
    /// 行尾显示的当前值；为空时只显示箭头。
    var value: String = ""

    var body: some View {
        HStack(spacing: 12) {
            Label(AccountLocalization.string(titleKey, locale: locale), systemImage: symbol)
                .labelStyle(ProfileSettingsLabelStyle())
            Spacer(minLength: 4)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .font(.body)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(minHeight: 60)
        .contentShape(Rectangle())
    }
}

/// 两行之间的手绘细线，从标题处开始。
struct ProfileSettingsRowDivider: View {
    var body: some View {
        HandDrawnRule(seed: 99)
            .stroke(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            .frame(height: 3)
            .padding(.leading, 62)
            .padding(.trailing, 20)
            .accessibilityHidden(true)
    }
}

/// 统一个人页图标宽度，使用系统线性图标和主文字色。
struct ProfileSettingsLabelStyle: LabelStyle {
    /// 图标与标题的颜色；破坏性操作使用红色。
    var color: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 14) {
            configuration.icon
                .font(.system(size: 21, weight: .regular))
                .frame(width: 28)
                .accessibilityHidden(true)
            configuration.title
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color)
    }
}

/// 将按钮类行的留白纳入 Button 标签，使整行均可点击。
struct ProfileExportLabelStyle: LabelStyle {
    /// 图标与标题的颜色；破坏性操作使用红色。
    var color: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        Label(configuration)
            .labelStyle(ProfileSettingsLabelStyle(color: color))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .contentShape(Rectangle())
    }
}
