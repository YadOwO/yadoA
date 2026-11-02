import Foundation
import Observation

/// AI 点数页的流水分页：进入页面加载第一页，用户点“查看更早的记录”时按游标加载下一页。
///
/// 流水只在页面打开期间保存在内存里，不做缓存；下拉刷新时从第一页重新加载。
@Observable
final class AICreditEntryFeed {
    /// 要加载的一页。
    private enum Page: Equatable {
        /// 第一页，加载后替换已有列表。
        case first

        /// 某个游标之后的一页，加载后追加。
        case after(String)

        /// 请求用的游标；第一页为 nil。
        var cursor: String? {
            switch self {
            case .first: nil
            case let .after(cursor): cursor
            }
        }
    }

    /// 已加载的流水，按时间倒序。
    private(set) var entries: [AICreditEntry] = []

    /// 是否已成功加载过第一页；用于区分“还没加载”和“确实没有流水”。
    private(set) var hasLoaded = false

    /// 是否正在加载第一页或下一页。
    private(set) var isLoading = false

    /// 最近一次加载失败的原因；重新加载成功后清空。
    private(set) var failure: AIBillingAPIError?

    /// 下一页的游标；没有更多时为 nil。
    private var nextCursor: String?

    /// 最近一次加载失败的那一页，重试时原样再加载；没有失败时为 nil。
    private var failedPage: Page?

    /// 加载代次：每次重新加载第一页时加一，晚到的旧请求结果按代次丢弃。
    private var generation = 0

    /// 点数查询接口。
    private let api: AIBillingFetching

    /// 创建流水分页。
    ///
    /// - Parameter api: 点数查询接口。
    init(api: AIBillingFetching) {
        self.api = api
    }

    /// 是否还有下一页可加载。
    var hasMore: Bool {
        hasLoaded && nextCursor != nil
    }

    /// 从第一页重新加载；进行中的下一页请求结果会被丢弃。失败时保留已加载的流水并记下原因。
    func reload() async {
        generation += 1
        await load(.first, generation: generation)
    }

    /// 加载下一页；没有更多、正在加载或有未处理的失败时不发请求，失败后由用户点重试。
    func loadMore() async {
        guard hasLoaded, let nextCursor, !isLoading, failure == nil else { return }
        await load(.after(nextCursor), generation: generation)
    }

    /// 重试失败的那一页：第一页（含下拉刷新）失败时重新加载第一页，下一页失败时再加载那一页。
    func retry() async {
        guard let failedPage, !isLoading else { return }
        switch failedPage {
        case .first:
            await reload()
        case .after:
            await load(failedPage, generation: generation)
        }
    }

    /// 加载一页并合并到列表。
    ///
    /// - Parameters:
    ///   - page: 要加载的页；第一页替换已有列表，其余追加。
    ///   - generation: 发起请求时的加载代次。
    private func load(_ page: Page, generation requestGeneration: Int) async {
        isLoading = true
        do {
            let result = try await api.fetchEntries(cursor: page.cursor)
            guard requestGeneration == generation else { return }
            if page == .first {
                entries = result.entries
            } else {
                // 两页之间有新流水时服务端按游标取更旧的部分，不会重复；这里仍按 ID 去重兜底
                let loadedIDs = Set(entries.map(\.id))
                entries.append(contentsOf: result.entries.filter { !loadedIDs.contains($0.id) })
            }
            nextCursor = result.nextCursor
            hasLoaded = true
            failure = nil
            failedPage = nil
        } catch {
            guard requestGeneration == generation else { return }
            failure = error as? AIBillingAPIError ?? .network
            failedPage = page
        }
        isLoading = false
    }
}
