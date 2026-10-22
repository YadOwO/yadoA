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

/// 一批变更提示在首页的定位目标：切到哪个月份，以及滚动时在其中哪几笔里取排得最靠上的一笔。
///
/// 语音记账一句话可能改动好几笔、分布在不同月份。首页一次只能展示一个月，
/// 因此切到变更最多的月份；锚点取列表里最靠上的一笔，其余几笔会出现在它下方。
struct HomeEntryFocus: Equatable {
    /// 要切换到的月份。
    let month: HomeMonth

    /// 该月份内的变更流水；滚动时取其中在明细里排得最靠上、且已经出现的一笔。
    let transactionIDs: Set<UUID>

    /// 为一批变更选出定位目标。
    ///
    /// 月份按以下顺序决出：变更笔数最多 → 首页当前所在月份 → 离今天所在月份最近 → 更晚的月份。
    ///
    /// - Parameters:
    ///   - entries: 本批流水变更。
    ///   - currentMonth: 首页当前展示的月份，笔数相同时优先留在这个月，避免无谓的跳转。
    ///   - today: 今天所在的月份。
    /// - Returns: 定位目标；所有变更的记账日都无效时为 `nil`。
    init?(entries: [HomeRecentEntryHighlight.Entry], currentMonth: HomeMonth?, today: HomeMonth?) {
        var idsByMonth: [HomeMonth: Set<UUID>] = [:]
        for entry in entries {
            guard let month = HomeMonth(value: entry.transactionDay / 100) else { continue }
            idsByMonth[month, default: []].insert(entry.id)
        }
        // 月份距今天所在月份相差的月数；没有今天时视为相同距离。
        func distance(_ month: HomeMonth) -> Int {
            guard let today else { return 0 }
            return abs((month.year - today.year) * 12 + month.month - today.month)
        }
        let best = idsByMonth.max { lhs, rhs in
            if lhs.value.count != rhs.value.count { return lhs.value.count < rhs.value.count }
            if (lhs.key == currentMonth) != (rhs.key == currentMonth) { return rhs.key == currentMonth }
            if distance(lhs.key) != distance(rhs.key) { return distance(lhs.key) > distance(rhs.key) }
            return lhs.key < rhs.key
        }
        guard let best else { return nil }
        month = best.key
        transactionIDs = best.value
    }
}
