import Foundation
import Observation

/// 意见反馈的未读回复数，供「我的」入口和底部「我的」Tab 的角标共用。
///
/// 以服务端为准，只保存在内存里：App 启动、回到前台、进入「我的」时刷新；反馈页标记已读后用服务端带回的条数就地更新。
/// 未读数记着所属账号：换账号或退出登录后立即清零，旧账号晚到的结果不会记到当前账号上。
/// 写入都编号：刷新在发起时取号，标记已读在结果回来时取号，晚到的旧刷新结果不再覆盖更新的条数。
@Observable
final class FeedbackStore {
    /// 当前账号未读的团队回复条数；未登录或还没取到时为 0。
    private(set) var unreadCount = 0

    /// 当前未读数所属的账号。
    private var ownerUserID: String?

    /// 下一次写入的序号。
    private var nextWriteToken = 0

    /// 最近一次生效写入的序号；更早的结果晚到时丢弃。
    private var appliedWriteToken = 0

    /// 意见反馈接口。
    private let api: FeedbackServing

    /// 读取当前登录账号 ID 的动作；未登录时返回 nil。
    private let currentUserID: () -> String?

    /// 创建未读状态。
    ///
    /// - Parameters:
    ///   - api: 意见反馈接口。
    ///   - currentUserID: 读取当前登录账号 ID 的动作。
    init(api: FeedbackServing, currentUserID: @escaping () -> String?) {
        self.api = api
        self.currentUserID = currentUserID
    }

    /// 用登录状态创建：凭证取自公共服务的 access token，账号取 Logto 用户 ID。
    ///
    /// - Parameter authStore: 全局登录状态。
    convenience init(authStore: AuthStore) {
        self.init(api: FeedbackAPI(authStore: authStore), currentUserID: { authStore.userID })
    }

    /// 从服务端刷新未读数；未登录时清零，失败时保留原值。
    func refreshUnread() async {
        guard let userID = currentUserID() else {
            clear()
            return
        }
        adopt(userID)
        let token = beginWrite()
        guard let count = try? await api.fetchUnreadCount() else { return }
        guard ownerUserID == userID, currentUserID() == userID, token >= appliedWriteToken else { return }
        appliedWriteToken = token
        unreadCount = count
    }

    /// 反馈页标记已读后，用服务端带回的未读数就地更新；期间换了账号或退出登录时丢弃。
    ///
    /// - Parameters:
    ///   - count: 标记已读后的未读条数。
    ///   - userID: 标记已读时的账号。
    func applyUnreadCount(_ count: Int, for userID: String) {
        guard currentUserID() == userID else { return }
        adopt(userID)
        appliedWriteToken = beginWrite()
        unreadCount = count
    }

    /// 登记一次即将写入的操作。
    ///
    /// - Returns: 本次写入的序号，比之前的都大。
    private func beginWrite() -> Int {
        nextWriteToken += 1
        return nextWriteToken
    }

    /// 切到指定账号；与当前未读数所属账号不同时先清零。
    ///
    /// - Parameter userID: 当前登录账号 ID。
    private func adopt(_ userID: String) {
        guard ownerUserID != userID else { return }
        clear()
        ownerUserID = userID
    }

    /// 清零并解除账号归属。
    private func clear() {
        unreadCount = 0
        ownerUserID = nil
    }
}
