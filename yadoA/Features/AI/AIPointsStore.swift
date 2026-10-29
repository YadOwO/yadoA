import Foundation
import Observation

/// 当前登录账号的 AI 点数：余额、各批点数的过期时刻、模型档位与每说一句扣的点数，供“我的”入口、AI 点数页和语音记账共用。
///
/// 模型档位（普通、精准）由用户在 AI 点数页选择并保存在本机，与账号无关；每说一句扣的点数取所用档位的点数。
///
/// 余额以服务端为准，只保存在内存里：进入“我的”或 AI 点数页时刷新，语音记账得到响应后用服务端带回的余额就地更新。
/// 余额记着所属账号；刷新和语音回报都核对账号，换账号或退出登录后不会把旧账号的余额记到当前账号上。
/// 余额写入都编号：刷新在发起时取号，语音回报在响应回来时取号，晚到的旧刷新结果不再覆盖更新的余额。
@Observable
final class AIPointsStore {
    /// 进行中的一次刷新及其所属账号。
    private struct RefreshRequest {
        /// 发起刷新时的账号。
        let userID: String

        /// 刷新任务。
        let task: Task<Void, Never>
    }

    /// 当前余额；未登录或还没取到时为 nil。
    private(set) var balance: Int?

    /// 各批未过期的点数，按过期时刻从早到晚；服务端没有返回时为空。
    private(set) var lots: [AICreditLot] = []

    /// 服务端的模型档位列表；还没取到时为 nil。与账号无关，换账号时保留。
    private(set) var tierList: AIModelTierList?

    /// 用户在本机选的模型档位；没选过时为 nil，跟随服务端的默认档位。与账号无关，换账号时保留。
    private(set) var selectedTier: AIModelTier?

    /// 最近一次刷新余额失败的原因；刷新成功后清空。
    private(set) var failure: AIBillingAPIError?

    /// 进行中的刷新；同一账号同时发起的刷新共用这一次请求，换了账号则另起一次。
    private var refreshRequest: RefreshRequest?

    /// 当前余额所属的账号；与当前登录账号不一致时先清空再刷新。
    private var ownerUserID: String?

    /// 下一次余额写入的序号；刷新发起时、语音回报写入时各取一个。
    private var nextWriteToken = 0

    /// 最近一次成功写入余额的序号；更早的结果晚到时丢弃。
    private var appliedWriteToken = 0

    /// 点数查询接口。
    private let api: AIBillingFetching

    /// 读取当前登录账号 ID 的动作；未登录时返回 nil。
    private let currentUserID: () -> String?

    /// 保存所选模型档位的本机偏好。
    private let defaults: UserDefaults

    /// 创建点数状态。
    ///
    /// - Parameters:
    ///   - api: 点数查询接口。
    ///   - defaults: 保存所选模型档位的本机偏好；测试传入独立的存储。
    ///   - currentUserID: 读取当前登录账号 ID 的动作。
    init(api: AIBillingFetching, defaults: UserDefaults = .standard, currentUserID: @escaping () -> String?) {
        self.api = api
        self.defaults = defaults
        self.currentUserID = currentUserID
        selectedTier = defaults.string(forKey: AIModelTier.storageKey).flatMap(AIModelTier.init(rawValue:))
    }

    /// 用登录状态创建：凭证取自 AI 服务的 access token，账号取 Logto 用户 ID。
    ///
    /// - Parameter authStore: 全局登录状态。
    convenience init(authStore: AuthStore) {
        self.init(
            api: AIBillingAPI { try await authStore.accessTokenForAIService() },
            currentUserID: { authStore.userID }
        )
    }

    /// 语音记账请求带的档位：用户选过且服务端仍可用时为所选档位；没选过、或所选档位服务端已不提供时为 nil，
    /// 不带档位请求头，由服务端按默认档位处理。还没取到档位列表时先按所选档位发送。
    var requestTier: AIModelTier? {
        guard let selectedTier else { return nil }
        guard let tierList else { return selectedTier }
        return tierList.selectableTiers.contains(selectedTier) ? selectedTier : nil
    }

    /// 界面上勾选的档位：实际使用的档位；跟随服务端默认档位时为默认档位，客户端不认识默认档位时为 nil。
    var displayTier: AIModelTier? {
        requestTier ?? tierList.flatMap { AIModelTier(rawValue: $0.defaultTier) }
    }

    /// 语音记账每说一句扣的点数，即实际使用档位的每轮点数；还没取到档位列表时为 nil。
    var pointsPerTurn: Int? {
        guard let tierList else { return nil }
        return tierList.pointsPerTurn(for: requestTier?.rawValue ?? tierList.defaultTier)
    }

    /// 选择模型档位并保存在本机；从下一句话开始生效，正在处理的一句沿用开始时的档位。
    ///
    /// - Parameter tier: 用户选的档位。
    func selectTier(_ tier: AIModelTier) {
        selectedTier = tier
        defaults.set(tier.rawValue, forKey: AIModelTier.storageKey)
    }

    /// 余额是否已经不够说一句；还不知道每轮点数时按 1 点判断，余额未知时不算用完。
    var isExhausted: Bool {
        guard let balance else { return false }
        return balance < (pointsPerTurn ?? 1)
    }

    /// 余额不够所用档位说一句，但够换用扣点更少的可选档位：此时点数并没有用完，界面提示切换档位。
    var canAffordCheaperTier: Bool {
        guard isExhausted, let balance, let tierList else { return false }
        return tierList.selectableTiers.contains { tier in
            tierList.pointsPerTurn(for: tier.rawValue).map { $0 <= balance } ?? false
        }
    }

    /// 按当前余额用某个档位还能说几句，供模型选择页比较各档位；追问的回答也算一句。
    ///
    /// - Parameter tier: 档位。
    /// - Returns: 余额能覆盖的句数，不够一句时为 0；余额或该档位点数未知、或该档位不扣点时为 nil。
    func turnsLeft(for tier: AIModelTier) -> Int? {
        guard let balance, let pointsPerTurn = tierList?.pointsPerTurn(for: tier.rawValue), pointsPerTurn > 0 else {
            return nil
        }
        return max(balance, 0) / pointsPerTurn
    }

    /// 是否正在刷新余额。
    var isRefreshing: Bool {
        refreshRequest != nil
    }

    /// 还有剩余、尚未到期的各批点数，按过期时间从早到晚；没有余额或服务端没有返回批次时为空。
    ///
    /// - Parameter now: 当前时间，测试可注入；已到期但还没刷新掉的批次不算。
    /// - Returns: 未过期的批次。
    func activeLots(now: Date = .now) -> [AICreditLot] {
        guard let balance, balance > 0 else { return [] }
        return lots.filter { $0.points > 0 && $0.expiresAt > now }
    }

    /// 最早过期、还有剩余的一批点数；没有余额或服务端没有返回批次时为 nil。
    ///
    /// - Parameter now: 当前时间，测试可注入；已到期但还没刷新掉的批次不算。
    /// - Returns: 最近一批要过期的点数。
    func nextExpiringLot(now: Date = .now) -> AICreditLot? {
        activeLots(now: now).first
    }

    /// 从服务端刷新余额，同时重新查模型档位列表。
    ///
    /// 未登录时立即清空余额。同一账号正在刷新时等这一次结束，不重复请求：从“我的”快速点进 AI 点数页时，
    /// 明细要等钱包建好（含新用户赠送）再查。正在刷新的是别的账号时另起一次，旧账号的结果回来后丢弃。
    func refresh() async {
        guard let userID = currentUserID() else {
            clearBalance()
            return
        }
        adopt(userID)
        if let refreshRequest, refreshRequest.userID == userID {
            await refreshRequest.task.value
            return
        }
        let writeToken = beginWrite()
        let task = Task { await performRefresh(for: userID, writeToken: writeToken) }
        refreshRequest = RefreshRequest(userID: userID, task: task)
        await task.value
        // 等待期间可能已为另一个账号另起刷新，只清掉自己这一次
        if refreshRequest?.task == task {
            refreshRequest = nil
        }
    }

    /// 为一次 AI 请求准备余额回报：记下发起请求时的账号，响应回来时已换账号或已退出登录就丢弃。
    ///
    /// 写入序号在响应回来时才取：服务端在一轮快结束时才结算扣点（点数不足的 402 也是当场查的余额），
    /// 带回的余额比请求期间发起的刷新读到的更新；按请求发起时取号，会被期间完成的刷新压住，显示扣点前的旧余额。
    ///
    /// - Returns: 用服务端带回的余额（扣点后的响应头，或点数不足时错误详情里的余额）就地更新的动作。
    func balanceReporter() -> (Int) -> Void {
        guard let requestUserID = currentUserID() else { return { _ in } }
        return { [weak self] newBalance in
            guard let self, self.currentUserID() == requestUserID else { return }
            self.adopt(requestUserID)
            self.noteAppliedWrite(self.beginWrite())
            self.applyReportedBalance(newBalance)
        }
    }

    /// 创建与本状态共用接口的流水分页，供 AI 点数页使用。
    ///
    /// - Returns: 新的流水分页，尚未加载。
    func makeEntryFeed() -> AICreditEntryFeed {
        AICreditEntryFeed(api: api)
    }

    /// 实际执行一次刷新：失败时保留已有余额并记下原因；等待期间换了账号、退出登录，或已有更新的余额写入时丢弃结果。
    ///
    /// - Parameters:
    ///   - userID: 发起刷新时的账号。
    ///   - writeToken: 这次刷新的写入序号。
    private func performRefresh(for userID: String, writeToken: Int) async {
        // 档位列表不调用模型、不扣点，每次都重新查，服务端停用或恢复档位后跟着更新；与余额并行，不拖慢明细加载
        async let latestTierList = fetchTierList()
        do {
            let wallet = try await api.fetchWallet()
            if isCurrentOwner(userID), canApplyWrite(writeToken) {
                noteAppliedWrite(writeToken)
                balance = wallet.balance
                lots = wallet.lots
                failure = nil
            }
        } catch {
            if isCurrentOwner(userID), canApplyWrite(writeToken) {
                failure = error as? AIBillingAPIError ?? .network
            }
        }

        // 这次没取到时沿用上次的档位列表；从没取到过时不显示档位选择，说明文案改用不带数字的说法、是否用完按 1 点判断，不算刷新失败
        if let tiers = await latestTierList {
            tierList = tiers
        }
    }

    /// 查询模型档位列表。
    ///
    /// - Returns: 档位列表；查询失败时为 nil。
    private func fetchTierList() async -> AIModelTierList? {
        try? await api.fetchModelTiers()
    }

    /// 用语音记账带回的余额更新；余额减少时按服务端“先用最早过期的”规则同步扣减各批点数，下次刷新再以服务端为准。
    ///
    /// - Parameter newBalance: 服务端结算后的余额。
    private func applyReportedBalance(_ newBalance: Int) {
        if let balance, newBalance < balance {
            var remaining = balance - newBalance
            lots = lots.compactMap { lot in
                guard remaining > 0 else { return lot }
                let used = min(lot.points, remaining)
                remaining -= used
                return lot.points > used ? lot.withPoints(lot.points - used) : nil
            }
        }
        balance = newBalance
        failure = nil
    }

    /// 余额是否仍属于这个账号，且它仍是当前登录账号。
    ///
    /// - Parameter userID: 发起请求时的账号。
    private func isCurrentOwner(_ userID: String) -> Bool {
        ownerUserID == userID && currentUserID() == userID
    }

    /// 登记一次即将写入余额的操作。
    ///
    /// - Returns: 本次写入的序号，比之前的都大。
    private func beginWrite() -> Int {
        nextWriteToken += 1
        return nextWriteToken
    }

    /// 这次写入是否还能覆盖当前余额。
    ///
    /// - Parameter token: `beginWrite()` 返回的序号。
    /// - Returns: 没有更新的写入已经生效时为 true。
    private func canApplyWrite(_ token: Int) -> Bool {
        token >= appliedWriteToken
    }

    /// 记下这次写入已生效。
    ///
    /// - Parameter token: 已生效的写入序号。
    private func noteAppliedWrite(_ token: Int) {
        appliedWriteToken = token
    }

    /// 切到指定账号；与当前余额所属账号不同时先清空旧余额。
    ///
    /// - Parameter userID: 当前登录账号 ID。
    private func adopt(_ userID: String) {
        guard ownerUserID != userID else { return }
        clearBalance()
        ownerUserID = userID
    }

    /// 清空与账号相关的状态；模型档位列表与所选档位与账号无关，保留。
    private func clearBalance() {
        balance = nil
        lots = []
        failure = nil
        ownerUserID = nil
    }
}
