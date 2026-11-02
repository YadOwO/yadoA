import SwiftUI

/// “我的 › AI 点数 › 到期明细”：未过期的各批点数，带来源、剩余与入账时的点数、到期与获得日期。
///
/// 按过期时间从早到晚排列；扣点先用最早过期的一批，所以列表顺序也就是扣点的顺序。
/// 数据来自根部注入的 `AIPointsStore`，与 AI 点数页的余额同源，下拉刷新时重新查询余额。
struct AIPointLotsView: View {
    @Environment(\.locale) private var locale
    /// 当前账号的 AI 点数；预览中没有注入时为 nil。
    @Environment(AIPointsStore.self) private var points: AIPointsStore?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ProfileSettingsSection(nil, seed: "ai.lots") {
                    if lots.isEmpty {
                        Text(text("ai.lots.empty"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                            .accessibilityIdentifier("ai-lots-empty")
                    } else {
                        // 批次没有 ID，列表很短且只随刷新整体替换，用序号做标识即可
                        ForEach(Array(lots.enumerated()), id: \.offset) { index, lot in
                            if index > 0 {
                                ProfileSettingsRowDivider()
                            }
                            AICreditLotRow(lot: lot)
                        }
                    }
                }
                .accessibilityIdentifier("ai-lots")

                Text(text("ai.lots.footnote"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .paperPage()
        .navigationTitle(text("ai.lots.title"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await points?.refresh() }
    }

    /// 未过期的各批点数，按过期时间从早到晚。
    private var lots: [AICreditLot] {
        points?.activeLots() ?? []
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 到期明细中的一批点数：图标、来源、到期与获得日期，右侧为剩余点数和入账时的点数。
private struct AICreditLotRow: View {
    @Environment(\.locale) private var locale

    /// 展示的批次。
    let lot: AICreditLot

    /// 离过期不到这么久时，到期日期用账本红提醒。
    static let expiringSoonInterval: TimeInterval = 7 * 24 * 60 * 60

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: lot.symbol)
                .font(.system(size: 21, weight: .regular))
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(lot.title(locale: locale))
                    .font(.body)
                Text(dateText("ai.lots.expiresOn", lot.expiresAt))
                    .font(.footnote)
                    .foregroundStyle(isExpiringSoon ? Color(.ledgerRed) : Color.secondary)
                if let createdAt = lot.createdAt {
                    Text(dateText("ai.lots.receivedOn", createdAt))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(lot.points.formatted(.number.locale(locale)))
                    .font(.body.weight(.medium))
                    .monospacedDigit()
                if let originalPoints = lot.originalPoints {
                    Text(
                        AccountLocalization.formatted(
                            "ai.lots.original",
                            value: originalPoints.formatted(.number.locale(locale)),
                            locale: locale
                        )
                    )
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }

    /// 是否快要过期。
    private var isExpiringSoon: Bool {
        lot.expiresAt.timeIntervalSinceNow < Self.expiringSoonInterval
    }

    /// 带日期的一行，例如“2027年1月26日 过期”。
    ///
    /// - Parameters:
    ///   - key: 含一个 `%@` 占位的文案 key。
    ///   - date: 填入的日期，只显示年月日。
    private func dateText(_ key: String, _ date: Date) -> String {
        AccountLocalization.formatted(
            key,
            value: date.formatted(.dateTime.year().month().day().locale(locale)),
            locale: locale
        )
    }
}

#Preview {
    NavigationStack { AIPointLotsView() }
}
