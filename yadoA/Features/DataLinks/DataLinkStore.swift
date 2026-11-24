import Foundation
import Observation

/// 数据联动的状态：hub 打开了哪些联动、用户是否授权、最近一次的物品购入价汇总，以及三个估值设置。
///
/// 是否授权以 hub 为准，只在内存里记最近一次成功的 `GET /v1/links`，不往本机写授权；
/// 冷启动还没拉到、离线或没登录时 `links` 里没有芽豆有物，任何联动入口、账户页那一行都不出现，估值也不计入净资产。
/// 汇总（带本机保存时间）和设置按 Logto 用户 ID 存在 UserDefaults，换账号互不串；估值不落 SwiftData，不是 `Account`。
/// 每次 await 回来都要核对账号还是不是发起时的那个，旧账号晚到的结果直接丢掉；
/// 授权列表的写入编号：刷新在发起时取号，授权、取消授权在结果回来时取号，晚到的旧刷新结果不再覆盖更新的状态。
@Observable
final class DataLinkStore {
    /// 汇总的新鲜时长：本机缓存保存不到这么久就不再向服务端要。
    static let summaryFreshness: TimeInterval = 5 * 60

    /// 最近一次成功拉到的联动列表；nil 表示还不知道。只在内存里，刷新失败时保留原值。
    private(set) var links: [DataLinkStatus]?

    /// 最近一次取汇总失败的原因；成功、换账号、取消授权后清空。服务端说没授权或来源没开不算失败，直接改 `links`。
    private(set) var lastSummaryFailure: DataLinkAPIError?

    /// 本机缓存（汇总、设置）每次写入后加一：UserDefaults 本身不可观察，界面靠它重新读取。
    private var cacheRevision = 0

    /// 正在取汇总的请求数。
    private var summaryRequestsInFlight = 0

    /// 当前 `links` 所属的账号。
    private var ownerUserID: String?

    /// 下一次授权列表写入的序号。
    private var nextLinksWriteToken = 0

    /// 最近一次生效的授权列表写入序号；更早的结果晚到时丢弃。
    private var appliedLinksWriteToken = 0

    /// 数据联动接口。
    private let api: DataLinkServing

    /// 读取当前登录账号 ID 的动作；未登录时返回 nil。
    private let currentUserID: () -> String?

    /// 当前是否允许联网：中国大陆地区同意隐私政策之前为 false，此时不发请求，也没有任何联动入口。
    private let isNetworkAllowed: () -> Bool

    /// 保存汇总缓存和设置的本机存储；测试传入独立的存储。
    private let defaults: UserDefaults

    /// 当前时间；测试可固定，用来验证 5 分钟节流。
    private let now: () -> Date

    /// 创建联动状态。
    ///
    /// - Parameters:
    ///   - api: 数据联动接口。
    ///   - currentUserID: 读取当前登录账号 ID 的动作。
    ///   - isNetworkAllowed: 查询当前是否允许联网的动作，默认恒为允许。
    ///   - defaults: 保存汇总缓存和设置的本机存储。
    ///   - now: 读取当前时间的动作。
    init(
        api: DataLinkServing,
        currentUserID: @escaping () -> String?,
        isNetworkAllowed: @escaping () -> Bool = { true },
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = { Date() }
    ) {
        self.api = api
        self.currentUserID = currentUserID
        self.isNetworkAllowed = isNetworkAllowed
        self.defaults = defaults
        self.now = now
    }

    /// 用登录状态创建：凭证取自公共服务的 access token，账号取 Logto 用户 ID。
    ///
    /// - Parameters:
    ///   - authStore: 全局登录状态。
    ///   - isNetworkAllowed: 查询当前是否允许联网的动作，默认恒为允许。
    convenience init(authStore: AuthStore, isNetworkAllowed: @escaping () -> Bool = { true }) {
        self.init(
            api: DataLinkAPI(authStore: authStore),
            currentUserID: { authStore.userID },
            isNetworkAllowed: isNetworkAllowed
        )
    }

    // MARK: - 本机存储的键

    /// 某个用户的汇总缓存在 UserDefaults 里的键。
    ///
    /// - Parameter userID: Logto 用户 ID。
    static func summaryKey(userID: String) -> String {
        "dataLink.yadoi.itemValue.summary.\(userID)"
    }

    /// 某个用户的估值设置在 UserDefaults 里的键。
    ///
    /// - Parameter userID: Logto 用户 ID。
    static func settingsKey(userID: String) -> String {
        "dataLink.yadoi.itemValue.settings.\(userID)"
    }

    /// 本机保存的汇总：汇总本身加上本机保存它的时刻，节流以保存时刻为准。
    private nonisolated struct CachedSummary: Codable {
        /// 汇总。
        let summary: ItemValueSummary

        /// 本机保存的时刻。
        let savedAt: Date
    }

    // MARK: - 状态

    /// 联动是否可用：已登录、允许联网，并且最近一次成功拉到的列表里有芽豆有物。
    ///
    /// 列表属于别的账号时（刚换了账号还没刷新）按不可用处理。
    var isItemValueLinkAvailable: Bool {
        guard isNetworkAllowed(), let userID = currentUserID(), ownerUserID == userID else { return false }
        return itemValueLink != nil
    }

    /// 联动可用并且用户已授权。
    var isItemValueGranted: Bool {
        isItemValueLinkAvailable && itemValueLink?.granted == true
    }

    /// 当前账号的估值设置；没存过时是默认值。写入时折扣夹进范围并对齐到步长，没登录时忽略。
    var settings: ItemValuationSettings {
        get {
            _ = cacheRevision
            guard let userID = currentUserID(),
                  let data = defaults.data(forKey: Self.settingsKey(userID: userID)),
                  let stored = try? JSONDecoder().decode(ItemValuationSettings.self, from: data)
            else { return ItemValuationSettings() }
            return stored
        }
        set {
            guard let userID = currentUserID() else { return }
            let normalized = ItemValuationSettings(
                showsOnAccounts: newValue.showsOnAccounts,
                countsInNetWorth: newValue.countsInNetWorth,
                discountPercent: newValue.discountPercent
            )
            guard let data = try? JSONEncoder().encode(normalized) else { return }
            defaults.set(data, forKey: Self.settingsKey(userID: userID))
            cacheRevision += 1
        }
    }

    /// 当前账号本机缓存的汇总；没有缓存、没登录或缓存读不出来时为 nil。
    var cachedSummary: ItemValueSummary? {
        cachedRecord?.summary
    }

    /// 正在向服务端取汇总。
    var isRefreshingSummary: Bool {
        summaryRequestsInFlight > 0
    }

    /// 芽豆有物联动在界面上的状态。
    var linkState: ItemValueLinkState {
        ItemValueLinkState.state(isGranted: isItemValueGranted, summary: cachedSummary)
    }

    /// 账户页那一行和汇总用的估值金额：已授权、有汇总、至少有一件填了购入价才有值，否则为 nil。
    var accountValuation: Decimal? {
        guard isItemValueGranted, let summary = cachedSummary, summary.pricedItemCount > 0 else { return nil }
        return ItemValuation.amount(summary: summary, discountPercent: settings.discountPercent)
    }

    /// 账户页是否显示「物品估值」那一行：有估值，并且打开了「显示在账户页」。
    var showsAccountRow: Bool {
        accountValuation != nil && settings.showsOnAccounts
    }

    /// 要计入汇总卡片和资产分析的估值：有估值，并且打开了「计入净资产」；否则为 nil。
    var netWorthValuation: Decimal? {
        guard let valuation = accountValuation, settings.countsInNetWorth else { return nil }
        return valuation
    }

    // MARK: - 刷新

    /// 从 hub 刷新联动列表；不允许联网时什么都不做，没登录时清空内存；失败时保留原值。
    ///
    /// 成功后，如果芽豆有物已不在列表里或显示未授权，清掉当前账号的汇总缓存。
    func refreshLinks() async {
        guard isNetworkAllowed() else { return }
        guard let userID = currentUserID() else {
            clear()
            return
        }
        adopt(userID)
        let token = beginLinksWrite()
        guard let list = try? await api.fetchLinks() else { return }
        guard isCurrent(userID), token >= appliedLinksWriteToken else { return }
        appliedLinksWriteToken = token
        links = list.links
        if itemValueLink?.granted != true {
            removeSummaryCache(for: userID)
        }
    }

    /// 已授权时向 hub 取最新的汇总，写入本机缓存。
    ///
    /// 缓存保存不到 5 分钟且没有 `force` 时不拉；账户页出现和下拉刷新都走这里，节流由这里负责。
    /// 服务端说没授权时把内存里的芽豆有物改成未授权并清缓存，说来源没开时把它从列表里去掉并清缓存；
    /// 其他失败保留缓存，只记下原因。
    ///
    /// - Parameter force: 为 true 时不看缓存的新鲜度，授权成功后立即拉一次用它。
    func refreshItemValueIfStale(force: Bool = false) async {
        guard isItemValueGranted, let userID = currentUserID() else { return }
        if !force, let record = cachedRecord {
            let age = now().timeIntervalSince(record.savedAt)
            // 本机时间被往回调过时 age 为负，按过期处理，不让缓存永远不刷新
            if age >= 0, age < Self.summaryFreshness { return }
        }
        let linksToken = appliedLinksWriteToken
        summaryRequestsInFlight += 1
        defer { summaryRequestsInFlight -= 1 }
        do {
            let summary = try await api.fetchItemValueSummary()
            // 等待期间可能换了账号、取消了授权：这时结果不能再写进缓存
            guard isCurrent(userID), isItemValueGranted else { return }
            saveSummary(summary, for: userID)
            lastSummaryFailure = nil
        } catch {
            // 页面消失、任务被取消时请求会以失败收场，这不是服务的问题，不记成失败
            guard !Task.isCancelled, isCurrent(userID) else { return }
            let failure = error as? DataLinkAPIError ?? .network
            switch failure {
            case .notGranted, .unavailable:
                // 等待期间授权列表被更新过（刚授权、取消或刷新），这个结果可能是旧的，下次刷新再对
                guard appliedLinksWriteToken == linksToken else { return }
                if failure == .notGranted {
                    markItemValueNotGranted()
                } else {
                    removeItemValueLink()
                }
                removeSummaryCache(for: userID)
                lastSummaryFailure = nil
            default:
                lastSummaryFailure = failure
            }
        }
    }

    // MARK: - 授权与取消

    /// 授权：调 PUT，成功后更新授权状态并立即拉一次汇总。
    ///
    /// - Returns: 授权成功为 `.success`；失败时带原因，服务端说来源没开时同时把它从列表里去掉。
    func grant() async -> Result<Void, DataLinkAPIError> {
        guard isNetworkAllowed() else { return .failure(.network) }
        guard let userID = currentUserID() else { return .failure(.notSignedIn) }
        adopt(userID)
        do {
            let status = try await api.grantItemValue()
            guard isCurrent(userID) else { return .failure(.sessionExpired) }
            applyItemValueLink(status)
        } catch {
            let failure = error as? DataLinkAPIError ?? .network
            if failure == .unavailable, isCurrent(userID) {
                removeItemValueLink()
            }
            return .failure(failure)
        }
        await refreshItemValueIfStale(force: true)
        return .success(())
    }

    /// 取消授权：调 DELETE，成功后更新授权状态并清掉这个账号的汇总缓存；服务端没有这条授权时同样返回成功。
    ///
    /// - Returns: 取消成功为 `.success`；失败时带原因，授权状态和缓存保持原样。
    func revoke() async -> Result<Void, DataLinkAPIError> {
        guard isNetworkAllowed() else { return .failure(.network) }
        guard let userID = currentUserID() else { return .failure(.notSignedIn) }
        adopt(userID)
        do {
            let status = try await api.revokeItemValue()
            guard isCurrent(userID) else { return .failure(.sessionExpired) }
            applyItemValueLink(status)
            removeSummaryCache(for: userID)
            lastSummaryFailure = nil
            return .success(())
        } catch {
            return .failure(error as? DataLinkAPIError ?? .network)
        }
    }

    // MARK: - 清理

    /// 退出登录时调用：清掉当前账号的汇总缓存，设置保留，下次登录同一个账号还在。
    ///
    /// 必须在 `AuthStore.signOut()` 之前调，之后就取不到账号 ID 了。
    func clearCurrentUserCache() {
        guard let userID = currentUserID() else { return }
        removeSummaryCache(for: userID)
    }

    /// 注销账号时调用：清掉当前账号的汇总缓存和设置。
    ///
    /// 必须在 `AuthStore.signOut()` 之前调；服务端的授权记录已由 hub 在注销时一并删除。
    func forgetCurrentUser() {
        guard let userID = currentUserID() else { return }
        removeSummaryCache(for: userID)
        defaults.removeObject(forKey: Self.settingsKey(userID: userID))
        cacheRevision += 1
    }

    // MARK: - 内部

    /// 列表里芽豆有物那一项。
    private var itemValueLink: DataLinkStatus? {
        links?.first { $0.source == DataLinkCode.source }
    }

    /// 当前账号本机保存的汇总缓存。
    private var cachedRecord: CachedSummary? {
        _ = cacheRevision
        guard let userID = currentUserID(),
              let data = defaults.data(forKey: Self.summaryKey(userID: userID))
        else { return nil }
        return try? JSONDecoder().decode(CachedSummary.self, from: data)
    }

    /// 这个账号现在还是当前登录的账号，并且内存里的状态属于它。
    ///
    /// - Parameter userID: 发起请求时的账号。
    private func isCurrent(_ userID: String) -> Bool {
        currentUserID() == userID && ownerUserID == userID
    }

    /// 登记一次即将写入授权列表的操作。
    ///
    /// - Returns: 本次写入的序号，比之前的都大。
    private func beginLinksWrite() -> Int {
        nextLinksWriteToken += 1
        return nextLinksWriteToken
    }

    /// 切到指定账号；与内存状态所属账号不同时先清空内存。
    ///
    /// - Parameter userID: 当前登录账号 ID。
    private func adopt(_ userID: String) {
        guard ownerUserID != userID else { return }
        clear()
        ownerUserID = userID
    }

    /// 清空内存里的状态并解除账号归属；本机缓存按账号存放，不在这里动。
    private func clear() {
        links = nil
        lastSummaryFailure = nil
        ownerUserID = nil
    }

    /// 把授权、取消授权返回的状态记进列表，并让更早发起的列表刷新结果作废。
    ///
    /// - Parameter status: 服务端返回的芽豆有物联动状态。
    private func applyItemValueLink(_ status: DataLinkStatus) {
        appliedLinksWriteToken = beginLinksWrite()
        var updated = (links ?? []).filter { $0.source != status.source }
        updated.append(status)
        links = updated
    }

    /// 把内存里的芽豆有物改成未授权。
    private func markItemValueNotGranted() {
        links = links?.map { link in
            guard link.source == DataLinkCode.source else { return link }
            return DataLinkStatus(
                source: link.source,
                target: link.target,
                scope: link.scope,
                granted: false,
                grantedAt: nil
            )
        }
    }

    /// 把芽豆有物从内存的列表里去掉。
    private func removeItemValueLink() {
        links = links?.filter { $0.source != DataLinkCode.source }
    }

    /// 写入汇总缓存，保存时刻取当前时间。
    ///
    /// - Parameters:
    ///   - summary: 刚取到的汇总。
    ///   - userID: 缓存所属账号。
    private func saveSummary(_ summary: ItemValueSummary, for userID: String) {
        guard let data = try? JSONEncoder().encode(CachedSummary(summary: summary, savedAt: now())) else { return }
        defaults.set(data, forKey: Self.summaryKey(userID: userID))
        cacheRevision += 1
    }

    /// 清掉某个账号的汇总缓存。
    ///
    /// - Parameter userID: 缓存所属账号。
    private func removeSummaryCache(for userID: String) {
        defaults.removeObject(forKey: Self.summaryKey(userID: userID))
        cacheRevision += 1
    }
}
