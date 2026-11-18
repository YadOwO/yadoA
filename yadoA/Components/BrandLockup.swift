import SwiftUI

/// 产品标记加衬线产品名横向排开的品牌落款。
///
/// 用在登录页导航栏标题位，以及首次启动隐私同意、AI 记账说明这类整屏同意页的页首，让用户一眼知道是芽豆资产在请求同意。
/// 标记用 `BrandMark`（与 App 图标里的 A 和对勾同源），深浅色各有一份；名称跟随当前语言。
struct BrandLockup: View {
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 7) {
            Image(.brandMark)
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
            Text(AccountLocalization.string("app.name", locale: locale))
                .font(.system(size: 22, weight: .semibold, design: .serif))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    BrandLockup()
        .padding()
        .paperPage()
}
