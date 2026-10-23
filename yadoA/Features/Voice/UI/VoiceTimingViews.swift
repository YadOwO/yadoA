import SwiftUI

/// 会话卡片中一句话的耗时面板：默认只显示一行概要，点开展开整棵耗时树。
///
/// 只在 `VoiceTimingFeature.isEnabled` 时显示（本地开发包）。
struct VoiceTurnTimingView: View {
    @Environment(\.locale) private var locale

    /// 这句话的耗时。
    let timing: VoiceTurnTiming

    /// 是否展开耗时树。
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "stopwatch")
                    Text(VoiceTimingBreakdown.summary(for: timing, locale: locale))
                        .monospacedDigit()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("voice-turn-timing")

            if isExpanded {
                VoiceTimingRowsView(rows: VoiceTimingBreakdown.rows(for: timing, locale: locale))
                    .padding(10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}

/// 耗时树的各行：名称按层级缩进，说明与耗时靠右。
struct VoiceTimingRowsView: View {
    /// 要显示的行。
    let rows: [VoiceTimingRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(rows) { row in
                VoiceTimingRowView(row: row)
            }
        }
    }
}

/// 耗时树中的一行。
private struct VoiceTimingRowView: View {
    /// 这一行。
    let row: VoiceTimingRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(row.title)
                .foregroundStyle(primaryStyle)
                .padding(.leading, CGFloat(row.depth) * 12)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if let detail = row.detail {
                Text(detail)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(duration)
                .monospacedDigit()
                .foregroundStyle(primaryStyle)
        }
        .font(font)
        .accessibilityElement(children: .combine)
    }

    /// 最外层用主文字色，子阶段用次要文字色。
    private var primaryStyle: Color {
        row.depth == 0 ? .primary : .secondary
    }

    /// 总计行加粗。
    private var font: Font {
        row.isTotal ? .caption.weight(.semibold) : .caption
    }

    private var duration: String {
        guard let durationMs = row.durationMs else { return "-" }
        return VoiceTimingBreakdown.format(durationMs)
    }
}

/// 「我的 → 开发 → 语音耗时」：最近若干句的耗时，可逐句展开、导出成文本或清空。
struct VoiceTimingHistoryView: View {
    @Environment(\.locale) private var locale

    /// 耗时记录。
    var store: VoiceTimingStore = .shared

    /// 是否在确认清空。
    @State private var isClearConfirmationPresented = false

    var body: some View {
        let records = Array(store.records.reversed())
        Group {
            if records.isEmpty {
                ContentUnavailableView(text("voice.timing.history.empty"), systemImage: "stopwatch")
            } else {
                List {
                    Section {
                        Text(statistics(records))
                            .font(.subheadline)
                            .monospacedDigit()
                    }
                    Section {
                        ForEach(records) { record in
                            DisclosureGroup {
                                VoiceTimingRowsView(rows: VoiceTimingBreakdown.rows(for: record, locale: locale))
                                    .padding(.vertical, 4)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(VoiceTimingBreakdown.summary(for: record, locale: locale))
                                        .font(.subheadline.weight(.medium))
                                        .monospacedDigit()
                                    Text(record.recordedAt.formatted(date: .abbreviated, time: .standard))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(text("voice.timing.history.title"))
        .navigationBarTitleDisplayMode(.inline)
        .paperPage()
        .toolbar {
            if !records.isEmpty {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ShareLink(item: VoiceTimingBreakdown.exportText(for: store.records, locale: locale)) {
                        Label(text("voice.timing.history.export"), systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        isClearConfirmationPresented = true
                    } label: {
                        Label(text("voice.timing.history.clear"), systemImage: "trash")
                    }
                }
            }
        }
        .confirmationDialog(
            text("voice.timing.history.clear.confirm"),
            isPresented: $isClearConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(text("voice.timing.history.clear"), role: .destructive) { store.clear() }
        }
    }

    /// 汇总：句数与总耗时的中位数、P95。
    private func statistics(_ records: [VoiceTurnTiming]) -> String {
        guard let stats = VoiceTimingBreakdown.percentiles(records.map(\.totalMs)) else { return "" }
        return String(
            format: text("voice.timing.history.stats"),
            locale: locale,
            records.count,
            VoiceTimingBreakdown.format(stats.p50),
            VoiceTimingBreakdown.format(stats.p95)
        )
    }

    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}
