import Foundation
import Observation

/// 当前登录账号的 AI 点数：余额、各批点数的过期时刻、模型档位与每说一句扣的点数，供“我的”入口、AI 点数页和语音记账共用。
///
/// 模型档位（普通、精准）快捷语音和 AI 对话各选各的（见 `AIModelScope`），保存在本机，与账号无关；
/// 没选过时默认用精准（`AIModelTier.appDefault`）。每说一句扣的点数取这句所用档位的点数。
///
/// 余额以服务端为准，只保存在内存里：进入“我的”或 AI 点数页时刷新，语音记账得到响应后用服务端带回的余额就地更新。
/// 余额记着所属账号；刷新和语音回报都核对账号，换账号或退出登录后不会把旧账号的余额记到当前账号上。
/// 每日签到的状态也在这里：进入“我的”或签到页时刷新，签到、打开礼包成功后直接用服务端返回的余额和批次更新，不再多发请求。
/// 签到状态里带着当前连签天数和还没开完的礼包；签到日历按月现查，不存在这里。
/// 签到引导（第一次在“我的”看到签到气泡时的说明）是否看过，按账号保存在本机。
/// 余额写入都编号：刷新在发起时取号，语音回报在响应回来时取号，晚到的旧刷新结果不再覆盖更新的余额。
///
/// “AI 记账说明”的同意状态也按账号保存在本机（见 `isAIProcessingConsented`），没同意的账号不能把内容发给 AI；
/// 它与“帮助改进 AI”互不影响，换账号和退出登录时都保留。
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

    /// 用户在本机为各入口选的模型档位；没选过的入口不在其中，用本 App 的默认档位（精准）。与账号无关，换账号时保留。
    private(set) var selectedTiers: [AIModelScope: AIModelTier]

    /// 在本机授权过“帮助改进 AI”的账号。按账号保存：同一台设备换账号时，新账号不能继承别人的授权。
    private var traceConsentedUserIDs: Set<String>

    /// 在本机同意过“AI 记账说明”的账号。按账号保存：同一台设备换账号时，新账号要重新同意。
    private var aiProcessingConsentedUserIDs: Set<String>

    /// 签到状态；未登录或还没拿到时为 nil。刷新失败时保留上一次拿到的，签到页不会因为一次网络抖动整页清空。
    private(set) var checkInStatus: AICheckInStatus?

    /// 是否正在签到；用来拦住重复点击。
    private(set) var isCheckingIn = false

    /// 是否正在打开礼包；用来拦住重复点击，免得年度礼包一次点击开掉两次。
    private(set) var isOpeningGift = false

    /// 在本机看过签到引导的账号。按账号保存：换个账号登录，第一次看到签到气泡时再说明一次。
    private var checkInGuideShownUserIDs: Set<String>

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

    /// 当前环境是否提供“帮助改进 AI”，为 false 时一律视为未授权。
    private let isTraceConsentAvailable: Bool

    /// 当前是否允许联网：中国大陆地区同意隐私政策之前为 false，此时刷新直接返回，不发请求。
    private let isNetworkAllowed: () -> Bool

    /// 创建点数状态。
    ///
    /// - Parameters:
    ///   - api: 点数查询接口。
    ///   - defaults: 保存所选模型档位的本机偏好；测试传入独立的存储。
    ///   - isTraceConsentAvailable: 当前环境是否提供“帮助改进 AI”，默认取 `AuthConfig`，测试可以传 false 模拟线上包。
    ///   - currentUserID: 读取当前登录账号 ID 的动作。
    ///   - isNetworkAllowed: 查询当前是否允许联网的动作，默认恒为允许。
    init(
        api: AIBillingFetching,
        defaults: UserDefaults = .standard,
        isTraceConsentAvailable: Bool = AuthConfig.isAITraceConsentAvailable,
        currentUserID: @escaping () -> String?,
        isNetworkAllowed: @escaping () -> Bool = { true }
    ) {
        self.api = api
        self.defaults = defaults
        self.isTraceConsentAvailable = isTraceConsentAvailable
        self.currentUserID = currentUserID
        self.isNetworkAllowed = isNetworkAllowed
        selectedTiers = AIModelScope.allCases.reduce(into: [:]) { result, scope in
            result[scope] = defaults.string(forKey: scope.storageKey).flatMap(AIModelTier.init(rawValue:))
        }
        traceConsentedUserIDs = Set(defaults.stringArray(forKey: Self.traceConsentStorageKey) ?? [])
        aiProcessingConsentedUserIDs = Set(defaults.stringArray(forKey: Self.aiProcessingConsentStorageKey) ?? [])
        checkInGuideShownUserIDs = Set(defaults.stringArray(forKey: Self.checkInGuideStorageKey) ?? [])
    }

    /// 用登录状态创建：凭证取自 AI 服务的 access token，账号取 Logto 用户 ID。
    ///
    /// - Parameters:
    ///   - authStore: 全局登录状态。
    ///   - isNetworkAllowed: 查询当前是否允许联网的动作，默认恒为允许。
    convenience init(authStore: AuthStore, isNetworkAllowed: @escaping () -> Bool = { true }) {
        self.init(
            api: AIBillingAPI { try await authStore.accessTokenForAIService() },
            currentUserID: { authStore.userID },
            isNetworkAllowed: isNetworkAllowed
        )
    }

    /// 用户为某个入口选的档位，不管服务端是否还提供。
    ///
    /// - Parameter scope: 入口。
    /// - Returns: 所选档位；没选过时为 nil。
    func selectedTier(for scope: AIModelScope) -> AIModelTier? {
        selectedTiers[scope]
    }

    /// 某个入口的请求带的档位：用户选过的档位，没选过时为本 App 的默认档位（精准）。
    ///
    /// 这个档位服务端已停用时退回精准；精准也停用时为 nil，不带档位请求头，由服务端按它的默认档位处理。
    /// 还没取到档位列表时先按选的或默认的档位发送。
    ///
    /// - Parameter scope: 这句话从哪个入口发出。
    func requestTier(for scope: AIModelScope) -> AIModelTier? {
        let preferredTier = selectedTiers[scope] ?? .appDefault
        guard let tierList else { return preferredTier }
        if tierList.selectableTiers.contains(preferredTier) { return preferredTier }
        return tierList.selectableTiers.contains(.appDefault) ? .appDefault : nil
    }

    /// 界面上勾选的档位：这个入口实际使用的档位；不带档位请求头时为服务端的默认档位，客户端不认识它时为 nil。
    ///
    /// - Parameter scope: 入口。
    func displayTier(for scope: AIModelScope) -> AIModelTier? {
        requestTier(for: scope) ?? tierList.flatMap { AIModelTier(rawValue: $0.defaultTier) }
    }

    /// 这个入口每说一句扣的点数，即实际使用档位的每轮点数；还没取到档位列表时为 nil。
    ///
    /// - Parameter scope: 入口。
    func pointsPerTurn(for scope: AIModelScope) -> Int? {
        guard let tierList else { return nil }
        return tierList.pointsPerTurn(for: requestTier(for: scope)?.rawValue ?? tierList.defaultTier)
    }

    /// 为某个入口选择模型档位并保存在本机，不影响另一个入口；从下一句话开始生效，正在处理的一句沿用开始时的档位。
    ///
    /// - Parameters:
    ///   - tier: 用户选的档位。
    ///   - scope: 入口。
    func selectTier(_ tier: AIModelTier, for scope: AIModelScope) {
        selectedTiers[scope] = tier
        defaults.set(tier.rawValue, forKey: scope.storageKey)
    }

    /// 保存已授权账号的本机偏好键。
    private static let traceConsentStorageKey = "ai.traceConsentUserIDs"

    /// 当前账号是否打开了“帮助改进 AI”；未登录或当前环境不提供（线上包）时为 false，本机留着的旧授权也不生效。
    var isTraceConsented: Bool {
        guard isTraceConsentAvailable else { return false }
        guard let userID = currentUserID() else { return false }
        return traceConsentedUserIDs.contains(userID)
    }

    /// 打开或关闭当前账号的“帮助改进 AI”，从下一次请求开始生效；未登录时不做任何事。
    ///
    /// - Parameter isConsented: 用户是否授权。
    func setTraceConsented(_ isConsented: Bool) {
        guard let userID = currentUserID() else { return }
        if isConsented {
            traceConsentedUserIDs.insert(userID)
        } else {
            traceConsentedUserIDs.remove(userID)
        }
        defaults.set(traceConsentedUserIDs.sorted(), forKey: Self.traceConsentStorageKey)
    }

    /// 保存已同意“AI 记账说明”的账号的本机偏好键。
    private static let aiProcessingConsentStorageKey = "ai.processingConsentUserIDs"

    /// 当前账号是否同意了“AI 记账说明”；未登录时为 false。
    var isAIProcessingConsented: Bool {
        guard let userID = currentUserID() else { return false }
        return aiProcessingConsentedUserIDs.contains(userID)
    }

    /// 同意或撤回当前账号的“AI 记账说明”，从下一次使用 AI 开始生效；未登录时不做任何事。
    ///
    /// - Parameter isConsented: 用户是否同意。
    func setAIProcessingConsented(_ isConsented: Bool) {
        guard let userID = currentUserID() else { return }
        if isConsented {
            aiProcessingConsentedUserIDs.insert(userID)
        } else {
            aiProcessingConsentedUserIDs.remove(userID)
        }
        defaults.set(aiProcessingConsentedUserIDs.sorted(), forKey: Self.aiProcessingConsentStorageKey)
    }

    /// 余额是否已经不够这个入口说一句；还不知道每轮点数时按 1 点判断，余额未知时不算用完。
    ///
    /// - Parameter scope: 入口。
    func isExhausted(for scope: AIModelScope) -> Bool {
        guard let balance else { return false }
        return balance < (pointsPerTurn(for: scope) ?? 1)
    }

    /// 余额不够这个入口所用档位说一句，但够换用扣点更少的可选档位：此时点数并没有用完，界面提示切换档位。
    ///
    /// - Parameter scope: 入口。
    func canAffordCheaperTier(for scope: AIModelScope) -> Bool {
        guard isExhausted(for: scope), let balance, let tierList else { return false }
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

    /// 是否该向用户提供签到：已拿到状态且今天还没签。
    var shouldOfferCheckIn: Bool {
        checkInStatus.map { !$0.checkedIn } ?? false
    }

    /// 还没开完的礼包，按发放先后；状态没拿到时为空。
    var unopenedGifts: [AICheckInGift] {
        checkInStatus?.gifts.filter { !$0.isFinished } ?? []
    }

    /// 保存看过签到引导的账号的本机偏好键。
    private static let checkInGuideStorageKey = "ai.checkInGuideShownUserIDs"

    /// 当前账号是否还没看过签到引导；未登录时为 false。
    var shouldShowCheckInGuide: Bool {
        guard let userID = currentUserID() else { return false }
        return !checkInGuideShownUserIDs.contains(userID)
    }

    /// 记下当前账号已看过签到引导，之后不再弹出；未登录时不做任何事。
    func markCheckInGuideShown() {
        guard let userID = currentUserID() else { return }
        checkInGuideShownUserIDs.insert(userID)
        defaults.set(checkInGuideShownUserIDs.sorted(), forKey: Self.checkInGuideStorageKey)
    }

    /// 开发测试用：让当前账号重新看一次签到引导，回到“我的”页、签到气泡出现时再弹出；未登录时不做任何事。
    /// 只有 dev 包的「开发」页调用。
    func resetCheckInGuide() {
        guard let userID = currentUserID() else { return }
        checkInGuideShownUserIDs.remove(userID)
        defaults.set(checkInGuideShownUserIDs.sorted(), forKey: Self.checkInGuideStorageKey)
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
        guard isNetworkAllowed() else { return }
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

    /// 刷新签到状态；未登录时清空。失败时保留上一次拿到的状态，不影响余额和 `failure`。
    func refreshCheckInStatus() async {
        guard isNetworkAllowed() else { return }
        guard let userID = currentUserID() else {
            checkInStatus = nil
            return
        }
        adopt(userID)
        do {
            let status = try await api.fetchCheckInStatus()
            if isCurrentOwner(userID) {
                checkInStatus = status
            }
        } catch {
            // 失败时保留上一次的状态；换账号时 adopt 已经清空过，不会留下别人的
        }
    }

    /// 每日签到。成功时用服务端返回的余额更新，并把新一批点数按过期时间插入批次；今天已签过时不追加批次，改为重新拉一次钱包。
    /// 签到状态换成已签，连签天数取返回值，这次得到的礼包追加到待开列表；补签卡换成签到后剩的张数，今天不能再用。
    ///
    /// 要用补签卡但服务端说用不了（另一台设备刚改了状态、跨过了零点）时这次没有签到：重新拉一次签到状态，
    /// 界面按最新情况让用户再点一次，余额不变。
    ///
    /// - Parameter useCard: 是否用补签卡保住昨天，由用户在签到前的弹窗里选择。
    /// - Returns: 签到结果；失败时为对应错误，余额不变。
    func checkIn(useCard: Bool = false) async -> Result<AICheckInResult, AIBillingAPIError> {
        guard let userID = currentUserID() else { return .failure(.notSignedIn) }
        guard !isCheckingIn else { return .failure(.invalidContract) }
        adopt(userID)
        isCheckingIn = true
        defer { isCheckingIn = false }
        do {
            let result = try await api.checkIn(useCard: useCard)
            guard isCurrentOwner(userID) else { return .success(result) }
            noteAppliedWrite(beginWrite())
            balance = result.balance
            failure = nil
            if !result.isDuplicate {
                insertGrantLot(
                    points: result.points,
                    reason: AICreditEntry.dailyCheckInReason,
                    createdAt: result.createdAt,
                    expiresAt: result.expiresAt
                )
            }
            let previous = checkInStatus
            // 同一个礼包以返回的为准（当天重复签到带回的打开次数是最新的），新得到的追加在后面
            var gifts = (previous?.gifts ?? []).map { gift in
                result.gifts.first { $0.id == gift.id } ?? gift
            }
            for gift in result.gifts where !gifts.contains(where: { $0.id == gift.id }) {
                gifts.append(gift)
            }
            checkInStatus = AICheckInStatus(
                date: result.date,
                checkedIn: true,
                checkIn: AICheckInRecord(
                    points: result.points,
                    streak: result.streak,
                    createdAt: result.createdAt,
                    expiresAt: result.expiresAt
                ),
                minPoints: previous?.minPoints ?? result.points,
                maxPoints: previous?.maxPoints ?? result.points,
                validHours: previous?.validHours,
                streak: result.streak,
                firstCheckInDate: previous?.firstCheckInDate ?? result.date,
                gifts: gifts.filter { !$0.isFinished },
                giftTiers: previous?.giftTiers ?? [],
                protection: previous?.protection?.afterCheckIn(cardsLeft: result.cardsLeft)
            )
            if result.isDuplicate {
                await refresh()
            }
            return .success(result)
        } catch {
            let apiError = error as? AIBillingAPIError ?? .network
            if apiError == .checkInProtectionUnavailable, isCurrentOwner(userID) {
                await refreshCheckInStatus()
            }
            return .failure(apiError)
        }
    }

    /// 打开一次签到礼包，开的是它的下一次（`nextSeq`）。
    ///
    /// 成功时用服务端返回的余额更新，把这次的点数按过期时间插入批次，并更新待开列表（开完的移除，年度礼包开过一次的留着）。
    /// 这一次早已开过（网络重发）时不在本机写余额和批次，改为重新拉一次钱包。礼包不存在或状态已变时重新拉签到状态，界面按最新列表显示。
    ///
    /// - Parameter gift: 要打开的礼包。
    /// - Returns: 打开结果；失败时为对应错误，余额不变。
    func openGift(_ gift: AICheckInGift) async -> Result<AICheckInGiftOpenResult, AIBillingAPIError> {
        guard let userID = currentUserID() else { return .failure(.notSignedIn) }
        guard !isOpeningGift, !gift.isFinished else { return .failure(.invalidContract) }
        adopt(userID)
        isOpeningGift = true
        defer { isOpeningGift = false }
        do {
            let result = try await api.openCheckInGift(id: gift.id, seq: gift.nextSeq)
            guard isCurrentOwner(userID) else { return .success(result) }
            if let checkInStatus {
                let gifts = checkInStatus.gifts.map { $0.id == result.gift.id ? result.gift : $0 }
                self.checkInStatus = checkInStatus.replacingGifts(gifts)
            }
            if result.isDuplicate {
                // 这一次早就入过账：本机批次里有没有它说不准，余额和批次都交给刷新；
                // 这里不登记写入，免得把正在进行的刷新当成过期结果丢掉
                await refresh()
            } else {
                noteAppliedWrite(beginWrite())
                balance = result.balance
                failure = nil
                insertGrantLot(
                    points: result.points,
                    reason: result.gift.tier.entryReason,
                    createdAt: result.createdAt,
                    expiresAt: result.expiresAt
                )
            }
            return .success(result)
        } catch {
            let apiError = error as? AIBillingAPIError ?? .network
            // 404、409 都映射成 invalidContract：礼包已被别的设备开过或不存在，重新拉一次列表；网络错误不拉，免得把列表清空
            if apiError == .invalidContract, isCurrentOwner(userID) {
                await refreshCheckInStatus()
            }
            return .failure(apiError)
        }
    }

    /// 开发测试用：在服务端清空当前账号的签到、礼包和打开记录，再补出截至昨天的连签；成功后换上重置后的签到状态并刷新余额。
    ///
    /// 只有 dev 环境的服务端开放这个接口，只有 dev 包的「开发」页调用。已入账的点数保留，补连签时服务端另发 1 点。
    /// 正在签到或开礼包时不重置，免得动画中途状态被换掉。
    ///
    /// - Parameter options: 补几天连签（0 为清空、像从没签过；N 为今天签到就是第 N+1 天）、昨天是否漏签、本月的补签卡是否已用。
    /// - Returns: 重置后的签到状态；失败时为对应错误，本机状态不变。
    func resetCheckInForTesting(_ options: AICheckInResetOptions) async -> Result<AICheckInStatus, AIBillingAPIError> {
        guard isNetworkAllowed() else { return .failure(.network) }
        guard let userID = currentUserID() else { return .failure(.notSignedIn) }
        guard !isCheckingIn, !isOpeningGift else { return .failure(.invalidContract) }
        adopt(userID)
        do {
            let status = try await api.resetCheckInForTesting(options)
            guard isCurrentOwner(userID) else { return .success(status) }
            checkInStatus = status
            await refresh()
            return .success(status)
        } catch {
            return .failure(error as? AIBillingAPIError ?? .network)
        }
    }

    /// 查询某个月的签到日历；签到页按月现查，不缓存在这里。
    ///
    /// - Parameter month: 月份，`YYYY-MM`。
    /// - Returns: 这个月的签到日历；不允许联网、未登录或查询失败时为对应错误。
    func fetchCheckInMonth(_ month: String) async -> Result<AICheckInMonth, AIBillingAPIError> {
        guard isNetworkAllowed() else { return .failure(.network) }
        guard currentUserID() != nil else { return .failure(.notSignedIn) }
        do {
            return .success(try await api.fetchCheckInHistory(month: month))
        } catch {
            return .failure(error as? AIBillingAPIError ?? .network)
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

    /// 创建与本状态共用接口的流水分页，供点数明细页使用。
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

    /// 把签到或礼包新入账的一批点数按过期时间插入批次，与服务端钱包的排序一致；下次刷新再以服务端为准。
    ///
    /// - Parameters:
    ///   - points: 入账点数。
    ///   - reason: 流水的原因标签，例如每日签到、某档礼包。
    ///   - createdAt: 入账时刻。
    ///   - expiresAt: 过期时刻。
    private func insertGrantLot(points: Int, reason: String?, createdAt: Date, expiresAt: Date) {
        let lot = AICreditLot(
            points: points,
            expiresAt: expiresAt,
            originalPoints: points,
            kind: .grant,
            reason: reason,
            product: AIBillingAPI.product,
            createdAt: createdAt
        )
        let index = lots.firstIndex { $0.expiresAt > lot.expiresAt } ?? lots.endIndex
        lots.insert(lot, at: index)
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
        checkInStatus = nil
        isCheckingIn = false
        isOpeningGift = false
        ownerUserID = nil
    }
}
