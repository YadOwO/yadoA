import Foundation
import Testing
@testable import yadoA

/// 聊天页的展示规则：下一步建议、状态、纸条标题和查账分布。
@Suite("聊天页展示规则")
@MainActor
struct AIChatPresentationTests {
    private let locale = Locale(identifier: "zh-Hans")

    /// 测试用的日历，按 UTC 计算记账日。
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// 生成一轮展示内容。
    private func snapshot(
        resultText: String? = nil,
        isFailed: Bool = false,
        isUndone: Bool = false,
        changes: [AIChatChangeSnapshot] = [],
        insight: AIChatInsight? = nil
    ) -> AIChatTurnSnapshot {
        AIChatTurnSnapshot(
            id: UUID(), createdAt: .now, userText: "午饭 28", imageFileNames: [], resultText: resultText,
            isFailed: isFailed, isUndone: isUndone, changes: changes, insight: insight
        )
    }

    /// 生成一行改动。
    private func change(_ kind: AIChatChangeSnapshot.Kind, title: String = "午饭", amount: String? = "¥28.00") -> AIChatChangeSnapshot {
        AIChatChangeSnapshot(
            id: UUID(), kind: kind, targetID: UUID(), symbolName: nil, title: title, formattedAmount: amount,
            transactionDay: kind == .account ? nil : 20261020, accountName: nil, inferredFields: [],
            accountAction: nil, accountDetail: nil
        )
    }

    private func suggestions(
        latest: AIChatTurnSnapshot?,
        isLive: Bool = true,
        isAwaitingAnswer: Bool = false,
        canUndo: Bool = false
    ) -> [AIChatSuggestion] {
        AIChatSuggestions.make(
            latest: latest, isLive: isLive, isAwaitingAnswer: isAwaitingAnswer, canUndo: canUndo, locale: locale
        )
    }

    // MARK: - 下一步建议

    @Test("写入账本的建议都不会直接发送：金额得由用户自己说")
    func neverSendsWritingSuggestions() {
        let cases = [
            suggestions(latest: nil),
            suggestions(latest: snapshot(changes: [change(.created)]), canUndo: true),
        ]
        for list in cases {
            let sent = list.compactMap { suggestion -> String? in
                if case let .send(message) = suggestion.action { return message }
                return nil
            }
            // 只有查询类的句子才会发送，它们都不带金额
            #expect(sent.allSatisfy { !$0.contains(where: \.isNumber) })
        }
    }

    @Test("刚记完：先给撤销，只有一笔时才能改金额")
    func suggestsAfterEntry() throws {
        let single = suggestions(latest: snapshot(changes: [change(.created)]), canUndo: true)
        #expect(single.first?.isUndo == true)
        let fill = try #require(single.compactMap { suggestion -> String? in
            if case let .fill(content) = suggestion.action, !content.isEmpty { return content }
            return nil
        }.first)
        #expect(fill.contains("午饭"))

        let double = suggestions(latest: snapshot(changes: [change(.created), change(.created, title: "打车")]), canUndo: true)
        #expect(!double.contains { suggestion in
            if case let .fill(content) = suggestion.action { return !content.isEmpty }
            return false
        })
    }

    @Test("改了周期记账：先给撤销，再引导看全部规则，不给改金额")
    func suggestsAfterRecurringChange() {
        let list = suggestions(
            latest: snapshot(changes: [change(.recurring, title: "房租", amount: "¥800.00"), change(.created, title: "房租", amount: "¥800.00")]),
            canUndo: true
        )
        #expect(list.first?.isUndo == true)
        let recurringList = AccountLocalization.string("voice.chat.suggestion.recurringList", locale: locale)
        #expect(list.contains { $0.action == .send(recurringList) })
        #expect(!list.contains { $0.title == AccountLocalization.string("voice.chat.suggestion.editAmount", locale: locale) })
        #expect(list.count == 3)
    }

    @Test("不能撤销时不给撤销")
    func omitsUndoWhenNotUndoable() {
        #expect(!suggestions(latest: snapshot(changes: [change(.created)]), canUndo: false).contains(where: \.isUndo))
    }

    @Test("追问和失败时不打岔；已撤销、对话段结束时回到开场建议")
    func fallsBackToStartSuggestions() {
        let start = suggestions(latest: nil)
        #expect(suggestions(latest: snapshot(resultText: "多少钱？"), isAwaitingAnswer: true).isEmpty)
        #expect(suggestions(latest: snapshot(isFailed: true)).isEmpty)
        #expect(suggestions(latest: snapshot(isUndone: true, changes: [change(.created)])) == start)
        #expect(suggestions(latest: snapshot(changes: [change(.created)]), isLive: false) == start)
        #expect(suggestions(latest: snapshot(resultText: "好的")) == start)
    }

    @Test("查账之后顺着问，都不改数据")
    func suggestsAfterQuery() {
        let insight = AIChatInsight(title: "", formattedTotal: "¥0", formattedIncome: nil, comparison: nil, buckets: [])
        let list = suggestions(latest: snapshot(resultText: "花了 ¥0", insight: insight))
        #expect(!list.isEmpty)
        #expect(!list.contains(where: \.isUndo))
    }

    // MARK: - 状态

    @Test("状态只说确实知道的阶段：说话优先，带图的一轮先看图")
    func resolvesStatus() {
        var turn = VoiceSession.Turn(userText: "午饭", eventStartIndex: 0)
        #expect(AIChatStatus.resolve(isListening: false, processingTurn: nil) == .today)
        #expect(AIChatStatus.resolve(isListening: true, processingTurn: turn) == .listening)
        #expect(AIChatStatus.resolve(isListening: false, processingTurn: turn) == .thinking)

        turn.imageFileNames = ["a.jpg"]
        #expect(AIChatStatus.resolve(isListening: false, processingTurn: turn) == .readingImage)

        turn.phase = .searching
        #expect(AIChatStatus.resolve(isListening: false, processingTurn: turn) == .searching)
        turn.phase = .writing
        #expect(AIChatStatus.resolve(isListening: false, processingTurn: turn) == .writing)
    }

    @Test("开场白按时段变化")
    func greetsByHour() {
        #expect(AIChatCopy.greeting(hour: 8, locale: locale) != AIChatCopy.greeting(hour: 20, locale: locale))
        #expect(AIChatCopy.greeting(hour: 2, locale: locale) == AIChatCopy.greeting(hour: 23, locale: locale))
    }

    // MARK: - 纸条标题

    @Test("本机拼的摘要换成短标题，下面的行已经写清楚了")
    func shortensLocalSummary() throws {
        let changes = [change(.created), change(.created, title: "打车", amount: "¥35.00")]
        let summary = VoiceSessionSummary.text(
            forItems: [
                .init(kind: .created, label: "午饭", formattedAmount: "¥28.00"),
                .init(kind: .created, label: "打车", formattedAmount: "¥35.00"),
            ],
            locale: locale
        )
        let headline = try #require(AIChatCopy.slipHeadline(for: snapshot(resultText: summary, changes: changes), locale: locale))
        #expect(headline.contains("2"))
        #expect(!headline.contains("午饭"))
    }

    @Test("模型自己说的话和账户改动不换标题，不丢内容")
    func keepsModelReply() {
        #expect(AIChatCopy.slipHeadline(for: snapshot(resultText: "记好了，顺便提醒你预算快用完了", changes: [change(.created)]), locale: locale) == nil)
        #expect(AIChatCopy.slipHeadline(for: snapshot(resultText: "已把微信的余额调整为 ¥500", changes: [change(.account)]), locale: locale) == nil)
        #expect(AIChatCopy.slipHeadline(for: snapshot(resultText: "已新建周期记账：房租，每月 ¥800.00", changes: [change(.recurring)]), locale: locale) == nil)
    }

    @Test("已撤销的纸条标题是已撤销")
    func marksUndone() {
        #expect(
            AIChatCopy.slipHeadline(for: snapshot(resultText: "已记 1 笔", isUndone: true, changes: [change(.created)]), locale: locale)
                == AccountLocalization.string("voice.turn.undone", locale: locale)
        )
    }

    // MARK: - 查账分布

    @Test("范围覆盖今天时只算到今天；没有条件时取流水的范围")
    func clampsRange() {
        #expect(AIChatInsightBuilder.clampedRange(from: 20261001, to: 20261031, entryDays: [], today: 20261015) == 20261001...20261015)
        #expect(AIChatInsightBuilder.clampedRange(from: 20260901, to: 20260930, entryDays: [], today: 20261015) == 20260901...20260930)
        #expect(AIChatInsightBuilder.clampedRange(from: nil, to: nil, entryDays: [20260905, 20260901], today: 20261015) == 20260901...20260905)
        #expect(AIChatInsightBuilder.clampedRange(from: nil, to: nil, entryDays: [], today: 20261015) == nil)
    }

    @Test("上一期比同样长的一段：问整月按自然月挪，问一周按天数挪，截到今天的部分也对得上")
    func computesPreviousRange() {
        func previous(_ range: ClosedRange<Int>, requested: ClosedRange<Int>) -> ClosedRange<Int>? {
            AIChatInsightBuilder.previousRange(of: range, requested: requested, calendar: calendar, locale: locale)
        }
        #expect(previous(20261001...20261015, requested: 20261001...20261031) == 20260901...20260915)
        #expect(previous(20261001...20261031, requested: 20261001...20261031) == 20260901...20260930)
        #expect(previous(20261013...20261015, requested: 20261013...20261019) == 20261006...20261008)
    }

    /// 按范围分段。
    private func buckets(_ range: ClosedRange<Int>, entries: [(day: Int, amount: Decimal)] = []) -> [AIChatInsight.Bucket] {
        AIChatInsightBuilder.buckets(
            entries: entries, range: range, calendar: calendar, locale: locale, format: { "\($0)" }
        )
    }

    @Test("按范围长短分段：一周内按天，两个月内按周，再长按月且最多 12 个月；不足两段不画图")
    func segmentsByLength() {
        #expect(buckets(20261020...20261020).isEmpty)
        #expect(buckets(20261014...20261020).count == 7)
        #expect(buckets(20261001...20261030).count == 5)
        #expect(buckets(20260501...20261031).count == 6)
        #expect(buckets(20241101...20261031).count == 12)
    }

    @Test("起始日就是月末时，按月分段也不会越界")
    func handlesRangeStartingAtMonthEnd() {
        #expect(buckets(20260331...20261031).count == 8)
    }

    @Test("每段合计正确，范围外的流水不算")
    func sumsEachBucket() {
        let result = buckets(
            20261001...20261014,
            entries: [(day: 20261002, amount: 10), (day: 20261007, amount: 5), (day: 20261008, amount: 20), (day: 20261101, amount: 99)]
        )
        #expect(result.map(\.value) == [15, 20])
    }
}
