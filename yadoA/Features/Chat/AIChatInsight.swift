import Foundation

/// 今天的收支概况，聊天页顶部显示。
struct VoiceTodaySummary: Equatable {
    /// 今天的收支笔数。
    let entryCount: Int

    /// 今天的支出合计，不带正负号。
    let formattedExpense: String
}

/// 一次查账的展示结果：由模型给出的条件在本机算出，不多请求模型，也不回传给服务端。
///
/// 文字按发生时的语言保存，和改动快照一样进对话记录。
nonisolated struct AIChatInsight: Codable, Equatable, Sendable {
    /// 与上一期的差额。
    nonisolated struct Comparison: Codable, Equatable, Sendable {
        /// 这一期是否比上一期少。
        var isLess: Bool

        /// 差额，不带正负号。
        var formattedDelta: String
    }

    /// 分布图里的一根柱子。
    nonisolated struct Bucket: Codable, Equatable, Identifiable, Sendable {
        /// 这一段的起始记账日，作为稳定标识。
        var id: Int

        /// 横轴文字，例如「10/6」「10月」。
        var label: String

        /// 这一段的合计，决定柱子高度。
        var value: Double

        /// 这一段的合计文字。
        var formattedValue: String
    }

    /// 查询范围的说明，例如「10月1日至15日 · 餐饮 · 38 笔」。
    var title: String

    /// 主合计，不带正负号。
    var formattedTotal: String

    /// 没指定收支、同时有收入时的收入合计；其他情况为 `nil`。
    var formattedIncome: String?

    /// 与上一期的差额；没有明确时间范围或上一期没有流水时为 `nil`。
    var comparison: Comparison?

    /// 按时间分段的分布；不足两段时为空，不画图。
    var buckets: [Bucket]
}

/// 由筛选结果算出分布和比较范围；纯计算，不读数据库。
enum AIChatInsightBuilder {
    /// 按天分段的最长跨度（天）。
    private static let maxDailySpan = 7

    /// 按周分段的最长跨度（天）；再长就按月分段。
    private static let maxWeeklySpan = 62

    /// 按月分段最多显示的月数。
    private static let maxMonths = 12

    /// 上一期按自然月比较的最短跨度（天）；再短就往前挪同样的天数。
    private static let minMonthlyComparisonSpan = 28

    /// 确定要展示的记账日范围：没给的边界取流水的最早或最晚一天；范围覆盖今天时只算到今天，未来的日子不画空柱子。
    ///
    /// - Parameters:
    ///   - from: 条件里的起始记账日。
    ///   - to: 条件里的结束记账日。
    ///   - entryDays: 符合条件的流水的记账日。
    ///   - today: 今天的记账日。
    /// - Returns: `YYYYMMDD` 范围；既没有条件也没有流水时为 `nil`。
    static func clampedRange(from: Int?, to: Int?, entryDays: [Int], today: Int) -> ClosedRange<Int>? {
        guard let lower = from ?? entryDays.min(), var upper = to ?? entryDays.max(), lower <= upper else { return nil }
        if lower <= today, upper > today {
            upper = today
        }
        return lower...upper
    }

    /// 上一期的范围，用来比同样长的一段：问的是整个月时按自然月往前挪，这样问 10 月、今天 15 号时比的是 9 月 1～15 日；
    /// 否则往前挪问的那么多天，这样问本周、今天周三时比的是上周一到周三。
    ///
    /// - Parameters:
    ///   - range: 这一期实际算到的范围，可能已经截到今天。
    ///   - requested: 模型问的范围，决定怎么往前挪。
    ///   - calendar: 记账日使用的日历。
    ///   - locale: 解析记账日使用的语言环境。
    /// - Returns: `YYYYMMDD` 范围；日期无法换算时为 `nil`。
    static func previousRange(
        of range: ClosedRange<Int>,
        requested: ClosedRange<Int>,
        calendar: Calendar,
        locale: Locale
    ) -> ClosedRange<Int>? {
        guard let start = TransactionDay.date(from: range.lowerBound, calendar: calendar, locale: locale),
              let end = TransactionDay.date(from: range.upperBound, calendar: calendar, locale: locale),
              let requestedStart = TransactionDay.date(from: requested.lowerBound, calendar: calendar, locale: locale),
              let requestedEnd = TransactionDay.date(from: requested.upperBound, calendar: calendar, locale: locale),
              let spanDays = calendar.dateComponents([.day], from: requestedStart, to: requestedEnd).day
        else { return nil }
        let days = spanDays + 1
        let component: Calendar.Component = days >= minMonthlyComparisonSpan ? .month : .day
        let value = days >= minMonthlyComparisonSpan ? -1 : -days
        guard let previousStart = calendar.date(byAdding: component, value: value, to: start),
              let previousEnd = calendar.date(byAdding: component, value: value, to: end)
        else { return nil }
        return TransactionDay.encode(previousStart, calendar: calendar)...TransactionDay.encode(previousEnd, calendar: calendar)
    }

    /// 范围的文字，例如「10月1日至15日」。
    ///
    /// - Parameters:
    ///   - range: 记账日范围。
    ///   - calendar: 记账日使用的日历。
    ///   - locale: 文案使用的语言环境。
    /// - Returns: 范围文字；日期无法换算时为 `nil`。
    static func rangeText(_ range: ClosedRange<Int>, calendar: Calendar, locale: Locale) -> String? {
        guard let start = TransactionDay.date(from: range.lowerBound, calendar: calendar, locale: locale),
              let end = TransactionDay.date(from: range.upperBound, calendar: calendar, locale: locale)
        else { return nil }
        let formatter = DateIntervalFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateTemplate = range.lowerBound / 10_000 == range.upperBound / 10_000 ? "MMMd" : "yMMMd"
        return formatter.string(from: start, to: end)
    }

    /// 按范围长短分段求和：一周内按天，两个月内按 7 天一段，再长按自然月（最多最近 12 个月）。
    ///
    /// - Parameters:
    ///   - entries: 符合条件的流水的记账日和金额。
    ///   - range: 要展示的范围。
    ///   - calendar: 记账日使用的日历。
    ///   - locale: 文案使用的语言环境。
    ///   - format: 把合计转成文字。
    /// - Returns: 按时间排列的分段；不足两段时为空。
    static func buckets(
        entries: [(day: Int, amount: Decimal)],
        range: ClosedRange<Int>,
        calendar: Calendar,
        locale: Locale,
        format: (Decimal) -> String
    ) -> [AIChatInsight.Bucket] {
        guard let start = TransactionDay.date(from: range.lowerBound, calendar: calendar, locale: locale),
              let end = TransactionDay.date(from: range.upperBound, calendar: calendar, locale: locale),
              let spanDays = calendar.dateComponents([.day], from: start, to: end).day
        else { return [] }
        let days = spanDays + 1
        let segments: [ClosedRange<Date>]
        let template: String
        if days <= maxWeeklySpan {
            let step = days <= maxDailySpan ? 1 : 7
            segments = stride(from: 0, to: days, by: step).compactMap { offset in
                guard let lower = calendar.date(byAdding: .day, value: offset, to: start),
                      let upper = calendar.date(byAdding: .day, value: step - 1, to: lower)
                else { return nil }
                return lower...min(upper, end)
            }
            template = "Md"
        } else {
            segments = monthSegments(from: start, to: end, calendar: calendar)
            template = range.lowerBound / 10_000 == range.upperBound / 10_000 ? "MMM" : "yMMM"
        }
        guard segments.count >= 2 else { return [] }
        let formatter = BookkeepingDateFormatting.formatter(template: template, locale: locale, calendar: calendar)
        return segments.map { segment in
            let lower = TransactionDay.encode(segment.lowerBound, calendar: calendar)
            let upper = TransactionDay.encode(segment.upperBound, calendar: calendar)
            let total = entries
                .filter { $0.day >= lower && $0.day <= upper }
                .reduce(Decimal.zero) { $0 + $1.amount }
            return AIChatInsight.Bucket(
                id: lower,
                label: formatter.string(from: segment.lowerBound),
                value: NSDecimalNumber(decimal: total).doubleValue,
                formattedValue: format(total)
            )
        }
    }

    /// 把范围切成自然月，两端不超出范围；只保留最近 12 个月。
    private static func monthSegments(from start: Date, to end: Date, calendar: Calendar) -> [ClosedRange<Date>] {
        var segments: [ClosedRange<Date>] = []
        var lower = start
        while lower <= end {
            guard let interval = calendar.dateInterval(of: .month, for: lower),
                  let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end)
            else { break }
            // 记账日换算出的时刻不一定是零点，起始日就是月末时不能让下界越过上界
            segments.append(lower...max(lower, min(lastDay, end)))
            lower = interval.end
        }
        return Array(segments.suffix(maxMonths))
    }
}

/// 输入栏上方的一条建议。
struct AIChatSuggestion: Equatable, Identifiable {
    /// 点下去做什么。
    enum Action: Equatable {
        /// 直接发送；只用于查账这类不改数据的话。
        case send(String)

        /// 放进输入框让用户补全；记账、改账的金额得由用户说了算，不能替他发出去。
        case fill(String)

        /// 打开添加图片。
        case attachImage

        /// 撤销最近一轮。
        case undo
    }

    /// 建议文字。
    let title: String

    /// 点下去做什么。
    let action: Action

    /// 稳定标识。
    var id: String { title }

    /// 是否在本机完成、不扣点；撤销用强调色标出来。
    var isUndo: Bool { action == .undo }
}

/// 根据刚发生的事给出下一步建议：只用本机规则，不请求模型。
enum AIChatSuggestions {
    /// 生成建议。
    ///
    /// - Parameters:
    ///   - latest: 最新一轮；还没有记录时为 `nil`。
    ///   - isLive: 最新一轮是否还在当前对话段；已经结束的不再顺着它往下问。
    ///   - isAwaitingAnswer: 是否正在等用户回答追问。
    ///   - canUndo: 最新一轮能否撤销。
    ///   - locale: 文案使用的语言环境。
    /// - Returns: 按展示顺序排列的建议。
    static func make(
        latest: AIChatTurnSnapshot?,
        isLive: Bool,
        isAwaitingAnswer: Bool,
        canUndo: Bool,
        locale: Locale
    ) -> [AIChatSuggestion] {
        func string(_ key: String) -> String { AccountLocalization.string("voice.chat.suggestion.\(key)", locale: locale) }
        let start = [
            AIChatSuggestion(title: string("monthSpend"), action: .send(string("monthSpend"))),
            AIChatSuggestion(title: string("attachReceipt"), action: .attachImage),
            AIChatSuggestion(title: string("record"), action: .fill("")),
            AIChatSuggestion(title: string("netWorth"), action: .send(string("netWorth"))),
        ]
        guard let latest, isLive else { return start }
        // 追问时候选项在这一轮里，失败时重新发送在这一轮里，下面不再打岔
        guard !isAwaitingAnswer, !latest.isFailed else { return [] }
        guard !latest.isUndone else { return start }
        if latest.insight != nil {
            return [
                AIChatSuggestion(title: string("compare"), action: .send(string("compare"))),
                AIChatSuggestion(title: string("largest"), action: .send(string("largest"))),
                AIChatSuggestion(title: string("record"), action: .fill("")),
            ]
        }
        guard !latest.changes.isEmpty else { return start }

        var result: [AIChatSuggestion] = []
        if canUndo {
            result.append(AIChatSuggestion(
                title: AccountLocalization.string("voice.turn.undo", locale: locale), action: .undo
            ))
        }
        let remaining = latest.changes.filter { $0.kind == .created || $0.kind == .updated }
        if remaining.count == 1, let change = remaining.first {
            result.append(AIChatSuggestion(
                title: string("editAmount"),
                action: .fill(AccountLocalization.formatted(
                    "voice.chat.suggestion.editAmount.fill", value: change.title, locale: locale
                ))
            ))
        }
        if let change = remaining.last {
            let question = AccountLocalization.formatted(
                "voice.chat.suggestion.labelMonth", value: change.title, locale: locale
            )
            result.append(AIChatSuggestion(title: question, action: .send(question)))
        } else if latest.changes.contains(where: { $0.kind == .account }) {
            result.append(AIChatSuggestion(title: string("netWorth"), action: .send(string("netWorth"))))
        }
        result.append(AIChatSuggestion(title: string("recordAnother"), action: .fill("")))
        return result
    }
}

/// 聊天页顶部胶囊显示的状态。
enum AIChatStatus: Equatable {
    /// 空闲：显示今天的支出。
    case today

    /// 正在听用户说话，或等最后的识别结果。
    case listening

    /// 已发出，等模型回复。
    case thinking

    /// 带图片的一轮，等模型看图。
    case readingImage

    /// 模型要查账。
    case searching

    /// 已写入一部分，等模型决定后续。
    case writing

    /// 由当前输入和处理状态确定。
    ///
    /// - Parameters:
    ///   - isListening: 是否正在收音或等最后的识别结果。
    ///   - processingTurn: 正在处理的一轮；没有时为 `nil`。
    /// - Returns: 要显示的状态。
    static func resolve(isListening: Bool, processingTurn: VoiceSession.Turn?) -> AIChatStatus {
        if isListening { return .listening }
        guard let processingTurn else { return .today }
        switch processingTurn.phase {
        case .thinking: return processingTurn.imageFileNames.isEmpty ? .thinking : .readingImage
        case .searching: return .searching
        case .writing: return .writing
        }
    }

    /// 处理中显示的文字；空闲时为 `nil`，由调用方显示今日支出。
    ///
    /// - Parameter locale: 文案使用的语言环境。
    func text(locale: Locale) -> String? {
        let key: String? = switch self {
        case .today: nil
        case .listening: "voice.chat.status.listening"
        case .thinking: "voice.chat.status.thinking"
        case .readingImage: "voice.chat.status.image"
        case .searching: "voice.chat.status.searching"
        case .writing: "voice.chat.status.writing"
        }
        return key.map { AccountLocalization.string($0, locale: locale) }
    }
}

/// 结果纸条标题和开场白的文案。
enum AIChatCopy {
    /// 按当前时段打招呼的开场白。
    ///
    /// - Parameters:
    ///   - hour: 当前是几点，0～23。
    ///   - locale: 文案使用的语言环境。
    static func greeting(hour: Int, locale: Locale) -> String {
        let key = switch hour {
        case 5..<11: "voice.chat.greeting.morning"
        case 11..<14: "voice.chat.greeting.noon"
        case 14..<18: "voice.chat.greeting.afternoon"
        case 18..<23: "voice.chat.greeting.evening"
        default: "voice.chat.greeting.night"
        }
        return AccountLocalization.string(key, locale: locale)
    }

    /// 纸条的短标题，例如「已记 2 笔」。
    ///
    /// 结果文字是本机拼的摘要时，下面的行已经写得更清楚，换成短标题；模型自己说的话不能丢，返回 `nil` 由调用方照常显示。
    ///
    /// - Parameters:
    ///   - snapshot: 这一轮的展示内容。
    ///   - locale: 文案使用的语言环境。
    /// - Returns: 短标题；有账户改动或模型回复时为 `nil`。
    static func slipHeadline(for snapshot: AIChatTurnSnapshot, locale: Locale) -> String? {
        if snapshot.isUndone {
            return AccountLocalization.string("voice.turn.undone", locale: locale)
        }
        let items = snapshot.changes.compactMap { change -> VoiceSessionSummary.Item? in
            let kind: VoiceEntryChange.Kind
            switch change.kind {
            case .created: kind = .created
            case .updated: kind = .updated
            case .deleted: kind = .deleted
            case .account: return nil
            }
            return VoiceSessionSummary.Item(kind: kind, label: change.title, formattedAmount: change.formattedAmount ?? "")
        }
        guard !items.isEmpty, items.count == snapshot.changes.count else { return nil }
        if let resultText = snapshot.resultText, resultText != VoiceSessionSummary.text(forItems: items, locale: locale) {
            return nil
        }
        let kinds = Set(snapshot.changes.map(\.kind))
        let key = switch kinds.count == 1 ? kinds.first : nil {
        case .created: "voice.chat.slip.created"
        case .updated: "voice.chat.slip.updated"
        case .deleted: "voice.chat.slip.deleted"
        default: "voice.chat.slip.changed"
        }
        return String(format: AccountLocalization.string(key, locale: locale), locale: locale, items.count)
    }
}
