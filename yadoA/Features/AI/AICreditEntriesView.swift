import SwiftUI

/// “我的 › AI 点数 › 点数明细”：每一笔点数的增减，按时间倒序，带变动后的余额。
///
/// 进入页面加载第一页，有更早的记录时由用户点按钮加载下一页；下拉刷新时从第一页重新加载。
/// 流水由本页的 `AICreditEntryFeed` 分页加载，只在页面打开期间保存在内存里。
struct AICreditEntriesView: View {
    @Environment(\.locale) private var locale
    /// 当前账号的 AI 点数，用来创建流水分页；预览中没有注入时为 nil。
    @Environment(AIPointsStore.self) private var points: AIPointsStore?

    /// 本页的流水分页；页面出现后创建。
    @State private var feed: AICreditEntryFeed?

    var body: some View {
        ScrollView {
            ProfileSettingsSection(nil, seed: "ai.entries") {
                if let feed, !feed.entries.isEmpty {
                    ForEach(Array(feed.entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            ProfileSettingsRowDivider()
                        }
                        AICreditEntryRow(entry: entry)
                    }

                    if feed.failure != nil {
                        ProfileSettingsRowDivider()
                        failureRow(feed)
                    } else if feed.hasMore {
                        ProfileSettingsRowDivider()
                        loadMoreRow(feed)
                    }
                } else if let feed, feed.failure != nil {
                    failureRow(feed)
                } else if let feed, feed.hasLoaded {
                    Text(text("ai.entries.empty"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .accessibilityIdentifier("ai-entries-empty")
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ai-entries")
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .paperPage()
        .navigationTitle(text("ai.entries.title"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await feed?.reload() }
        // 只在第一次出现时加载；本页没有下一级页面，不会因返回而重复加载
        .task {
            guard feed == nil, let newFeed = points?.makeEntryFeed() else { return }
            feed = newFeed
            await newFeed.reload()
        }
    }

    /// 加载下一页的按钮行；加载中显示转圈。
    ///
    /// 不在滚到底部时自动加载：卡片里是普通 VStack，页脚一渲染就会出现，自动加载会把所有页一次拉完。
    ///
    /// - Parameter feed: 流水分页。
    private func loadMoreRow(_ feed: AICreditEntryFeed) -> some View {
        Button {
            Task { await feed.loadMore() }
        } label: {
            Group {
                if feed.isLoading {
                    ProgressView()
                } else {
                    Text(text("ai.entries.loadMore"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 22)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .disabled(feed.isLoading)
        .accessibilityIdentifier("ai-entries-load-more")
    }

    /// 明细加载失败的一行，带重试按钮。
    ///
    /// - Parameter feed: 出错的流水分页。
    private func failureRow(_ feed: AICreditEntryFeed) -> some View {
        HStack(spacing: 12) {
            Text(text("ai.entries.failed"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(text("common.retry")) {
                Task { await feed.retry() }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .disabled(feed.isLoading)
            .accessibilityIdentifier("ai-entries-retry")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 明细中的一条流水：图标、标题、时间，右侧为带正负号的变动点数和变动后余额。
private struct AICreditEntryRow: View {
    @Environment(\.locale) private var locale

    /// 展示的流水。
    let entry: AICreditEntry

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: entry.symbol)
                .font(.system(size: 21, weight: .regular))
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title(locale: locale))
                    .font(.body)
                Text(Self.formattedTime(entry.createdAt, locale: locale))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(entry.signedPoints(locale: locale))
                    .font(.body.weight(.medium))
                    .monospacedDigit()
                    // 增加按全局正负颜色用正向色；扣点是正常消耗，不上色
                    .amountTone(entry.points > 0 ? .positive : .neutral)
                Text(
                    AccountLocalization.formatted(
                        "ai.entry.balanceAfter",
                        value: entry.balanceAfter.formatted(.number.locale(locale)),
                        locale: locale
                    )
                )
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }

    /// 流水时间：今年的省略年份。
    ///
    /// - Parameters:
    ///   - date: 入账时间。
    ///   - locale: 格式使用的语言环境。
    ///   - now: 当前时间，测试可注入。
    /// - Returns: 例如“10月28日 14:32”。
    static func formattedTime(_ date: Date, locale: Locale, now: Date = .now) -> String {
        let calendar = Calendar.current
        let isThisYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let style = isThisYear
            ? Date.FormatStyle.dateTime.month().day().hour().minute()
            : Date.FormatStyle.dateTime.year().month().day().hour().minute()
        return date.formatted(style.locale(locale))
    }
}

#Preview {
    NavigationStack { AICreditEntriesView() }
}
