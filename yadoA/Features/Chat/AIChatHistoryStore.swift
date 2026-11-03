import Foundation
import Observation
import SwiftData

extension Notification.Name {
    /// 本机账本被整体替换或清空、或对话记录被清空：当前对话段不能再引用旧数据，界面要重新读取记录。
    static let aiChatContextInvalidated = Notification.Name("aiChatContextInvalidated")
}

/// 一轮对话的本机记录；只存在这台设备上，不进云同步和备份，保留 `AIChatHistoryStore.retentionDays` 天。
@Model
final class AIChatTurnRecord {
    /// 与 `VoiceSession.Turn.id` 相同，撤销时据此更新同一条记录。
    @Attribute(.unique) var id: UUID

    /// 用户发出这一轮的时刻。
    var createdAt: Date

    /// 用户说的话；只发图片时为空。
    var userText: String

    /// 这一轮附带的图片文件名，文件保存在 `AIChatImageStore.directory`。
    var imageFileNames: [String]

    /// 回复、追问或失败原因；按当时的语言保存。
    var resultText: String?

    /// 这一轮是否没能完成。
    var isFailed: Bool

    /// 这一轮是否已被撤销。
    var isUndone: Bool

    /// 这一轮的改动快照，内容是 `[AIChatChangeSnapshot]` 的 JSON。
    var changesData: Data

    /// 这一轮查询结果的快照，内容是 `AIChatInsight` 的 JSON；没有查询结果时为空。
    var insightData: Data?

    /// 创建一条记录。
    ///
    /// - Parameters:
    ///   - snapshot: 这一轮的展示内容。
    ///   - changesData: 改动快照的 JSON。
    init(snapshot: AIChatTurnSnapshot, changesData: Data) {
        id = snapshot.id
        createdAt = snapshot.createdAt
        userText = snapshot.userText
        imageFileNames = snapshot.imageFileNames
        resultText = snapshot.resultText
        isFailed = snapshot.isFailed
        isUndone = snapshot.isUndone
        self.changesData = changesData
        insightData = snapshot.insight.flatMap { try? JSONEncoder().encode($0) }
    }
}

/// 一次改动的展示快照：文字按发生时保存，账户之后改名也不影响已有记录；点开时再按 `targetID` 查最新状态。
nonisolated struct AIChatChangeSnapshot: Codable, Equatable, Identifiable, Sendable {
    /// 改动类型。
    nonisolated enum Kind: String, Codable, Sendable {
        /// 新增流水。
        case created

        /// 修改流水。
        case updated

        /// 删除流水。
        case deleted

        /// 账户相关的改动。
        case account

        /// 周期记账规则的改动。
        case recurring
    }

    /// 本次改动的唯一标识。
    var id: UUID

    /// 改动类型。
    var kind: Kind

    /// 点开时要看的流水、账户或周期记账规则；删除账户、删除规则时为空。
    var targetID: UUID?

    /// 行图标。
    var symbolName: String?

    /// 流水的名称或账户名称。
    var title: String

    /// 行尾金额；修改、删除账户时为空。
    var formattedAmount: String?

    /// 流水的 `YYYYMMDD` 记账日；账户改动为空。
    var transactionDay: Int?

    /// 流水所属账户的名称；账户改动为空。
    var accountName: String?

    /// 流水待确认字段的原始值；账户改动为空。
    var inferredFields: [String]

    /// 账户或周期记账改动的动作文字，例如「调整余额」「新建周期记账」；流水改动为空。
    ///
    /// 字段名沿用最早只有账户改动时的命名，已经写进本机历史记录，不再改名。
    var accountAction: String?

    /// 账户或周期记账改动的补充说明；流水改动为空。
    var accountDetail: String?

    /// 是否是流水改动。
    var isEntry: Bool { kind != .account && kind != .recurring }
}

extension AIChatChangeSnapshot {
    /// 由一次实际发生的改动生成快照。
    ///
    /// - Parameter change: 工具执行产生的改动。
    init(change: VoiceChange) {
        switch change {
        case let .entry(entry):
            let kind: Kind = switch entry.kind {
            case .created: .created
            case .updated: .updated
            case .deleted: .deleted
            }
            self.init(
                id: entry.id,
                kind: kind,
                targetID: entry.transactionID,
                symbolName: entry.row?.symbolName,
                title: entry.label,
                formattedAmount: entry.formattedAmount,
                transactionDay: entry.transactionDay,
                accountName: entry.accountName,
                inferredFields: entry.inferredFields.map(\.rawValue),
                accountAction: nil,
                accountDetail: nil
            )
        case let .account(account):
            self.init(
                id: account.id,
                kind: .account,
                targetID: account.accountIDs.first,
                symbolName: account.symbolName,
                title: account.title,
                formattedAmount: account.formattedAmount,
                transactionDay: nil,
                accountName: nil,
                inferredFields: [],
                accountAction: account.actionText,
                accountDetail: account.detail
            )
        case let .recurring(recurring):
            self.init(
                id: recurring.id,
                kind: .recurring,
                targetID: recurring.ruleID,
                symbolName: recurring.symbolName,
                title: recurring.title,
                formattedAmount: recurring.formattedAmount,
                transactionDay: nil,
                accountName: nil,
                inferredFields: [],
                accountAction: recurring.actionText,
                accountDetail: recurring.detail
            )
        }
    }
}

/// 聊天页展示的一轮：历史记录和当前对话段的轮次都转成它，界面只有一套渲染。
struct AIChatTurnSnapshot: Equatable, Identifiable {
    /// 与 `VoiceSession.Turn.id` 相同。
    let id: UUID

    /// 发出时刻。
    let createdAt: Date

    /// 用户说的话；只发图片时为空。
    let userText: String

    /// 附带的图片文件名。
    let imageFileNames: [String]

    /// 回复、追问或失败原因；处理中为空。
    let resultText: String?

    /// 是否没能完成。
    let isFailed: Bool

    /// 是否已被撤销。
    let isUndone: Bool

    /// 这一轮的改动。
    let changes: [AIChatChangeSnapshot]

    /// 这一轮的查询结果；一轮查了多次时不展示，避免只画其中一次让人误读。
    var insight: AIChatInsight?
}

extension AIChatTurnSnapshot {
    /// 由当前对话段的一轮生成。
    ///
    /// - Parameters:
    ///   - turn: 会话中的一轮。
    ///   - locale: 失败提示使用的语言。
    init(turn: VoiceSession.Turn, locale: Locale) {
        self.init(
            id: turn.id,
            createdAt: turn.createdAt,
            userText: turn.userText,
            imageFileNames: turn.imageFileNames,
            resultText: turn.resultText(locale: locale),
            isFailed: turn.failure != nil,
            isUndone: turn.isUndone,
            changes: turn.changes.map(AIChatChangeSnapshot.init(change:)),
            insight: turn.insights.count == 1 ? turn.insights.first : nil
        )
    }

    /// 由本机记录还原。
    fileprivate init(record: AIChatTurnRecord) {
        self.init(
            id: record.id,
            createdAt: record.createdAt,
            userText: record.userText,
            imageFileNames: record.imageFileNames,
            resultText: record.resultText,
            isFailed: record.isFailed,
            isUndone: record.isUndone,
            changes: (try? JSONDecoder().decode([AIChatChangeSnapshot].self, from: record.changesData)) ?? [],
            insight: record.insightData.flatMap { try? JSONDecoder().decode(AIChatInsight.self, from: $0) }
        )
    }
}

/// 对话记录的本机存储：每轮结束时写入，聊天页分页读取。
///
/// 记录写失败不影响记账本身，账本才是真数据，因此这里的写入都不向外抛错。
@MainActor
@Observable
final class AIChatHistoryStore {
    /// 记录保留的天数，超过后在下次启动时清理。
    static let retentionDays = 90

    /// 每次读取的轮数。
    static let pageSize = 50

    /// 已读取的记录，按时间正序排列。
    private(set) var turns: [AIChatTurnSnapshot] = []

    /// 是否还有更早的记录没有读取。
    private(set) var hasEarlier = false

    private let container: ModelContainer
    private let images: AIChatImageStore

    /// 创建存储。
    ///
    /// - Parameters:
    ///   - container: 应用持有的本地财务容器。
    ///   - images: 图片文件存储。
    init(container: ModelContainer, images: AIChatImageStore = .production) {
        self.container = container
        self.images = images
    }

    /// 读取最近一页记录，丢弃之前读过的。
    func loadLatest() {
        turns = []
        hasEarlier = false
        loadEarlier()
    }

    /// 再往前读一页。
    func loadEarlier() {
        var descriptor = FetchDescriptor<AIChatTurnRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchOffset = turns.count
        // 多读一条，判断前面是否还有
        descriptor.fetchLimit = Self.pageSize + 1
        let records = (try? container.makeManualSaveContext().fetch(descriptor)) ?? []
        hasEarlier = records.count > Self.pageSize
        turns.insert(contentsOf: records.prefix(Self.pageSize).reversed().map(AIChatTurnSnapshot.init(record:)), at: 0)
    }

    /// 写入或更新一轮；处理中的不写入。
    ///
    /// - Parameters:
    ///   - turn: 会话中的一轮。
    ///   - locale: 失败提示使用的语言。
    func save(_ turn: VoiceSession.Turn, locale: Locale) {
        guard turn.outcome != .processing else { return }
        let snapshot = AIChatTurnSnapshot(turn: turn, locale: locale)
        let changesData = (try? JSONEncoder().encode(snapshot.changes)) ?? Data()
        let context = container.makeManualSaveContext()
        let turnID = turn.id
        var descriptor = FetchDescriptor<AIChatTurnRecord>(predicate: #Predicate { $0.id == turnID })
        descriptor.fetchLimit = 1
        do {
            if let record = try context.fetch(descriptor).first {
                record.resultText = snapshot.resultText
                record.isFailed = snapshot.isFailed
                record.isUndone = snapshot.isUndone
                record.changesData = changesData
                record.insightData = snapshot.insight.flatMap { try? JSONEncoder().encode($0) }
            } else {
                context.insert(AIChatTurnRecord(snapshot: snapshot, changesData: changesData))
            }
            try context.save()
        } catch {
            context.rollback()
            return
        }
        if let index = turns.firstIndex(where: { $0.id == turnID }) {
            turns[index] = snapshot
        } else {
            turns.append(snapshot)
        }
    }

    /// 本机是否还有对话记录；AI 点数页据此决定清空入口能不能点。读不出来时当作有，不挡住清空。
    func hasRecords() -> Bool {
        var descriptor = FetchDescriptor<AIChatTurnRecord>()
        descriptor.fetchLimit = 1
        return ((try? container.makeManualSaveContext().fetchCount(descriptor)) ?? 1) > 0
    }

    /// 清空全部记录和图片。
    ///
    /// - Throws: 保存失败时抛出，此时记录保持原样。
    func clearAll() throws {
        let context = container.makeManualSaveContext()
        do {
            try context.delete(model: AIChatTurnRecord.self)
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        images.removeAll()
        turns = []
        hasEarlier = false
        NotificationCenter.default.post(name: .aiChatContextInvalidated, object: nil)
    }

    /// 清理超过保留期的记录，以及没有记录引用的图片文件；只在启动、还没有发出新一轮时调用。
    ///
    /// - Parameter now: 当前时刻。
    func prune(now: Date = .now) {
        guard let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -Self.retentionDays, to: now)
        else { return }
        let context = container.makeManualSaveContext()
        do {
            let expired = try context.fetch(FetchDescriptor<AIChatTurnRecord>(
                predicate: #Predicate { $0.createdAt < cutoff }
            ))
            expired.forEach(context.delete)
            try context.save()
            let kept = try context.fetch(FetchDescriptor<AIChatTurnRecord>())
            images.removeFiles(notIn: Set(kept.flatMap(\.imageFileNames)))
        } catch {
            context.rollback()
        }
    }

    /// 这些轮次涉及的流水、账户和周期记账规则中，当前仍然存在的那些。
    ///
    /// - Parameter turns: 要检查的轮次。
    /// - Returns: 仍然存在的流水、账户和规则 UUID。
    func existingTargetIDs(in turns: [AIChatTurnSnapshot]) -> Set<UUID> {
        let changes = turns.flatMap(\.changes)
        let transactionIDs = changes.filter(\.isEntry).compactMap(\.targetID)
        let accountIDs = changes.filter { $0.kind == .account }.compactMap(\.targetID)
        let ruleIDs = changes.filter { $0.kind == .recurring }.compactMap(\.targetID)
        let context = container.makeManualSaveContext()
        let transactions = (try? context.fetch(FetchDescriptor<AccountTransaction>(
            predicate: #Predicate { transactionIDs.contains($0.id) }
        ))) ?? []
        let accounts = (try? context.fetch(FetchDescriptor<Account>(
            predicate: #Predicate { accountIDs.contains($0.id) }
        ))) ?? []
        let rules = (try? context.fetch(FetchDescriptor<RecurringRule>(
            predicate: #Predicate { ruleIDs.contains($0.id) }
        ))) ?? []
        return Set(transactions.map(\.id)).union(accounts.map(\.id)).union(rules.map(\.id))
    }
}
