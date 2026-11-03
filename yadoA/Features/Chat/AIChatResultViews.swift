import SwiftUI

/// 结果纸条上能做的事；历史记录里只有打开详情。
struct AIChatResultActions {
    /// 打开一行改动的详情。
    let open: (AIChatChangeSnapshot) -> Void

    /// 撤销这一轮；不能撤销时为 `nil`。
    var undo: (() -> Void)?

    /// 确认一行的账户，返回是否成功；不能就地确认时为 `nil`，点待确认改为打开详情。
    var confirmAccount: ((AIChatChangeSnapshot, UUID) -> Bool)?

    /// 读取可以选的账户。
    var accountOptions: () -> [VoiceAccountOption] = { [] }
}

/// 一轮的结果：有改动时是一张纸条，查账时是大数字加分布图，其余是一段文字；模型说的话可以长按选中拷贝。
struct AIChatTurnResultView: View {
    /// 这一轮的展示内容。
    let snapshot: AIChatTurnSnapshot

    /// 这一轮是否处理完了。
    let isFinished: Bool

    /// 是否是模型的追问；用标题字号，让人知道该接话了。
    let isQuestion: Bool

    /// 是否播放入场动效；只有刚发生的一轮才播，翻历史时全部静止。
    let animatesEntrance: Bool

    /// 仍然存在的流水和账户；找不到的行置灰，不能点开。
    let existingTargetIDs: Set<UUID>

    /// 纸条上能做的事。
    let actions: AIChatResultActions

    /// 入场动效播完。
    let onEntranceFinished: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !snapshot.changes.isEmpty {
                AIChatResultSlip(
                    snapshot: snapshot,
                    isFinished: isFinished,
                    animatesEntrance: animatesEntrance,
                    existingTargetIDs: existingTargetIDs,
                    actions: actions,
                    onEntranceFinished: onEntranceFinished
                )
            } else if let resultText = snapshot.resultText {
                AIChatRevealText(
                    text: resultText,
                    animates: animatesEntrance && !snapshot.isFailed,
                    onFinished: onEntranceFinished
                )
                .font(isQuestion ? Font.system(.title3, design: .serif).weight(.semibold) : Font.body)
                .foregroundStyle(snapshot.isFailed ? Color(.ledgerRed) : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
                .conversationTextSelection()
            }
            if isFinished, let insight = snapshot.insight {
                AIChatInsightCard(insight: insight, animatesEntrance: animatesEntrance)
            }
        }
    }
}

// MARK: - 结果纸条

/// 结果纸条：逐行写入，全部写完才在标题后点上红色句号。撤销时用红笔逐行划掉。
private struct AIChatResultSlip: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 这一轮的展示内容。
    let snapshot: AIChatTurnSnapshot

    /// 这一轮是否处理完了。
    let isFinished: Bool

    /// 是否播放入场动效。
    let animatesEntrance: Bool

    /// 仍然存在的流水和账户。
    let existingTargetIDs: Set<UUID>

    /// 纸条上能做的事。
    let actions: AIChatResultActions

    /// 入场动效播完。
    let onEntranceFinished: () -> Void

    /// 已经写出的行数。
    @State private var revealedCount = 0

    /// 句号是否已经点上。
    @State private var isPeriodShown = false

    /// 正在选账户的一行。
    @State private var pickingChangeID: UUID?

    /// 可以选的账户；展开时读一次。
    @State private var accountOptions: [VoiceAccountOption] = []

    /// 确认账户失败。
    @State private var hasPickFailure = false

    /// 要显示的行。
    private var visibleChanges: ArraySlice<AIChatChangeSnapshot> {
        animatesEntrance ? snapshot.changes.prefix(revealedCount) : snapshot.changes[...]
    }

    /// 入场动效依赖的内容变化。
    private struct RevealKey: Equatable {
        let count: Int
        let isFinished: Bool
        let animates: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(Array(visibleChanges.enumerated()), id: \.element.id) { index, change in
                if index > 0 {
                    Divider()
                }
                row(change, index: index)
                    .transition(
                        reduceMotion ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .offset(x: -14))
                    )
            }
            if hasPickFailure {
                Text(AccountLocalization.string("voice.chat.pick.failed", locale: locale))
                    .font(.caption)
                    .foregroundStyle(Color(.ledgerRed))
                    .padding(.vertical, 4)
            }
            if let undo = actions.undo, !snapshot.isUndone, isFinished {
                Button {
                    AppHaptics.play(.restore)
                    undo()
                } label: {
                    Label(AccountLocalization.string("voice.turn.undo", locale: locale), systemImage: "arrow.uturn.backward")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("voice-undo")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.paperSurface), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .task(id: RevealKey(count: snapshot.changes.count, isFinished: isFinished, animates: animatesEntrance)) {
            await reveal()
        }
    }

    /// 标题：短标题后面跟红色句号；模型自己说的话照常显示全文。
    @ViewBuilder
    private var header: some View {
        if let headline = AIChatCopy.slipHeadline(for: snapshot, locale: locale) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(headline)
                    .font(.system(.title3, design: .serif).weight(.semibold))
                    .contentTransition(.opacity)
                Circle()
                    .fill(snapshot.isUndone ? Color.secondary : Color(.ledgerRed))
                    .frame(width: 6, height: 6)
                    .opacity(isPeriodVisible ? 1 : 0)
                    .scaleEffect(isPeriodVisible ? 1 : 0.4)
                    .accessibilityHidden(true)
            }
            .padding(.bottom, 4)
        } else if let resultText = snapshot.resultText {
            Text(resultText)
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .conversationTextSelection()
                .padding(.bottom, 6)
        }
    }

    /// 句号是否显示：这一轮处理完、所有行都写出来之后。
    private var isPeriodVisible: Bool {
        isFinished && (!animatesEntrance || isPeriodShown)
    }

    /// 一行改动。
    private func row(_ change: AIChatChangeSnapshot, index: Int) -> some View {
        AIChatChangeRow(
            change: change,
            isUndone: snapshot.isUndone,
            strikeDelay: Double(index) * 0.18,
            isAvailable: !snapshot.isUndone
                && change.kind != .deleted
                && change.targetID.map { existingTargetIDs.contains($0) } == true,
            isPicking: pickingChangeID == change.id,
            accountOptions: accountOptions,
            onOpen: { actions.open(change) },
            onTapInferred: { tapInferred(change) },
            onPickAccount: { pick($0, for: change) }
        )
    }

    /// 点待确认：账户就地选，其他字段到详情页改。
    private func tapInferred(_ change: AIChatChangeSnapshot) {
        guard actions.confirmAccount != nil, change.inferredFields.contains(VoiceInferredField.account.rawValue) else {
            actions.open(change)
            return
        }
        hasPickFailure = false
        accountOptions = actions.accountOptions()
        withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.2)) {
            pickingChangeID = pickingChangeID == change.id ? nil : change.id
        }
    }

    /// 选好账户。
    private func pick(_ option: VoiceAccountOption, for change: AIChatChangeSnapshot) {
        guard let accountID = UUID(uuidString: option.id), let confirm = actions.confirmAccount else { return }
        let isConfirmed = confirm(change, accountID)
        hasPickFailure = !isConfirmed
        AppHaptics.play(isConfirmed ? .selection : .error)
        withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.2)) {
            pickingChangeID = nil
        }
    }

    /// 逐行写出，全部写完且这一轮处理完时点上句号。
    private func reveal() async {
        guard animatesEntrance else { return }
        guard !reduceMotion else {
            revealedCount = snapshot.changes.count
            if isFinished {
                isPeriodShown = true
                onEntranceFinished()
            }
            return
        }
        while revealedCount < snapshot.changes.count {
            withAnimation(.spring(duration: 0.42, bounce: 0.25)) {
                revealedCount += 1
            }
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
        }
        guard isFinished else { return }
        withAnimation(.easeOut(duration: 0.3)) {
            isPeriodShown = true
        }
        onEntranceFinished()
    }
}

/// 纸条上的一行：图标、名称、说明和金额。点行看详情，点红色虚线的待确认可以就地改。
private struct AIChatChangeRow: View {
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 这一行的内容。
    let change: AIChatChangeSnapshot

    /// 所在轮次是否已撤销。
    let isUndone: Bool

    /// 撤销时这一行晚多久开始划，几行错开落笔。
    let strikeDelay: Double

    /// 是否可以点开详情。
    let isAvailable: Bool

    /// 是否展开了账户候选。
    let isPicking: Bool

    /// 可以选的账户。
    let accountOptions: [VoiceAccountOption]

    /// 打开详情。
    let onOpen: () -> Void

    /// 点待确认。
    let onTapInferred: () -> Void

    /// 选了一个账户。
    let onPickAccount: (VoiceAccountOption) -> Void

    /// 划掉的笔迹写到哪里。
    @State private var strikeProgress: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: change.symbolName ?? "questionmark")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor.opacity(0.08), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if let action {
                            Text(action)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(change.kind == .deleted ? Color(.ledgerRed) : Color.secondary)
                        }
                        Text(change.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if let inferred, !isUndone {
                        Button(action: onTapInferred) {
                            Text(inferred)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .padding(.bottom, 1.5)
                                .overlay(alignment: .bottom) { AIChatDashedLine() }
                                .frame(minHeight: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("voice-chat-inferred")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let amount = change.formattedAmount {
                    Text(amount)
                        .font(.system(.body, design: .serif).monospacedDigit())
                        .lineLimit(1)
                }
                // 不可用时保留占位，各行金额仍然对齐
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                    .opacity(isAvailable ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isAvailable ? .isButton : [])
            .accessibilityAction {
                if isAvailable { onOpen() }
            }
            .accessibilityActions {
                if let inferred, !isUndone {
                    Button(inferred, action: onTapInferred)
                }
            }
            .opacity(isUndone ? 0.45 : 1)
            .overlay {
                AIChatHandStrike()
                    .trim(from: 0, to: strikeProgress)
                    .stroke(Color(.ledgerRed), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .frame(height: 12)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isAvailable { onOpen() }
            }
            if isPicking {
                LedgerFlowLayout(spacing: 6) {
                    ForEach(accountOptions.filter(\.isActive), id: \.id) { option in
                        Button(option.name) { onPickAccount(option) }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                            .tint(option.name == change.accountName ? Color.accentColor : Color.secondary)
                    }
                }
                .padding(.leading, 42)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .accessibilityIdentifier("voice-chat-account-picks")
            }
        }
        .padding(.vertical, 8)
        .onAppear {
            // 历史记录里已撤销的直接显示划好的样子
            if isUndone { strikeProgress = 1 }
        }
        .onChange(of: isUndone) { _, undone in
            guard undone else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.36).delay(strikeDelay)) {
                strikeProgress = 1
            }
        }
    }

    /// 行首的动作；新增不写，纸条标题已经说了。
    private var action: String? {
        switch change.kind {
        case .created: nil
        case .updated: VoiceEntryChangeText.action(for: .updated, locale: locale)
        case .deleted: VoiceEntryChangeText.action(for: .deleted, locale: locale)
        case .account, .recurring: change.accountAction
        }
    }

    /// 日期和账户，或账户、周期记账改动的说明。
    private var detail: String? {
        guard let transactionDay = change.transactionDay else { return change.accountDetail }
        return VoiceEntryChangeText.detail(
            transactionDay: transactionDay,
            accountName: change.accountName,
            inferredFields: [],
            locale: locale,
            calendar: calendar
        )
    }

    /// 待确认字段的说明。
    private var inferred: String? {
        VoiceEntryChangeText.inferredText(change.inferredFields, locale: locale)
    }
}

/// 红色虚线：标出还没确认的字段，提示可以点。
private struct AIChatDashedLine: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: 0, y: proxy.size.height / 2))
                path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height / 2))
            }
            .stroke(Color(.ledgerRed), style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
        }
        .frame(height: 1.5)
        .accessibilityHidden(true)
    }
}

// MARK: - 查账结果

/// 查账的结果：大数字加分布图。图是单一系列：只高亮选中的一段并标出它的金额，点其他柱子切换。
private struct AIChatInsightCard: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 查询结果。
    let insight: AIChatInsight

    /// 是否播放入场动效。
    let animatesEntrance: Bool

    /// 选中的柱子；默认最新一段。
    @State private var selectedBucketID: Int?

    /// 柱子是否已经长出来。
    @State private var isGrown = false

    /// 柱子的最大高度。
    private static let chartHeight: CGFloat = 72

    /// 当前选中的一段。
    private var selectedBucket: AIChatInsight.Bucket? {
        insight.buckets.first { $0.id == selectedBucketID } ?? insight.buckets.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(insight.title)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(insight.formattedTotal)
                .font(.system(.largeTitle, design: .serif).weight(.medium).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let subtitle {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !insight.buckets.isEmpty {
                chart
                    .padding(.top, 10)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.paperSurface), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .onAppear {
            guard animatesEntrance, !reduceMotion else {
                isGrown = true
                return
            }
            withAnimation(.spring(duration: 0.7, bounce: 0.2).delay(0.15)) {
                isGrown = true
            }
        }
        .accessibilityIdentifier("voice-chat-insight")
    }

    /// 与上一期的差额和收入合计。
    private var subtitle: String? {
        var parts: [String] = []
        if let comparison = insight.comparison {
            parts.append(AccountLocalization.formatted(
                comparison.isLess ? "voice.chat.insight.less" : "voice.chat.insight.more",
                value: comparison.formattedDelta,
                locale: locale
            ))
        }
        if let income = insight.formattedIncome {
            parts.append(AccountLocalization.formatted("voice.chat.insight.income", value: income, locale: locale))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 分布图：只标选中一段的金额，横轴文字放不下时隔一个显示。
    private var chart: some View {
        let maxValue = max(insight.buckets.map(\.value).max() ?? 0, 0.01)
        let labelStride = insight.buckets.count > 7 ? 2 : 1
        return VStack(alignment: .leading, spacing: 6) {
            if let selectedBucket {
                HStack(spacing: 6) {
                    Text(selectedBucket.label)
                        .foregroundStyle(.secondary)
                    Text(selectedBucket.formattedValue)
                        .font(.system(.footnote, design: .serif).weight(.medium).monospacedDigit())
                        .contentTransition(reduceMotion ? .identity : .numericText())
                }
                .font(.footnote)
                .accessibilityHidden(true)
            }
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(insight.buckets.enumerated()), id: \.element.id) { index, bucket in
                    let isSelected = bucket.id == selectedBucket?.id
                    // 倒序数才能保证最新一段总有文字
                    let showsLabel = (insight.buckets.count - 1 - index) % labelStride == 0
                    Button {
                        AppHaptics.play(.selection)
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                            selectedBucketID = bucket.id
                        }
                    } label: {
                        VStack(spacing: 4) {
                            UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4, style: .continuous)
                                .fill(isSelected ? Color(.ledgerRed) : Color.primary.opacity(0.16))
                                .frame(height: isGrown ? barHeight(bucket.value, maxValue: maxValue) : 0)
                                .frame(height: Self.chartHeight, alignment: .bottom)
                            Text(showsLabel ? bucket.label : " ")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: "\(bucket.label) \(bucket.formattedValue)"))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }

    /// 柱子高度：没有金额时不画，有金额时至少看得见。
    private func barHeight(_ value: Double, maxValue: Double) -> CGFloat {
        guard value > 0 else { return 0 }
        return max(3, Self.chartHeight * CGFloat(value / maxValue))
    }
}
