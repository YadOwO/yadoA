import Foundation
import Observation

/// 记录刚保存成功的那一笔流水，供首页回到前台时把对应行短暂标红，提示"记在了这里"。
///
/// 普通记账和截图记账分属不同的展示容器，无法共享 SwiftUI 环境，因此使用进程内单例传递。
@MainActor
@Observable
final class HomeRecentEntryHighlight {
    /// 一次等待首页展示的新流水提示。
    struct Entry: Equatable {
        /// 新流水的稳定 UUID，对应首页行标识。
        let id: UUID

        /// `YYYYMMDD` 记账日，用于让首页切到这笔流水所在的月份。
        let transactionDay: Int

        /// 保存成功的时刻，用于丢弃过期提示。
        let savedAt: Date
    }

    /// 应用内唯一的提示通道。
    static let shared = HomeRecentEntryHighlight()

    /// 超过该时长仍未被首页展示的提示不再生效，避免用户很久之后回到首页时突然跳月份。
    private static let lifetime: TimeInterval = 30

    /// 尚未被首页展示的新流水。
    private(set) var pending: Entry?

    private init() {}

    /// 保存成功后登记新流水。
    ///
    /// - Parameters:
    ///   - id: 新流水的 UUID。
    ///   - transactionDay: `YYYYMMDD` 记账日。
    func mark(id: UUID, transactionDay: Int) {
        pending = Entry(id: id, transactionDay: transactionDay, savedAt: .now)
    }

    /// 取走待展示的提示；每条提示只会被展示一次。
    ///
    /// - Returns: 仍在有效期内的新流水，没有或已过期时返回 `nil`。
    func consume() -> Entry? {
        guard let entry = pending else { return nil }
        pending = nil
        return Date.now.timeIntervalSince(entry.savedAt) <= Self.lifetime ? entry : nil
    }
}
