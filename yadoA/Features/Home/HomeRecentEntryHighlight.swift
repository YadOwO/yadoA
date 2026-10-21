import Foundation
import Observation

/// 记录刚新增、修改或删除成功的流水，供首页回到前台时在列表里播放对应的提示动画。
///
/// 一次可以登记多条：语音记账一句话可能同时新增、修改好几笔。
///
/// 新增会让对应行短暂标红并写出对勾；修改会把改动的旧值划掉、换成新值；删除会在原位置留下一行被划掉的残影，随后收起。
/// 普通记账、截图记账和流水详情分属不同的展示容器，无法共享 SwiftUI 环境，因此使用进程内单例传递。
@MainActor
@Observable
final class HomeRecentEntryHighlight {
    /// 一次等待首页展示的流水变更提示。
    struct Entry: Equatable {
        /// 流水发生的变更类型。
        enum Change: Equatable {
            /// 新记了一笔。
            case added

            /// 修改了已有流水；携带修改前的行快照，用于展示从什么改成了什么。
            ///
            /// 修改前流水不在首页展示时快照为 `nil`，此时只提示"改过"，不做逐项对比。
            case updated(previous: HomeOverviewRowPresentation?)

            /// 删除了一笔流水；携带删除前的行快照，用于在原位置画出残影。
            case deleted(HomeOverviewDeletedRow)
        }

        /// 流水的稳定 UUID，对应首页行标识。
        let id: UUID

        /// `YYYYMMDD` 记账日，用于让首页切到这笔流水所在的月份。
        let transactionDay: Int

        /// 本次提示对应的变更类型。
        let change: Change

        /// 保存成功的时刻，用于丢弃过期提示。
        let savedAt: Date
    }

    /// 应用内唯一的提示通道。
    static let shared = HomeRecentEntryHighlight()

    /// 超过该时长仍未被首页展示的提示不再生效，避免用户很久之后回到首页时突然跳月份。
    private static let lifetime: TimeInterval = 30

    /// 尚未被首页展示的流水变更，按登记顺序排列。
    private(set) var pending: [Entry] = []

    private init() {}

    /// 新增或修改保存成功后登记这笔流水；同一笔流水尚未展示的旧提示会被替换。
    ///
    /// - Parameters:
    ///   - id: 流水的 UUID。
    ///   - transactionDay: 保存后的 `YYYYMMDD` 记账日。
    ///   - change: 变更类型，默认为新增。
    func mark(id: UUID, transactionDay: Int, change: Entry.Change = .added) {
        pending.removeAll { $0.id == id }
        pending.append(Entry(id: id, transactionDay: transactionDay, change: change, savedAt: .now))
    }

    /// 删除成功后登记被删除流水的行快照。
    ///
    /// - Parameter deletedRow: 删除前生成的首页行快照。
    func markDeleted(_ deletedRow: HomeOverviewDeletedRow) {
        mark(id: deletedRow.row.id, transactionDay: deletedRow.transactionDay, change: .deleted(deletedRow))
    }

    /// 取走全部待展示的提示；每条提示只会被展示一次。
    ///
    /// - Returns: 仍在有效期内的流水变更，按登记顺序排列；没有或都已过期时为空。
    func consume() -> [Entry] {
        guard !pending.isEmpty else { return [] }
        let entries = pending
        pending = []
        return entries.filter { Date.now.timeIntervalSince($0.savedAt) <= Self.lifetime }
    }
}
