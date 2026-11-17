import SwiftData
import SwiftUI

/// 首页某一行正在播放的变更提示。
struct HomeRowMark: Equatable {
    /// 三种变更各用一种可区分的纸面动作。
    enum Kind: Equatable {
        /// 新记一笔：账本红 + 图标位置写出对勾。
        case added

        /// 修改：像账本更正一样，把改动的旧值划掉，再换上新值并在下面补一道笔迹。
        ///
        /// 没有修改前快照时只在标题和金额下补笔迹。
        case updated(previous: HomeOverviewRowPresentation?)

        /// 删除：红色墨线划掉整行并变淡，随后收起。
        case deleted
    }

    /// 播放提示的流水标识。
    let transactionID: UUID

    /// 提示类型。
    let kind: Kind

    /// 每次提示的唯一标识；同一笔流水连续两次相同提示时，旧提示到期不会误删新提示。
    let token = UUID()
}

/// 修改提示的播放阶段。
private enum HomeRowRevisionStep {
    /// 展示修改前的值，旧值上的划线逐渐画出。
    case previous

    /// 已换成新值，改动处下方有一道笔迹。
    case revised

    /// 笔迹褪去，回到普通样式。
    case settled
}

/// 一条流水在纸面上的样子，以及新增、修改、删除三种变更提示的动画。
///
/// 首页明细和首次引导里的示例账本共用这一份，引导里看到的就是记账后首页的真实样子。
struct HomeOverviewRowContent: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 已完成本地化的首页行数据。
    let row: HomeOverviewRowPresentation

    /// 当前行正在播放的变更提示；为空时保持默认样式。
    let mark: HomeRowMark.Kind?

    /// 当前提示的唯一标识；从语音卡片再次定位同一笔时提示类型可能不变，靠它从头重播。
    let markToken: UUID?

    /// 新增提示中图标位置手绘对勾的书写进度。
    @State private var tickProgress: CGFloat = 0

    /// 删除或修改提示中旧值划线的书写进度。
    @State private var strikeProgress: CGFloat = 0

    /// 修改提示中新值下方笔迹的书写进度。
    @State private var underlineProgress: CGFloat = 0

    /// 修改提示当前所处的阶段；行首次出现时就处于"旧值"阶段，避免先闪一下新值。
    @State private var revisionStep = HomeRowRevisionStep.previous

    /// 本次新增提示是否已经褪回默认色。
    @State private var hasSettled = false

    /// 当前是否处于"刚记下"的标红状态。
    private var isAddedMarked: Bool {
        mark == .added && !hasSettled
    }

    /// 是否为刚删除流水的残影。
    private var isDeleted: Bool {
        mark == .deleted
    }

    /// 修改提示的字段差异；不是修改提示时为 `nil`。
    private var revision: HomeOverviewRowRevision? {
        guard case let .updated(previous) = mark else { return nil }
        return HomeOverviewRowRevision(previous: previous ?? row, current: row)
    }

    /// 修改提示是否仍在展示旧值。
    private var showsPrevious: Bool {
        revision != nil && revisionStep == .previous
    }

    /// 当前要展示的行内容：修改提示的旧值阶段展示修改前快照，其余时候展示最新数据。
    private var displayed: HomeOverviewRowPresentation {
        showsPrevious ? revision?.previous ?? row : row
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                // 修改了分类时，旧图标以系统替换动画换成新图标。
                Image(systemName: displayed.symbolName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .contentTransition(.symbolEffect(.replace))
                    .opacity(isAddedMarked ? 0 : 1)
                // 标红期间图标位置写出一笔对勾，褪色时再交还给分类图标。
                HandDrawnTick(progress: tickProgress)
                    .frame(width: 24)
                    .opacity(isAddedMarked ? 1 : 0)
            }
            .frame(width: 38, height: 38)
            // 图标垫在随手涂出的色块上，每条流水的色块形状各不相同。
            .background(
                isAddedMarked ? Color(.ledgerRed).opacity(0.12) : Color.accentColor.opacity(0.08),
                in: HandDrawnBlob(seed: row.id.handDrawnSeed)
            )
            .opacity(deletedOpacity)
            .accessibilityHidden(true)

            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
            layout {
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayed.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(isAddedMarked ? Color(.ledgerRed) : Color.primary)
                        .contentTransition(.interpolate)
                        .modifier(revisionMarks(isChanged: revision?.isTitleChanged, marksWithoutVisibleChanges: true, seed: 1))
                    if let subtitle = displayed.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .contentTransition(.interpolate)
                            .modifier(revisionMarks(isChanged: revision?.isSubtitleChanged, marksWithoutVisibleChanges: false, seed: 2))
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // 金额修改时数字逐位滚动到新值。
                Text(displayed.formattedAmount)
                    .font(.system(.body, design: .serif).monospacedDigit())
                    .foregroundStyle(isAddedMarked ? Color(.ledgerRed) : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .contentTransition(.numericText())
                    .modifier(revisionMarks(isChanged: revision?.isAmountChanged, marksWithoutVisibleChanges: true, seed: 3))
                    .layoutPriority(1)
            }
            .opacity(deletedOpacity)
            // 像在账本上把这一笔划掉：一条红色墨线从左到右穿过标题和金额。
            .overlay {
                if isDeleted {
                    HandDrawnRule(seed: row.id.handDrawnSeed)
                        .trim(from: 0, to: strikeProgress)
                        .stroke(Color(.ledgerRed), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        .frame(height: 3)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(minHeight: 44)
        .task(id: markToken) {
            await playMark()
        }
    }
}

extension HomeOverviewRowContent {
    /// 删除残影随划线逐渐变淡，划完后保留约一半的不透明度。
    private var deletedOpacity: Double {
        isDeleted ? 1 - 0.55 * strikeProgress : 1
    }

    /// 为单个字段生成修改提示的笔迹。
    ///
    /// - Parameters:
    ///   - isChanged: 该字段是否改过；不是修改提示时为 `nil`。
    ///   - marksWithoutVisibleChanges: 行上看不出任何变化（例如只改了账户）时是否仍在该字段下补笔迹，告诉用户这一笔改过了。
    ///   - seed: 区分各字段笔迹形状的种子。
    /// - Returns: 旧值阶段划掉改过的字段，新值阶段在其下方补一道笔迹；不需要笔迹时为空。
    private func revisionMarks(
        isChanged: Bool?,
        marksWithoutVisibleChanges: Bool,
        seed: UInt64
    ) -> HomeRowRevisionMarks {
        let isStruck = isChanged == true
        let isUnderlined = isStruck || (marksWithoutVisibleChanges && revision?.hasVisibleChanges == false)
        return HomeRowRevisionMarks(
            seed: row.id.handDrawnSeed &+ seed,
            strikeProgress: isStruck ? strikeProgress : 0,
            isStrikeVisible: isStruck && showsPrevious,
            underlineProgress: isUnderlined ? underlineProgress : 0,
            isUnderlineVisible: isUnderlined && revisionStep == .revised
        )
    }

    /// 按提示类型播放；提示结束时复位，下一次可以从头播放。
    private func playMark() async {
        guard let mark else {
            hasSettled = false
            tickProgress = 0
            strikeProgress = 0
            underlineProgress = 0
            revisionStep = .previous
            return
        }
        // 上一次提示可能还没播完就被新提示替换，先回到起点再播
        hasSettled = false
        tickProgress = 0
        strikeProgress = 0
        underlineProgress = 0
        revisionStep = .previous

        do {
            // 等返回转场结束后再落笔。
            try await Task.sleep(for: .milliseconds(450))
            switch mark {
            case .added:
                draw(duration: 0.4) { tickProgress = 1 }
                try await Task.sleep(for: .milliseconds(1100))
                // 颜色渐变不涉及位移，减少动态效果时同样保留，只是更短。
                withAnimation(.easeInOut(duration: reduceMotion ? 0.6 : 1.2)) {
                    hasSettled = true
                }
            case .updated:
                try await playRevision()
            case .deleted:
                // 删除只负责划掉，收起由首页在停留片刻后统一处理。
                draw(duration: 0.45) { strikeProgress = 1 }
            }
        } catch {
            // 行被回收或提示被取消时直接结束，状态随视图一起丢弃。
        }
    }

    /// 修改提示的节奏：划掉旧值 → 换成新值（图标替换、数字滚动、文字渐变）→ 新值下补一道笔迹 → 笔迹褪去。
    private func playRevision() async throws {
        if revision?.hasVisibleChanges == true {
            draw(duration: 0.35) { strikeProgress = 1 }
            try await Task.sleep(for: .milliseconds(500))
        }
        // 文字和数字的内容过渡不涉及大幅位移，减少动态效果时同样保留，只是更短。
        withAnimation(.smooth(duration: reduceMotion ? 0.2 : 0.5)) {
            revisionStep = .revised
        }
        try await Task.sleep(for: .milliseconds(300))
        draw(duration: 0.4) { underlineProgress = 1 }
        try await Task.sleep(for: .milliseconds(1500))
        withAnimation(.easeInOut(duration: reduceMotion ? 0.4 : 0.8)) {
            revisionStep = .settled
        }
    }

    /// 以书写动画推进一笔笔迹；减少动态效果时直接画完。
    ///
    /// - Parameters:
    ///   - duration: 书写时长。
    ///   - update: 把对应进度设为完成的状态修改。
    private func draw(duration: Double, _ update: () -> Void) {
        if reduceMotion {
            update()
        } else {
            withAnimation(.easeInOut(duration: duration), update)
        }
    }
}

/// 修改提示落在单个字段上的笔迹：旧值上一道细划线，新值下一道细下划线。
///
/// 两道线都只用墨色细线，和账本上手写更正的样子一致；收起时整道线淡出，而不是倒着擦掉。
private struct HomeRowRevisionMarks: ViewModifier {
    /// 笔迹种子。
    let seed: UInt64

    /// 旧值划线的书写进度。
    let strikeProgress: CGFloat

    /// 旧值划线是否可见；换成新值时随旧值一起淡出。
    let isStrikeVisible: Bool

    /// 新值下划线的书写进度。
    let underlineProgress: CGFloat

    /// 新值下划线是否可见；提示收尾时淡出。
    let isUnderlineVisible: Bool

    func body(content: Content) -> some View {
        content
            .overlay {
                HandDrawnRule(seed: seed)
                    .trim(from: 0, to: strikeProgress)
                    .stroke(Color.primary.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                    .frame(height: 3)
                    .opacity(isStrikeVisible ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .bottom) {
                HandDrawnRule(seed: seed &+ 7)
                    .trim(from: 0, to: underlineProgress)
                    .stroke(Color.primary.opacity(0.45), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                    .frame(height: 3)
                    .offset(y: 4)
                    .opacity(isUnderlineVisible ? 1 : 0)
                    .accessibilityHidden(true)
            }
    }
}
