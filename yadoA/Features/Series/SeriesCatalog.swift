import Foundation

/// 芽豆系列的产品目录，「更多芽豆产品」页的数据。
///
/// 由 yado_run 网站在构建时生成（`src/pages/api/series.json.ts`），各 App 拉同一份、用自己的样式画列表；
/// 产品上架或改介绍只需重新部署网站，App 不用发版。网站约定路径不改、字段只加不改，App 这边忽略不认识的字段。
struct SeriesCatalog: Decodable, Equatable {
    /// 目录地址，和法律文档在同一个网站上。
    static let endpoint = LegalDocument.baseURL.appending(path: "api/series.json")

    /// 本 App 在目录里的代号，与 `FeedbackAPI.product`、`AIBillingAPI.product` 一致。
    static let currentProductCode = "yadoa"

    /// 目录里的全部产品，顺序由网站决定。
    let products: [SeriesProduct]

    /// 要向用户展示的产品：去掉本 App 自己。为空时「我的」页不显示入口。
    var otherProducts: [SeriesProduct] {
        products.filter { $0.code != Self.currentProductCode }
    }

    /// 直接用产品列表创建，供测试和预览使用。
    ///
    /// - Parameter products: 目录里的产品。
    init(products: [SeriesProduct]) {
        self.products = products
    }

    /// 逐个解码产品：某一个不符合契约（例如以后新增了本版本不认识的状态）时只跳过它，其余照常显示。
    ///
    /// - Throws: 整体不是 `{"products": [...]}` 结构时抛出 `DecodingError`。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        products = try container.decode([LossyProduct].self, forKey: .products).compactMap(\.product)
    }

    /// 目录的 JSON 字段。
    private enum CodingKeys: String, CodingKey {
        case products
    }

    /// 解码失败时得到 nil 而不是让整份目录失败的包装。
    private struct LossyProduct: Decodable {
        /// 解码成功的产品。
        let product: SeriesProduct?

        init(from decoder: Decoder) throws {
            product = try? SeriesProduct(from: decoder)
        }
    }
}

/// 目录里的一个芽豆产品。
struct SeriesProduct: Decodable, Equatable, Identifiable {
    /// 产品对外的阶段，取值与 yado_run `Product.status` 中会下发的两种一致。
    enum Status: String, Decodable {
        /// 即将上线：只展示，不给获取按钮。
        case comingSoon = "coming-soon"
        /// 已上架。
        case available = "now-showing"
    }

    /// 产品代号，小写，例如 `yadoi`。
    let code: String
    /// 产品名称。
    let name: SeriesLocalized<String>
    /// 一句话介绍；网站没填时为 nil。
    let tagline: SeriesLocalized<String>?
    /// 产品阶段。
    let status: Status
    /// 产品强调色，`#RRGGBB`；没有图标时用它画占位。
    let accent: String?
    /// 图标地址；网站没放图标时为 nil。
    let iconURL: URL?
    /// App Store 的数字 ID；没上架时为 nil。
    let appStoreId: String?
    /// 网站上的产品介绍页；没有产品页时为 nil。
    let pageURL: SeriesLocalized<URL>?

    /// 列表里的稳定标识。
    var id: String { code }

    /// App Store 上的产品页地址；只有已上架且 ID 是纯数字时才有，界面据此决定是否显示「获取」。
    var appStoreURL: URL? {
        guard status == .available,
              let appStoreId,
              !appStoreId.isEmpty,
              appStoreId.allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        return URL(string: "https://apps.apple.com/app/id\(appStoreId)")
    }
}

/// 中英两版的内容；目录里跟语言走的字段（名称、介绍、产品页地址）都是这个结构。
struct SeriesLocalized<Value: Decodable & Equatable>: Decodable, Equatable {
    /// 英文版。
    let en: Value
    /// 中文版。
    let zh: Value

    /// 按 App 当前语言取值：中文界面取中文版，其他语言取英文版，与 `LegalDocument.url(locale:)` 的规则一致。
    ///
    /// - Parameter locale: App 当前的语言环境（设置里选的语言，跟随系统时是系统语言）。
    /// - Returns: 对应语言的内容。
    func value(locale: Locale) -> Value {
        locale.language.languageCode == .chinese ? zh : en
    }
}
