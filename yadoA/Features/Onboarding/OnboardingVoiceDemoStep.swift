import SwiftUI

/// 演示：说一句话，同时记两笔、删一笔。
///
/// 全程是脚本：不录音、不联网、不写入账本。示例账本的每一行直接用首页的流水行，
/// 新增标红写对勾、删除划掉后收起，结果提示用语音记账同一套文案，和真正用起来一模一样。
struct OnboardingVoiceDemoStep: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 触感。
    let haptics: OnboardingHaptics

    /// 进入下一行。
    let onContinue: () -> Void

    /// 演示进行到哪一步。
    private enum Phase {
        /// 等用户点示例句。
        case idle
        /// “正在听”，转写逐字出现。
        case listening
        /// 松手发送，正在处理。
        case processing
        /// 按句子里的动作依次改账本。
        case applying
        /// 改完，显示结果提示。
        case done
    }

    @State private var phase = Phase.idle

    /// 标题写完后出现账本和按钮。
    @State private var isDetailVisible = false

    /// 转写已经出现的字数。
    @State private var transcriptLength = 0

    /// 正在执行的那一段话；为空时整句都是墨色。
    @State private var activeSegment: Int?

    /// 示例账本当前的行，最新的在上面。
    @State private var rows: [HomeOverviewRowPresentation] = []

    /// 各行正在播放的提示。
    @State private var marks: [UUID: HomeRowMark] = [:]

    /// 结果提示。
    @State private var summary: String?

    var body: some View {
        OnboardingPage {
            OnboardingInkText(
                text: text("onboarding.voice.title"),
                haptics: haptics,
                onWritten: { isDetailVisible = true }
            )
            .accessibilityAddTraits(.isHeader)

            Text(text("onboarding.voice.message"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
                .onboardingReveal(isDetailVisible)

            ledger
                .padding(.top, 24)
                .onboardingReveal(isDetailVisible, delay: 0.15)

            if phase != .idle {
                voiceCard
                    .padding(.top, 20)
                    .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 16)))
            }

            Text(text("onboarding.voice.footnote"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
                .onboardingReveal(isDetailVisible, delay: 0.3)
        } actions: {
            Group {
                switch phase {
                case .idle:
                    Button {
                        Task { await play() }
                    } label: {
                        Label(text("onboarding.voice.play"), systemImage: "mic.fill")
                    }
                    .buttonStyle(OnboardingPrimaryButtonStyle())
                    .accessibilityIdentifier("onboarding-voice-play")
                case .done:
                    Button(text("onboarding.continue"), action: onContinue)
                        .buttonStyle(OnboardingPrimaryButtonStyle())
                default:
                    Button {} label: {
                        Label(text("voice.processing"), systemImage: "waveform")
                    }
                    .buttonStyle(OnboardingPrimaryButtonStyle())
                    .disabled(true)
                }
            }
            .onboardingReveal(isDetailVisible, delay: 0.3)
            .disabled(!isDetailVisible)
        }
        .onAppear {
            if rows.isEmpty {
                rows = [OnboardingSamples.coffeeRow(locale: locale)]
            }
        }
    }

    // MARK: - 版面

    /// 示例账本：一个“今天”的日期标题，下面是流水行，写法与首页明细相同。
    private var ledger: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(text("onboarding.sample.today"))
                    .font(.system(.callout, design: .serif, weight: .medium))
                Spacer()
                OnboardingSampleBadge()
            }
            .padding(.bottom, 7)
            HandDrawnRule(seed: 71)
                .stroke(Color.primary.opacity(0.6), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                .frame(height: 3)
                .accessibilityHidden(true)

            ForEach(rows) { row in
                let mark = marks[row.id]
                HomeOverviewRowContent(row: row, mark: mark?.kind, markToken: mark?.token)
                    .padding(.vertical, 9)
                    .background(alignment: .bottom) {
                        HandDrawnRule(seed: row.id.handDrawnSeed)
                            .stroke(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                            .frame(height: 3)
                            .opacity(row.id == rows.last?.id ? 0 : 1)
                    }
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                    ))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(row.accessibilityLabel)
            }
        }
        .padding(.horizontal, 2)
    }

    /// 语音卡片：与记账页上的卡片同一种玻璃底，用户的话靠右，结果靠左。
    private var voiceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(text("voice.conversation.title"), systemImage: "waveform")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .symbolEffect(.variableColor.iterative, isActive: phase == .listening && !reduceMotion)

            transcriptBubble
                .frame(maxWidth: .infinity, alignment: .trailing)

            if phase == .processing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(text("voice.processing")).font(.subheadline)
                }
                .transition(.opacity)
            }
            if let summary {
                Text(summary)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 6)))
                    .accessibilityIdentifier("onboarding-voice-summary")
            }
        }
        .padding(14)
        .voiceFloatingSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// 用户说的那句话：识别时逐字出现，执行时正在处理的那一段标成账本红。
    private var transcriptBubble: some View {
        let segments = OnboardingSamples.sentenceSegments(locale: locale)
        let separator = text("onboarding.voice.separator")
        var remaining = transcriptLength
        var sentence = Text(verbatim: "")
        for (index, segment) in segments.enumerated() {
            let piece = index < segments.count - 1 ? segment + separator : segment
            let visible = String(piece.prefix(max(0, remaining)))
            remaining -= piece.count
            let isActive = activeSegment == index
            sentence = sentence + Text(visible)
                .foregroundStyle(isActive ? Color(.ledgerRed) : Color.primary)
                .fontWeight(isActive ? .semibold : .regular)
        }
        return sentence
            .font(.body)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .animation(.easeOut(duration: 0.2), value: activeSegment)
            .accessibilityLabel(segments.joined(separator: separator))
    }

    // MARK: - 演示

    /// 识别 → 发送 → 依次执行三段动作 → 结果提示；每个动作的触感对在笔迹落下的那一刻。
    private func play() async {
        guard phase == .idle else { return }
        let segments = OnboardingSamples.sentenceSegments(locale: locale)
        let separator = text("onboarding.voice.separator")
        let totalLength = segments.joined(separator: separator).count

        // 按下说话
        AppHaptics.play(.begin)
        withAnimation(.spring(duration: 0.4, bounce: 0.15)) {
            phase = .listening
        }
        let speakDuration = reduceMotion ? 0 : 1.8
        if reduceMotion {
            transcriptLength = totalLength
        } else {
            let step = speakDuration / Double(max(totalLength, 1))
            for length in 1...max(totalLength, 1) {
                transcriptLength = length
                try? await Task.sleep(for: .seconds(step))
            }
        }

        // 松手发送
        AppHaptics.play(.commit)
        withAnimation(.easeOut(duration: 0.2)) {
            phase = .processing
        }
        try? await Task.sleep(for: .milliseconds(700))
        withAnimation(.easeOut(duration: 0.2)) {
            phase = .applying
        }

        // 一笔新增：行从上方长出来，等首页行自己的落笔延迟和对勾写完时震一下
        for (index, row) in [OnboardingSamples.lunchRow(locale: locale), OnboardingSamples.taxiRow(locale: locale)].enumerated() {
            activeSegment = index
            withAnimation(.spring(duration: 0.45, bounce: 0.2)) {
                rows.insert(row, at: 0)
                marks[row.id] = HomeRowMark(transactionID: row.id, kind: .added)
            }
            try? await Task.sleep(for: OnboardingSamples.tickLanding)
            haptics.tick()
            try? await Task.sleep(for: .milliseconds(250))
        }

        // 删掉早上那杯咖啡：划线开始时一下，停一会儿后收起
        activeSegment = 2
        let coffee = OnboardingSamples.coffeeRow(locale: locale)
        marks[coffee.id] = HomeRowMark(transactionID: coffee.id, kind: .deleted)
        try? await Task.sleep(for: OnboardingSamples.strikeStart)
        haptics.strike(duration: 0.45)
        try? await Task.sleep(for: .milliseconds(1100))
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
            rows.removeAll { $0.id == coffee.id }
            marks[coffee.id] = nil
        }

        try? await Task.sleep(for: .milliseconds(300))
        withAnimation(.spring(duration: 0.4, bounce: 0.15)) {
            activeSegment = nil
            summary = VoiceSessionSummary.text(forItems: OnboardingSamples.summaryItems(locale: locale), locale: locale)
            phase = .done
        }
        haptics.success()
    }

    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 两个演示共用的示例账目；第 3 步记下的午饭和打车算在第 4 步的数字里，今天一共 60 元。
enum OnboardingSamples {
    /// 新增提示从行出现到对勾写完的时长：首页行先等 0.45 秒再用 0.4 秒写对勾。
    static let tickLanding: Duration = .milliseconds(850)

    /// 删除提示从标记到划线开始的时长，与首页行的落笔延迟一致。
    static let strikeStart: Duration = .milliseconds(450)

    /// 示例句按动作分成的三段：新增午饭、新增打车、删除咖啡。
    static func sentenceSegments(locale: Locale) -> [String] {
        ["onboarding.voice.segment.lunch", "onboarding.voice.segment.taxi", "onboarding.voice.segment.coffee"]
            .map { AccountLocalization.string($0, locale: locale) }
    }

    /// 早上那杯咖啡，演示开始前就在账本里。
    static func coffeeRow(locale: Locale) -> HomeOverviewRowPresentation {
        row(id: coffeeID, category: .dining, noteKey: "onboarding.sample.coffee", amount: 18, locale: locale)
    }

    /// 新记的午饭，微信付。
    static func lunchRow(locale: Locale) -> HomeOverviewRowPresentation {
        row(id: lunchID, category: .dining, noteKey: "onboarding.sample.lunch", amount: 32, locale: locale)
    }

    /// 新记的打车。
    static func taxiRow(locale: Locale) -> HomeOverviewRowPresentation {
        row(id: taxiID, category: .transportation, noteKey: "onboarding.sample.taxi", amount: 28, locale: locale)
    }

    /// 结果提示里的三笔变更，按执行顺序排列。
    static func summaryItems(locale: Locale) -> [VoiceSessionSummary.Item] {
        [
            .init(kind: .created, label: text("onboarding.sample.lunch", locale), formattedAmount: currency(32, locale: locale)),
            .init(kind: .created, label: text("onboarding.sample.taxi", locale), formattedAmount: currency(28, locale: locale)),
            .init(kind: .deleted, label: text("onboarding.sample.coffee", locale), formattedAmount: currency(18, locale: locale)),
        ]
    }

    /// 人民币金额。
    static func currency(_ amount: Decimal, locale: Locale) -> String {
        amount.formatted(.currency(code: "CNY").locale(locale))
    }

    /// 生成一行首页流水：与真实首页一致，主行是备注、副行是分类，支出金额带负号。
    private static func row(
        id: UUID,
        category: ExpenseCategory,
        noteKey: String,
        amount: Decimal,
        locale: Locale
    ) -> HomeOverviewRowPresentation {
        let item = BookkeepingCategoryCatalog.presets.resolvedItem(direction: .expense, key: category.rawValue)
        let lines = BookkeepingEntryLines(note: text(noteKey, locale), categoryTitle: item.title(locale: locale))
        let formattedAmount = currency(-amount, locale: locale)
        return HomeOverviewRowPresentation(
            id: id,
            title: lines.title,
            symbolName: item.symbolName,
            formattedAmount: formattedAmount,
            subtitle: lines.subtitle,
            accessibilityLabel: [lines.title, lines.subtitle, formattedAmount].compactMap { $0 }.joined(separator: ", ")
        )
    }

    private static func text(_ key: String, _ locale: Locale) -> String {
        AccountLocalization.string(key, locale: locale)
    }

    // 固定标识，每次演示的手绘笔迹都一样
    private static let coffeeID = UUID(uuidString: "6F1D2C6E-0000-4000-8000-00000000C0FE")!
    private static let lunchID = UUID(uuidString: "6F1D2C6E-0000-4000-8000-0000000001C4")!
    private static let taxiID = UUID(uuidString: "6F1D2C6E-0000-4000-8000-00000000074A")!
}
