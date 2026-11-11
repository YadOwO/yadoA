import Foundation
import Testing
@testable import yadoA

/// 验证「更多芽豆产品」：目录解码、去掉本 App、按语言取值、App Store 地址、缓存与刷新、文案。
@Suite("更多芽豆产品")
@MainActor
struct SeriesCatalogTests {
    /// 英文环境。
    private let english = Locale(identifier: "en")
    /// 简体中文环境。
    private let simplifiedChinese = Locale(identifier: "zh-Hans")

    /// 与 yado_run `/api/series.json` 同结构的目录：本 App、一个已上架产品、一个即将上线的产品。
    private static let catalogJSON = """
    {"version":1,"products":[
      {"code":"yadoa","name":{"en":"yado Assets","zh":"芽豆资产"},"tagline":{"en":"A ledger that listens.","zh":"会听话的账本。"},
       "status":"coming-soon","accent":"#F0674C","iconURL":null,"appStoreId":null,
       "pageURL":{"en":"https://my.yado1225.top/works/yadoa/","zh":"https://my.yado1225.top/zh/works/yadoa/"}},
      {"code":"yadoi","name":{"en":"yado Items","zh":"芽豆有物"},"tagline":{"en":"What you own.","zh":"记录你拥有的东西。"},
       "status":"now-showing","accent":"#B9D9F0","iconURL":"https://my.yado1225.top/series/yadoi.png","appStoreId":"1234567890",
       "pageURL":{"en":"https://my.yado1225.top/works/yadoi/","zh":"https://my.yado1225.top/zh/works/yadoi/"}},
      {"code":"yadox","name":{"en":"yado X","zh":"芽豆某某"},"tagline":null,
       "status":"coming-soon","accent":"#88E0CD","iconURL":null,"appStoreId":null,"pageURL":null}
    ]}
    """

    /// 每个测试用自己的一份设置，互不影响，也不碰真实缓存。
    private func makeDefaults() -> UserDefaults {
        let name = "series.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: - 契约

    @Test("目录地址在法律文档同一个网站上，路径与 yado_run 约定的一致")
    func endpointMatchesWebsite() {
        #expect(SeriesCatalog.endpoint.absoluteString == "https://my.yado1225.top/api/series.json")
    }

    @Test("目录解码：字段齐全，可空字段为 null 时得到 nil，展示时去掉本 App 自己")
    func decodesCatalogAndDropsCurrentApp() throws {
        let catalog = try JSONDecoder().decode(SeriesCatalog.self, from: Data(Self.catalogJSON.utf8))
        #expect(catalog.products.map(\.code) == ["yadoa", "yadoi", "yadox"])
        #expect(catalog.otherProducts.map(\.code) == ["yadoi", "yadox"])

        let items = try #require(catalog.otherProducts.first)
        #expect(items.status == .available)
        #expect(items.accent == "#B9D9F0")
        #expect(items.iconURL?.absoluteString == "https://my.yado1225.top/series/yadoi.png")
        #expect(items.appStoreId == "1234567890")

        let upcoming = catalog.otherProducts[1]
        #expect(upcoming.status == .comingSoon)
        #expect(upcoming.tagline == nil)
        #expect(upcoming.iconURL == nil)
        #expect(upcoming.pageURL == nil)
    }

    @Test("某个产品不合契约（不认识的状态、缺名称）时只跳过它；整体结构不对时整份失败")
    func skipsMalformedProducts() throws {
        let json = """
        {"products":[
          {"code":"future","name":{"en":"F","zh":"未来"},"status":"archived"},
          {"code":"noname","status":"now-showing"},
          {"code":"yadoi","name":{"en":"yado Items","zh":"芽豆有物"},"status":"now-showing","somethingNew":true}
        ]}
        """
        let catalog = try JSONDecoder().decode(SeriesCatalog.self, from: Data(json.utf8))
        #expect(catalog.products.map(\.code) == ["yadoi"])

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SeriesCatalog.self, from: Data(#"{"items":[]}"#.utf8))
        }
    }

    @Test("中文界面取中文版，其他语言取英文版")
    func localizedValueFollowsAppLanguage() throws {
        let catalog = try JSONDecoder().decode(SeriesCatalog.self, from: Data(Self.catalogJSON.utf8))
        let items = try #require(catalog.otherProducts.first)
        #expect(items.name.value(locale: simplifiedChinese) == "芽豆有物")
        #expect(items.name.value(locale: Locale(identifier: "zh-Hans-CN")) == "芽豆有物")
        #expect(items.name.value(locale: english) == "yado Items")
        #expect(items.name.value(locale: Locale(identifier: "ja")) == "yado Items")
        #expect(items.pageURL?.value(locale: simplifiedChinese).absoluteString == "https://my.yado1225.top/zh/works/yadoi/")
        #expect(items.pageURL?.value(locale: english).absoluteString == "https://my.yado1225.top/works/yadoi/")
    }

    @Test("只有已上架且 ID 是纯数字时才有 App Store 地址")
    func appStoreURLRequiresAvailableStatusAndNumericID() {
        func product(status: SeriesProduct.Status, appStoreId: String?) -> SeriesProduct {
            SeriesProduct(
                code: "yadoi",
                name: SeriesLocalized(en: "yado Items", zh: "芽豆有物"),
                tagline: nil,
                status: status,
                accent: nil,
                iconURL: nil,
                appStoreId: appStoreId,
                pageURL: nil
            )
        }
        #expect(product(status: .available, appStoreId: "1234567890").appStoreURL?.absoluteString
            == "https://apps.apple.com/app/id1234567890")
        #expect(product(status: .comingSoon, appStoreId: "1234567890").appStoreURL == nil)
        #expect(product(status: .available, appStoreId: nil).appStoreURL == nil)
        #expect(product(status: .available, appStoreId: "").appStoreURL == nil)
        #expect(product(status: .available, appStoreId: "id123?x=1").appStoreURL == nil)
    }

    @Test("强调色只认 6 位十六进制，# 可省略")
    func accentColorParsing() throws {
        let accent = try #require(SeriesAccentColor.components(hex: "#F0674C"))
        #expect(abs(accent.red - 240.0 / 255) < 0.0001)
        #expect(abs(accent.green - 103.0 / 255) < 0.0001)
        #expect(abs(accent.blue - 76.0 / 255) < 0.0001)
        #expect(SeriesAccentColor.components(hex: "88E0CD") != nil)
        #expect(SeriesAccentColor.components(hex: nil) == nil)
        #expect(SeriesAccentColor.components(hex: "#FFF") == nil)
        #expect(SeriesAccentColor.components(hex: "#GGGGGG") == nil)
        #expect(SeriesAccentColor.components(hex: "+12345") == nil)
    }

    // MARK: - 目录状态

    @Test("没有缓存时列表为空（入口不显示）；刷新成功后有产品并写入缓存，下次启动直接可用")
    func refreshUpdatesProductsAndCache() async {
        let defaults = makeDefaults()
        let fetcher = FakeSeriesFetcher(result: .success(Data(Self.catalogJSON.utf8)))
        let store = SeriesCatalogStore(fetcher: fetcher, defaults: defaults)
        #expect(store.products.isEmpty)

        await store.refresh()
        #expect(store.products.map(\.code) == ["yadoi", "yadox"])

        // 下次启动：网络不可用也能从缓存读出同一份目录
        let offline = SeriesCatalogStore(fetcher: FakeSeriesFetcher(result: .failure(URLError(.notConnectedToInternet))), defaults: defaults)
        #expect(offline.products.map(\.code) == ["yadoi", "yadox"])
        await offline.refresh()
        #expect(offline.products.map(\.code) == ["yadoi", "yadox"])
    }

    @Test("目录里只有本 App 自己时列表为空")
    func onlyCurrentAppMeansEmpty() async {
        let json = #"{"products":[{"code":"yadoa","name":{"en":"yado Assets","zh":"芽豆资产"},"status":"coming-soon"}]}"#
        let store = SeriesCatalogStore(fetcher: FakeSeriesFetcher(result: .success(Data(json.utf8))), defaults: makeDefaults())
        await store.refresh()
        #expect(store.products.isEmpty)
    }

    @Test("返回内容不是目录（例如网站返回了错误页）时保留原来的列表，不覆盖缓存")
    func invalidResponseKeepsPreviousCatalog() async {
        let defaults = makeDefaults()
        let fetcher = FakeSeriesFetcher(result: .success(Data(Self.catalogJSON.utf8)))
        let store = SeriesCatalogStore(fetcher: fetcher, defaults: defaults)
        await store.refresh()

        fetcher.result = .success(Data("<html>404</html>".utf8))
        await store.refresh()
        #expect(store.products.map(\.code) == ["yadoi", "yadox"])
        #expect(defaults.data(forKey: SeriesCatalogStore.cacheStorageKey) == Data(Self.catalogJSON.utf8))
    }

    @Test("产品下架后刷新，列表跟着变空")
    func refreshCanEmptyTheList() async {
        let fetcher = FakeSeriesFetcher(result: .success(Data(Self.catalogJSON.utf8)))
        let store = SeriesCatalogStore(fetcher: fetcher, defaults: makeDefaults())
        await store.refresh()
        #expect(!store.products.isEmpty)

        fetcher.result = .success(Data(#"{"products":[]}"#.utf8))
        await store.refresh()
        #expect(store.products.isEmpty)
    }

    // MARK: - 文案

    @Test("入口与列表页的文案都有中英文")
    func stringsAreLocalized() {
        let keys = [
            "series.title",
            "series.intro",
            "series.empty",
            "series.status.comingSoon",
            "series.action.get",
            "series.action.get.accessibility",
            "series.action.learnMore",
            "series.action.learnMore.accessibility",
        ]
        for key in keys {
            #expect(AccountLocalization.string(key, locale: english) != key)
            #expect(AccountLocalization.string(key, locale: simplifiedChinese) != key)
        }
        #expect(AccountLocalization.formatted("series.action.get.accessibility", value: "芽豆有物", locale: simplifiedChinese)
            == "在 App Store 获取芽豆有物")
    }
}

/// 假的目录来源：返回预先设定的数据或错误。
private final class FakeSeriesFetcher: SeriesCatalogFetching {
    /// 下一次拉取的结果。
    var result: Result<Data, Error>

    /// 创建假来源。
    ///
    /// - Parameter result: 拉取时返回的结果。
    init(result: Result<Data, Error>) {
        self.result = result
    }

    func fetchCatalogData() async throws -> Data {
        try result.get()
    }
}
