import Foundation
import SwiftData

/// 一次流水变更在首页上要播放的提示，与 `HomeRecentEntryHighlight` 的三种提示对应。
enum VoiceEntryHighlight: Equatable {
    /// 新记了一笔。
    case added(id: UUID, transactionDay: Int)

    /// 修改了一笔；携带修改前的首页行快照。
    case updated(id: UUID, transactionDay: Int, previous: HomeOverviewRowPresentation?)

    /// 删除了一笔；携带删除前的首页行快照。
    case deleted(HomeOverviewDeletedRow)
}

extension HomeRecentEntryHighlight {
    /// 登记一条语音记账产生的首页提示；首页不在屏幕上时不登记。
    ///
    /// 语音只在用户正看着首页时原地提示。在别的页面说的、或在别的页面撤销的，回到首页时不再自动跳月份标红，
    /// 想看哪一笔点会话卡片上的结果定位。
    /// - Parameter highlight: 变更对应的提示。
    func mark(_ highlight: VoiceEntryHighlight) {
        guard isHomeVisible else { return }
        switch highlight {
        case let .added(id, transactionDay):
            mark(id: id, transactionDay: transactionDay)
        case let .updated(id, transactionDay, previous):
            mark(id: id, transactionDay: transactionDay, change: .updated(previous: previous))
        case let .deleted(row):
            markDeleted(row)
        }
    }
}

/// 一次工具执行成功写入的流水变更，供结果展示、撤销与首页提示使用。
struct VoiceEntryChange: Equatable, Identifiable {
    /// 变更类型。
    enum Kind: Equatable {
        /// 新增。
        case created

        /// 修改。
        case updated

        /// 删除。
        case deleted
    }

    /// 本次变更的唯一标识；同一笔流水在一轮里可能先后被改多次。确认账户后沿用原来的标识，界面上还是同一行。
    var id = UUID()

    /// 变更类型。
    let kind: Kind

    /// 流水 UUID。
    let transactionID: UUID

    /// 变更后的 `YYYYMMDD` 记账日；删除时为删除前的记账日。
    let transactionDay: Int

    /// 变更后的流水展示；删除时为删除前的样子。流水不在首页展示范围内时为 `nil`。
    let row: HomeOverviewRowPresentation?

    /// 流水所属账户的名称；账户不存在时为 `nil`。
    let accountName: String?

    /// 结果提示里称呼这笔流水的文字：备注、标题或分类名称，例如「午饭」。
    let label: String

    /// 不带正负号的本地化金额，例如「¥28.00」。
    let formattedAmount: String

    /// 由 AI 推断或取了默认值的字段，只有新增时可能非空。
    let inferredFields: [VoiceInferredField]

    /// 撤销本次变更的反向操作。
    let inverse: BookkeepingEntryMutation

    /// 首页提示；删除的流水不在首页展示范围、没有残影可画时为 `nil`。
    let highlight: VoiceEntryHighlight?
}

/// 账户相关改动撤销时执行的反向变更。
enum VoiceAccountInverse: Equatable {
    /// 删除余额调整流水，并从账户余额中扣回它的差额。
    case removeBalanceAdjustment(UUID)

    /// 删除转账流水，并改回两边账户的余额。
    case removeTransfer(UUID)

    /// 还原账户；改动换了默认记账账户时一并改回，没换时为 `nil`。
    case account(AccountRevert, defaultChange: DefaultAccountChange?)
}

/// 一次工具执行成功写入的账户相关改动：余额调整、转账、新建、修改或删除账户。
///
/// 余额调整与转账不在首页明细中展示，结果里点这一行打开账户详情，而不是在首页定位；
/// 文字在执行时按当时的语言生成，账户之后改名也不影响已展示的结果。
struct VoiceAccountChange: Equatable, Identifiable {
    /// 本次改动的唯一标识。
    let id = UUID()

    /// 改动涉及、改动后仍然存在的账户，转账时依次为转出、转入账户；删除账户时为空。
    ///
    /// 结果里点这一行打开第一个账户的详情，账户页列表在这些账户上补笔迹提示。
    let accountIDs: [UUID]

    /// 行首的动作，例如「调整余额」「转账」「新建账户」「已停用」。
    let actionText: String

    /// 行标题：账户名称；转账时为「招行 → 微信」。
    let title: String

    /// 行图标，取账户模板或类型的图标。
    let symbolName: String

    /// 行尾金额：调整后的余额、转账金额或新账户的余额；修改、删除账户时为 `nil`。
    let formattedAmount: String?

    /// 补充说明，例如「原 ¥500.00」「储蓄卡 · 待确认：余额」。
    let detail: String?

    /// 结果提示中的一句，例如「已把微信的余额调整为 ¥487.50」。
    let summary: String

    /// 撤销本次改动的反向变更。
    let inverse: VoiceAccountInverse
}

/// 一次工具执行成功写入的周期记账改动：新建、修改、暂停、恢复或删除规则。
///
/// 规则不在首页明细中展示，结果里点这一行打开周期记账列表；新建或修改时当场记入的流水另作收支改动，排在它后面。
/// 文字在执行时按当时的语言生成，之后改名、改分类也不影响已展示的结果。
struct VoiceRecurringChange: Equatable, Identifiable {
    /// 本次改动的唯一标识。
    let id = UUID()

    /// 改动后仍然存在的规则 UUID；删除时为 `nil`，结果里不再打开列表。
    let ruleID: UUID?

    /// 行首的动作，例如「新建周期记账」「已暂停」「已删除」。
    let actionText: String

    /// 行标题：规则的备注，没有备注时为分类名称。
    let title: String

    /// 行图标，取分类图标。
    let symbolName: String

    /// 行尾的每期金额，不带正负号。
    let formattedAmount: String

    /// 补充说明，例如「每月 · 下次 12月1日 · 招行 · 待确认：账户」。
    let detail: String?

    /// 结果提示中的一句，例如「已新建周期记账：房租，每月 ¥3,000.00」。
    let summary: String

    /// 撤销本次改动的反向变更。
    let inverse: RecurringRuleRevert
}

/// 一次工具执行成功写入的改动；一轮按执行顺序记录，撤销时倒序执行。
enum VoiceChange: Equatable, Identifiable {
    /// 收支流水的新增、修改、删除，可以在首页定位。
    case entry(VoiceEntryChange)

    /// 账户相关的改动。
    case account(VoiceAccountChange)

    /// 周期记账规则的改动。
    case recurring(VoiceRecurringChange)

    /// 改动的唯一标识。
    var id: UUID {
        switch self {
        case let .entry(change): change.id
        case let .account(change): change.id
        case let .recurring(change): change.id
        }
    }

    /// 收支流水的改动；其他改动为 `nil`。
    var entryChange: VoiceEntryChange? {
        if case let .entry(change) = self { return change }
        return nil
    }
}

/// 一次工具执行的结果。
struct VoiceToolExecution: Equatable {
    /// 回传给服务端的执行结果。
    let result: VoiceToolResult

    /// 成功写入的改动，按执行顺序排列；查询、汇总和失败时为空。
    ///
    /// 通常只有一项。新建或修改周期记账时，规则的改动后面紧跟当场记入的各期流水，撤销时一起倒序撤销。
    let changes: [VoiceChange]

    /// 汇总成功时展示用的结果；其他工具为 `nil`，不回传给服务端。
    var insight: AIChatInsight?

    /// 这次调用直接要求的改动，即 `changes` 的第一项；查询、汇总和失败时为 `nil`。
    var change: VoiceChange? { changes.first }
}
