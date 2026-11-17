import SwiftUI
import UIKit

/// 金额的正负语义，决定按全局正负颜色上色，还是保持调用方原来的文字色。
enum AmountTone: Equatable, Sendable {
    /// 正向：结余为正、点数增加等。
    case positive
    /// 负向：结余为负、账户欠款或透支等拉低净资产的金额。
    case negative
    /// 不上色。
    case neutral

    /// 按数值正负取语义，零为中性。
    ///
    /// - Parameter amount: 带符号的金额。
    init(signOf amount: Decimal) {
        if amount > 0 {
            self = .positive
        } else if amount < 0 {
            self = .negative
        } else {
            self = .neutral
        }
    }
}

extension View {
    /// 按“我的 › 设置 › 正负颜色”给金额上色；中性时不改颜色。
    ///
    /// 要写在其他 `foregroundStyle` 之前（更贴近文字），否则会被内层的颜色盖住。
    ///
    /// - Parameter tone: 金额的正负语义。
    func amountTone(_ tone: AmountTone) -> some View {
        modifier(AmountToneModifier(tone: tone))
    }
}

/// 读取全局正负颜色给内容上色；设置修改后各页面立即刷新。
private struct AmountToneModifier: ViewModifier {
    @AppStorage(AmountColorConvention.storageKey) private var convention: AmountColorConvention = .positiveRed

    /// 金额的正负语义。
    let tone: AmountTone

    func body(content: Content) -> some View {
        if let color = convention.color(for: tone) {
            content.foregroundStyle(color)
        } else {
            content
        }
    }
}

extension AmountColorConvention {
    /// 设置菜单项里的示意图：带颜色的加号和减号，对应正、负金额各自的颜色。
    ///
    /// 系统菜单只会原样显示“原色”位图，因此按当前外观把两种颜色画进一张图。
    ///
    /// - Parameter colorScheme: 当前外观，决定取账本红、账本绿的浅色还是深色值。
    /// - Returns: 可直接放进菜单项的图标。
    func swatch(colorScheme: ColorScheme) -> Image {
        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        let red = UIColor(resource: .ledgerRed).resolvedColor(with: traits)
        let green = UIColor(resource: .ledgerGreen).resolvedColor(with: traits)
        let isPositiveRed = self == .positiveRed
        let configuration = UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)

        guard
            let plus = UIImage(systemName: "plus", withConfiguration: configuration)?
                .withTintColor(isPositiveRed ? red : green, renderingMode: .alwaysOriginal),
            let minus = UIImage(systemName: "minus", withConfiguration: configuration)?
                .withTintColor(isPositiveRed ? green : red, renderingMode: .alwaysOriginal)
        else {
            return Image(systemName: "plusminus")
        }

        let spacing: CGFloat = 4
        let size = CGSize(
            width: plus.size.width + spacing + minus.size.width,
            height: max(plus.size.height, minus.size.height)
        )
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            plus.draw(at: CGPoint(x: 0, y: (size.height - plus.size.height) / 2))
            minus.draw(at: CGPoint(x: plus.size.width + spacing, y: (size.height - minus.size.height) / 2))
        }
        return Image(uiImage: image.withRenderingMode(.alwaysOriginal))
    }
}
