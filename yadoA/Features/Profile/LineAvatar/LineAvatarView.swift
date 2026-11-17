import SwiftUI

/// 把各槽位的线条画到画布上；设计画布按视图较短边等比缩放并居中。
///
/// 墨色跟随系统主文字色，红色用账本红，深浅外观都会自动适配。
struct LineAvatarCanvas: View {
    /// 各槽位此刻的画面。
    let frames: [LineAvatarSlot: LineAvatarStrokeFrame]

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let scale = side / LineAvatarGeometry.canvasSize
            context.translateBy(x: (size.width - side) / 2, y: (size.height - side) / 2)
            context.scaleBy(x: scale, y: scale)

            let style = StrokeStyle(lineWidth: LineAvatarGeometry.lineWidth, lineCap: .round, lineJoin: .round)
            for slot in LineAvatarSlot.allCases {
                guard let frame = frames[slot], let path = frame.visiblePath() else { continue }
                context.stroke(path, with: .color(Self.color(accentMix: frame.accentMix)), style: style)
            }
        }
        .accessibilityHidden(true)
    }

    /// 按混合比例取线条颜色；只在墨色和红色之间过渡时才混色。
    private static func color(accentMix: CGFloat) -> Color {
        if accentMix <= 0.001 { return .primary }
        if accentMix >= 0.999 { return Color(.ledgerRed) }
        return Color.primary.mix(with: Color(.ledgerRed), by: Double(accentMix))
    }
}

/// 静态线条头像：圆形底色上画一个预制头像，用于资料页、列表等。
struct LineAvatarView: View {
    @Environment(\.locale) private var locale

    /// 要显示的预制头像。
    let preset: LineAvatarPreset
    /// 头像直径。
    let size: CGFloat

    var body: some View {
        LineAvatarCanvas(frames: LineAvatarStrokeFrame.resting(preset.figure))
            .frame(width: size, height: size)
            .background(LineAvatarBackground())
            .accessibilityElement()
            .accessibilityAddTraits(.isImage)
            .accessibilityLabel(AccountLocalization.string(preset.nameKey, locale: locale))
    }
}

/// 线条头像的圆形底色：比页面纸色略亮，加一圈很淡的描边。
struct LineAvatarBackground: View {
    var body: some View {
        Circle()
            .fill(Color(.paperSurface))
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

#Preview("全部预制头像") {
    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 16)], spacing: 16) {
            ForEach(LineAvatarCatalog.presets) { preset in
                LineAvatarView(preset: preset, size: 96)
            }
        }
        .padding()
    }
    .background(Color(.paperBackground))
}
