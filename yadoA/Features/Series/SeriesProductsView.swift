import SwiftUI

/// “我的 › 更多芽豆产品”：列出芽豆系列的其他 App，每个产品一张卡片。
///
/// 数据来自根部注入的 `SeriesCatalogStore`（网站下发的目录，已去掉本 App 自己）。已上架的产品给「获取」，跳到 App Store；
/// 即将上线的只标状态。有产品介绍页的给「了解更多」，在 App 内用 Safari 视图打开网站上的产品页。
struct SeriesProductsView: View {
    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL
    /// 产品目录；预览中没有注入时为 nil。
    @Environment(SeriesCatalogStore.self) private var catalog: SeriesCatalogStore?

    /// 正在 App 内打开的产品介绍页。
    @State private var presentedPage: SeriesWebPage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(text(products.isEmpty ? "series.empty" : "series.intro"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)

                ForEach(products) { product in
                    SeriesProductCard(
                        product: product,
                        onGet: { url in openURL(url) },
                        onLearnMore: { url in presentedPage = SeriesWebPage(url: url) }
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .paperPage()
        .navigationTitle(text("series.title"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $presentedPage) { page in
            InAppSafariView(url: page.url)
                .ignoresSafeArea()
        }
        .task {
            // 停在这一页时也刷新一次，产品刚上架时不用退回「我的」再进来
            await catalog?.refresh()
        }
    }

    /// 要展示的产品；目录还没拉到或只有本 App 自己时为空，页面只显示一句说明。
    private var products: [SeriesProduct] {
        catalog?.products ?? []
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 要在 App 内打开的网页；给 `sheet(item:)` 用。
private struct SeriesWebPage: Identifiable {
    /// 网页地址。
    let url: URL

    /// 以地址作为标识。
    var id: URL { url }
}

/// 一个产品的卡片：图标、名称、一句话介绍，右侧是「获取」或「即将上线」，下方可选「了解更多」。
private struct SeriesProductCard: View {
    @Environment(\.locale) private var locale

    /// 要展示的产品。
    let product: SeriesProduct
    /// 点「获取」时调用，参数是 App Store 上的产品页地址。
    let onGet: (URL) -> Void
    /// 点「了解更多」时调用，参数是当前语言的产品介绍页地址。
    let onLearnMore: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                SeriesProductIcon(product: product, name: name)

                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.system(.headline, design: .serif, weight: .semibold))
                    if let tagline = product.tagline?.value(locale: locale), !tagline.isEmpty {
                        Text(tagline)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                trailingAction
            }

            if let pageURL = product.pageURL?.value(locale: locale) {
                Button {
                    onLearnMore(pageURL)
                } label: {
                    HStack(spacing: 4) {
                        Text(text("series.action.learnMore"))
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    AccountLocalization.formatted("series.action.learnMore.accessibility", value: name, locale: locale)
                )
                .accessibilityIdentifier("series-learn-more-\(product.code)")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ledgerFormBorder(seed: "series.product.\(product.code)".handDrawnSeed)
        .accessibilityIdentifier("series-product-\(product.code)")
    }

    /// 卡片右侧：已上架且有 App Store 地址时是「获取」按钮，即将上线时是状态文字，其他情况不显示。
    @ViewBuilder
    private var trailingAction: some View {
        if let appStoreURL = product.appStoreURL {
            Button {
                onGet(appStoreURL)
            } label: {
                Text(text("series.action.get"))
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 6)
                    .onAccentForeground()
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .accessibilityLabel(AccountLocalization.formatted("series.action.get.accessibility", value: name, locale: locale))
            .accessibilityIdentifier("series-get-\(product.code)")
        } else if product.status == .comingSoon {
            Text(text("series.status.comingSoon"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// 当前语言的产品名称。
    private var name: String {
        product.name.value(locale: locale)
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 产品图标：有图标地址时加载网络图片；没有、加载中或加载失败时，用产品强调色的浅底加名称首字占位。
private struct SeriesProductIcon: View {
    /// 要展示的产品。
    let product: SeriesProduct
    /// 当前语言的产品名称，占位时取首字。
    let name: String

    /// 图标边长。
    private static let size: CGFloat = 56

    var body: some View {
        Group {
            if let iconURL = product.iconURL {
                AsyncImage(url: iconURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: Self.size, height: Self.size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .accessibilityHidden(true)
    }

    /// 图标外形，接近系统 App 图标的圆角。
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.size * 0.225, style: .continuous)
    }

    /// 占位：强调色只做浅底，文字用主文字色，浅色和深色外观下都看得清。
    private var placeholder: some View {
        ZStack {
            (SeriesAccentColor.color(hex: product.accent) ?? Color.secondary).opacity(0.22)
            Text(String(name.prefix(1)))
                .font(.system(.title2, design: .serif, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }
}

/// 把目录里的 `#RRGGBB` 强调色转成颜色。
enum SeriesAccentColor {
    /// 解析 `#RRGGBB`（`#` 可省略）。
    ///
    /// - Parameter hex: 目录里的强调色。
    /// - Returns: 对应的颜色；为 nil 或格式不对时返回 nil。
    static func color(hex: String?) -> Color? {
        guard let components = components(hex: hex) else { return nil }
        return Color(.sRGB, red: components.red, green: components.green, blue: components.blue)
    }

    /// 解析出 0～1 的红、绿、蓝分量。
    ///
    /// - Parameter hex: `#RRGGBB`，`#` 可省略。
    /// - Returns: 三个分量；为 nil、长度不是 6 位或含非十六进制字符时返回 nil。
    static func components(hex: String?) -> (red: Double, green: Double, blue: Double)? {
        guard let hex else { return nil }
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else { return nil }
        return (
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

#Preview {
    NavigationStack { SeriesProductsView() }
        .environment(SeriesCatalogStore(fetcher: SeriesCatalogAPI(), defaults: UserDefaults(suiteName: "series.preview")!))
}
