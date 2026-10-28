import Foundation
import Observation

/// 当前登录账号的 AI 点数：余额、各批点数的过期时刻与每说一句扣的点数，供“我的”入口、AI 点数页和语音记账共用。
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

    /// 语音记账每说一句扣的点数，即默认文本模型的每轮点数；还没取到时为 nil。与账号无关，换账号时保留。
    private(set) var pointsPerTurn: Int?

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

    /// 创建点数状态。
    ///
    /// - Parameters:
    ///   - api: 点数查询接口。
    ///   - currentUserID: 读取当前登录账号 ID 的动作。
    init(api: AIBillingFetching, currentUserID: @escaping () -> String?) {
        self.api = api
        self.currentUserID = currentUserID
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

    /// 余额是否已经不够说一句；还不知道每轮点数时按 1 点判断，余额未知时不算用完。
    var isExhausted: Bool {
        guard let balance else { return false }
        return balance < (pointsPerTurn ?? 1)
    }

    /// 是否正在刷新余额。
    var isRefreshing: Bool {
        refreshRequest != nil
    }

    /// 最早过期、还有剩余的一批点数；没有余额或服务端没有返回批次时为 nil。
    ///
    /// - Parameter now: 当前时间，测试可注入；已到期但还没刷新掉的批次不算。
    /// - Returns: 最近一批要过期的点数。
    func nextExpiringLot(now: Date = .now) -> AICreditLot? {
        guard let balance, balance > 0 else { return nil }
        return lots.first { $0.points > 0 && $0.expiresAt > now }
    }

    /// 从服务端刷新余额；还不知道每轮点数时顺带查一次模型列表。
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
        do {
            let wallet = try await api.fetchWallet()
            guard isCurrentOwner(userID), canApplyWrite(writeToken) else { return }
            noteAppliedWrite(writeToken)
            balance = wallet.balance
            lots = wallet.lots
            failure = nil
        } catch {
            guard isCurrentOwner(userID), canApplyWrite(writeToken) else { return }
            failure = error as? AIBillingAPIError ?? .network
        }

        // 取不到每轮点数时说明文案改用不带数字的说法、是否用完按 1 点判断，不算刷新失败
        if pointsPerTurn == nil, let models = try? await api.fetchModels() {
            pointsPerTurn = models.defaultTextPointsPerTurn
        }
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
                return lot.points > used ? AICreditLot(points: lot.points - used, expiresAt: lot.expiresAt) : nil
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

    /// 清空与账号相关的状态；每轮点数与账号无关，保留。
    private func clearBalance() {
        balance = nil
        lots = []
        failure = nil
        ownerUserID = nil
    }
}
