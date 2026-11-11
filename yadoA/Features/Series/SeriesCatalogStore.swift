import Foundation
import Observation

/// 取产品目录原始数据的来源；测试注入假实现。
protocol SeriesCatalogFetching {
    /// 取回目录的 JSON 数据。
    ///
    /// - Returns: 未解码的响应体。
    /// - Throws: 网络失败或状态码不是 2xx。
    func fetchCatalogData() async throws -> Data
}

/// 从 yado_run 网站拉产品目录；公开的静态文件，不带登录凭证，也不带任何用户信息。
struct SeriesCatalogAPI: SeriesCatalogFetching {
    /// 目录地址。
    var endpoint: URL = SeriesCatalog.endpoint
    /// 发请求用的会话。
    var session: URLSession = .shared

    func fetchCatalogData() async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

/// 「更多芽豆产品」的目录状态，「我的」页入口和列表页共用。
///
/// 上次成功拉到的目录原样存在本机：启动时先用它，所以入口不会等网络才出现，断网也能看列表；
/// 进入「我的」时刷新一次，失败或内容不合契约时保留原来的目录。没有可展示的产品时入口整行不显示。
@Observable
final class SeriesCatalogStore {
    /// 目录缓存的存储键，存的是接口返回的原始 JSON。
    static let cacheStorageKey = "series.catalog.cache"

    /// 要展示的产品（已去掉本 App 自己）；还没拉到过目录时为空。
    private(set) var products: [SeriesProduct]

    /// 目录来源。
    private let fetcher: SeriesCatalogFetching

    /// 存放目录缓存的设置。
    private let defaults: UserDefaults

    /// 创建目录状态，并读出本机缓存的目录。
    ///
    /// - Parameters:
    ///   - fetcher: 目录来源，默认从网站拉取。
    ///   - defaults: 存放目录缓存的设置。
    init(fetcher: SeriesCatalogFetching = SeriesCatalogAPI(), defaults: UserDefaults = .standard) {
        self.fetcher = fetcher
        self.defaults = defaults
        products = defaults.data(forKey: Self.cacheStorageKey)
            .flatMap(Self.decode)?
            .otherProducts ?? []
    }

    /// 从网站刷新目录；成功后更新列表并覆盖本机缓存，失败或解码不出来时保持原样。
    func refresh() async {
        guard let data = try? await fetcher.fetchCatalogData(), let catalog = Self.decode(data) else { return }
        defaults.set(data, forKey: Self.cacheStorageKey)
        products = catalog.otherProducts
    }

    /// 解码目录；不合契约时返回 nil。
    ///
    /// - Parameter data: 接口返回或本机缓存的 JSON。
    /// - Returns: 解码出的目录。
    private static func decode(_ data: Data) -> SeriesCatalog? {
        try? JSONDecoder().decode(SeriesCatalog.self, from: data)
    }
}
