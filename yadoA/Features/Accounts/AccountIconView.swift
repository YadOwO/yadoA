import SwiftUI

/// 账户列表与后续详情页共用的图标展示数据。
struct AccountIconPresentation: Equatable {
    /// 已知模板在 Asset Catalog 中对应的品牌图片。
    let brandImageName: String?

    /// 品牌图片缺失或模板未知时使用的 SF Symbol。
    let symbolName: String

    /// SF Symbol 使用的系统动态色调。
    let tint: Color
}

/// 统一渲染品牌图片或安全降级 SF Symbol 的账户图标。
struct AccountIconView: View {
    /// 当前账户解析出的图标展示数据。
    let presentation: AccountIconPresentation

    var body: some View {
        Group {
            if let brandImageName = presentation.brandImageName {
                Image(brandImageName)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: presentation.symbolName)
                    .resizable()
                    .scaledToFit()
                    .padding(7)
                    .foregroundStyle(presentation.tint)
            }
        }
        .frame(width: 36, height: 36)
        .accessibilityHidden(true)
    }
}
