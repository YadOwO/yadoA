import SwiftUI

/// “我的 › AI 点数”：当前余额、模型档位入口、扣点规则和点数明细。
///
/// 点数分好几批、到期时间不同时，余额下的到期提示可以点开，进入到期明细（`AIPointLotsView`）；
/// 模型档位行点开进入模型选择页（`AIModelTierView`）。
///
/// 余额与每轮点数来自根部注入的 `AIPointsStore`，明细由本页的 `AICreditEntryFeed` 分页加载。
/// 暂不提供充值；点数用完时只说明暂时无法使用 AI 记账。
struct AIPointsView: View {
    @Environment(\.locale) private var locale
    @Environment(AuthStore.self) private var authStore
    @Environment(SignInPresentation.self) private var signInPresentation
    /// 当前账号的 AI 点数；预览中没有注入时为 nil。
    @Environment(AIPointsStore.self) private var points: AIPointsStore?

    /// 本页的流水分页；已登录时在页面出现后创建，退出登录时丢弃。
    @State private var feed: AICreditEntryFeed?

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                balanceCard

                if authStore.isAuthenticated {
                    tierSection
                }

                rulesSection

                if authStore.isAuthenticated {
                    entriesSection
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .paperPage()
        .navigationTitle(text("ai.points.title"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
        .task(id: authStore.isAuthenticated) { await refresh() }
    }

    // MARK: - 余额

    /// 页顶的余额卡片：已登录时显示余额和用完提示，未登录时引导登录。
    private var balanceCard: some View {
        VStack(spacing: 12) {
            if authStore.isAuthenticated {
                VStack(spacing: 6) {
                    VStack(spacing: 6) {
                        balanceFigure
                            .frame(minHeight: 64)

                        Text(text("ai.points.balance.caption"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("ai-points-balance")

                    expiryLine
                }

                if let noticeKey = balanceNoticeKey {
                    Text(text(noticeKey))
                        .font(.footnote)
                        .foregroundStyle(points?.isExhausted == true ? Color(.ledgerRed) : Color.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ai-points-notice")
                }
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)

                VStack(spacing: 4) {
                    Text(text("ai.points.signedOut.title"))
                        .font(.headline)
                    Text(text("ai.points.signedOut.message"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)

                signInButton
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .aiPointsSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// 余额数字；还没取到时显示加载中，取不到时显示占位横线。用完时用账本红。
    @ViewBuilder
    private var balanceFigure: some View {
        if let balance = points?.balance {
            Text(balance.formatted(.number.locale(locale)))
                .font(.system(size: 52, weight: .semibold, design: .serif))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(balance)))
                .foregroundStyle(points?.isExhausted == true ? Color(.ledgerRed) : Color.primary)
                .animation(.default, value: balance)
        } else if points?.isRefreshing == true {
            ProgressView()
        } else {
            Text(verbatim: "—")
                .font(.system(size: 52, weight: .semibold, design: .serif))
                .foregroundStyle(.tertiary)
        }
    }

    /// 余额下的到期提示：只有一批时是普通文字；有好几批时可以点开到期明细，末尾带箭头。
    @ViewBuilder
    private var expiryLine: some View {
        if let expiryText {
            if let points, points.activeLots().count > 1 {
                NavigationLink(value: ProfileRoute.aiPointLots) {
                    HStack(spacing: 4) {
                        Text(expiryText)
                            .multilineTextAlignment(.center)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .accessibilityHint(text("ai.points.expiry.hint"))
                .accessibilityIdentifier("ai-points-expiry")
            } else {
                Text(expiryText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("ai-points-expiry")
            }
        }
    }

    /// 最近一批要过期的点数，例如“100 点将于 2027年1月26日 过期”；没有余额或服务端没返回批次时不显示。
    private var expiryText: String? {
        guard let lot = points?.nextExpiringLot() else { return nil }
        return String(
            format: text("ai.points.expiry"),
            locale: locale,
            lot.points.formatted(.number.locale(locale)),
            lot.expiresAt.formatted(.dateTime.year().month().day().locale(locale))
        )
    }

    /// 余额下方的提示：不够所用档位说一句但够更便宜的档位时提示切换，连最便宜的档位都不够时说明暂时无法使用，
    /// 没取到余额时提示下拉重试；正常时不显示。
    private var balanceNoticeKey: String? {
        guard let points else { return nil }
        if points.isExhausted {
            return points.canAffordCheaperTier ? "ai.points.switchTier" : "ai.points.exhausted"
        }
        if points.balance == nil, points.failure != nil {
            return "ai.points.loadFailed"
        }
        return nil
    }

    /// 打开登录 / 注册页的按钮。
    private var signInButton: some View {
        Button {
            signInPresentation.present()
        } label: {
            Text(text("auth.sign_in.action"))
                .font(.body.weight(.medium))
                .padding(.horizontal, 8)
                .onAccentForeground()
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .disabled(authStore.isBusy)
        .accessibilityIdentifier("ai-points-sign-in")
    }

    // MARK: - 模型档位

    /// 模型档位入口：行尾显示当前使用的档位，点开进入模型选择页（`AIModelTierView`）查看各档位特点并切换；
    /// 档位列表还没取到、或可选的档位不到两个时不显示。
    ///
    /// 客户端不认识服务端默认档位时 `displayTier` 为 nil，行尾留空，不冒充成别的档位。
    @ViewBuilder
    private var tierSection: some View {
        if let points, let tierList = points.tierList, tierList.selectableTiers.count > 1 {
            ProfileSettingsSection(nil, seed: "ai.tier") {
                NavigationLink(value: ProfileRoute.aiModelTier) {
                    ProfileSettingsRow(
                        titleKey: "ai.tier.title",
                        symbol: "cpu",
                        value: points.displayTier.map { text($0.titleKey) } ?? ""
                    )
                }
                .accessibilityIdentifier("ai-points-tier")
            }
        }
    }

    // MARK: - 扣点规则

    /// 扣点规则：每说一句扣几点、追问也算一句、失败不扣、点数有有效期。
    private var rulesSection: some View {
        ProfileSettingsSection("ai.rules.title") {
            VStack(alignment: .leading, spacing: 14) {
                ruleRow(perTurnRule, symbol: "mic")
                ruleRow(text("ai.rules.followUp"), symbol: "bubble.left.and.bubble.right")
                ruleRow(text("ai.rules.free"), symbol: "checkmark.seal")
                ruleRow(text("ai.rules.expiry"), symbol: "hourglass")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .accessibilityIdentifier("ai-points-rules")
    }

    /// 按所用档位每说一句扣几点；还不知道每轮点数时用不带数字的说法。
    private var perTurnRule: String {
        guard let pointsPerTurn = points?.pointsPerTurn else {
            return text("ai.rules.perTurn.unknown")
        }
        return AccountLocalization.formatted(
            "ai.rules.perTurn",
            value: pointsPerTurn.formatted(.number.locale(locale)),
            locale: locale
        )
    }

    /// 一条规则：图标列与设置行对齐，文字可换行。
    ///
    /// - Parameters:
    ///   - content: 规则文案。
    ///   - symbol: 图标。
    private func ruleRow(_ content: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(content)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 明细

    /// 点数明细：首页加载中、失败、为空和列表四种状态；有更早的记录时由用户点按钮加载下一页。
    ///
    /// 不在滚到底部时自动加载：卡片里是普通 VStack，页脚一渲染就会出现，自动加载会把所有页一次拉完。
    private var entriesSection: some View {
        ProfileSettingsSection("ai.entries.title") {
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
                    .accessibilityIdentifier("ai-points-entries-empty")
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
        }
        .accessibilityIdentifier("ai-points-entries")
    }

    /// 加载下一页的按钮行；加载中显示转圈。
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
        .accessibilityIdentifier("ai-points-entries-load-more")
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
            .accessibilityIdentifier("ai-points-entries-retry")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - 刷新

    /// 刷新余额和明细：先刷新余额（首次查询时服务端才建钱包、发新用户赠送），再从第一页重新加载明细。
    private func refresh() async {
        guard authStore.isAuthenticated else {
            feed = nil
            await points?.refresh()
            return
        }
        if feed == nil {
            feed = points?.makeEntryFeed()
        }
        await points?.refresh()
        await feed?.reload()
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
                    // 增加用账本绿；扣点是正常消耗，不用红色
                    .foregroundStyle(entry.points > 0 ? Color(.ledgerGreen) : Color.primary)
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

/// 余额卡片底色：iOS 26 用 Liquid Glass，iOS 18 用常规材质。
private struct AIPointsSurface<SurfaceShape: Shape>: ViewModifier {
    /// 底色形状。
    let shape: SurfaceShape

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

private extension View {
    /// 给余额卡片加上玻璃或材质底色。
    func aiPointsSurface<SurfaceShape: Shape>(in shape: SurfaceShape) -> some View {
        modifier(AIPointsSurface(shape: shape))
    }
}

#Preview {
    NavigationStack { AIPointsView() }
        .environment(AuthStore())
        .environment(SignInPresentation())
}
