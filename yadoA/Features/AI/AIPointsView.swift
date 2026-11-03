import SwiftData
import SwiftUI
import UIKit

/// “我的 › AI 点数”：当前余额，点数明细、模型和隐私设置的入口，以及扣点规则。
///
/// 内容按用途分组：余额卡片下先是点数明细（`AICreditEntriesView`），再是快捷语音的模型（`AIModelTierView`），
/// 然后是隐私与数据（“帮助改进 AI”的说明较长，单独一页 `AITraceConsentView`；清空本机对话记录就地完成），最后是扣点规则。
/// 点数分好几批、到期时间不同时，余额下的到期提示可以点开，进入到期明细（`AIPointLotsView`）。
/// AI 对话的模型在聊天页的输入栏里单独选，本页不显示；余额是否够用、切换档位的提示都按快捷语音所用的档位算。
///
/// 余额与每轮点数来自根部注入的 `AIPointsStore`。暂不提供充值；点数用完时只说明暂时无法使用 AI 记账。
struct AIPointsView: View {
    @Environment(\.locale) private var locale
    @Environment(\.modelContext) private var modelContext
    @Environment(AuthStore.self) private var authStore
    @Environment(SignInPresentation.self) private var signInPresentation
    /// 当前账号的 AI 点数；预览中没有注入时为 nil。
    @Environment(AIPointsStore.self) private var points: AIPointsStore?

    /// 是否在确认清空对话记录。
    @State private var isClearChatHistoryConfirming = false

    /// 清空对话记录是否失败。
    @State private var isClearChatHistoryFailed = false

    /// 本机是否还有对话记录；没有时清空入口置灰。页面出现时重新读取。
    @State private var hasChatHistory = true

    /// 本次进入页面后是否刚清空过对话记录；清空成功后入口改成“已清空”，作为成功反馈。
    @State private var didClearChatHistory = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                balanceCard

                if authStore.isAuthenticated {
                    entriesSection
                    tierSection
                    privacySection
                }

                rulesSection
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .paperPage()
        .navigationTitle(text("ai.points.title"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await points?.refresh() }
        .task(id: authStore.isAuthenticated) { await points?.refresh() }
        .onAppear {
            hasChatHistory = AIChatHistoryStore(container: modelContext.container).hasRecords()
        }
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

                balanceNotice
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
        .glassSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// 余额数字；还没取到时显示加载中，取不到时显示占位横线。用完时用账本红。
    @ViewBuilder
    private var balanceFigure: some View {
        if let balance = points?.balance {
            Text(balance.formatted(.number.locale(locale)))
                .font(.system(size: 52, weight: .semibold, design: .serif))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(balance)))
                .foregroundStyle(points?.isExhausted(for: .quickVoice) == true ? Color(.ledgerRed) : Color.primary)
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

    /// 余额下方的提示；提示切换档位时可以点开模型选择页，末尾带箭头，其余提示是普通文字。
    @ViewBuilder
    private var balanceNotice: some View {
        if let noticeKey = balanceNoticeKey {
            let notice = Text(text(noticeKey))
                .font(.footnote)
                .foregroundStyle(points?.isExhausted(for: .quickVoice) == true ? Color(.ledgerRed) : Color.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if noticeKey == "ai.points.switchTier" {
                NavigationLink(value: ProfileRoute.aiModelTier) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        notice
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color(.ledgerRed))
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityHint(text("ai.points.switchTier.hint"))
                .accessibilityIdentifier("ai-points-notice")
            } else {
                notice
                    .accessibilityIdentifier("ai-points-notice")
            }
        }
    }

    /// 余额下方提示的文案 key：不够快捷语音所用档位说一句但够更便宜的档位时提示切换，连最便宜的档位都不够时说明暂时无法使用，
    /// 没取到余额时提示下拉重试；正常时不显示。
    private var balanceNoticeKey: String? {
        guard let points else { return nil }
        if points.isExhausted(for: .quickVoice) {
            return points.canAffordCheaperTier(for: .quickVoice) ? "ai.points.switchTier" : "ai.points.exhausted"
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

    // MARK: - 点数明细

    /// 点数明细入口：每一笔点数的增减放在单独一页（`AICreditEntriesView`），本页只留余额和设置。
    private var entriesSection: some View {
        ProfileSettingsSection(nil, seed: "ai.entries") {
            NavigationLink(value: ProfileRoute.aiCreditEntries) {
                ProfileSettingsRow(titleKey: "ai.entries.title", symbol: "list.bullet.rectangle")
            }
            .accessibilityIdentifier("ai-points-entries")
        }
    }

    // MARK: - 模型档位

    /// 快捷语音的模型档位入口：行尾显示当前使用的档位，点开进入模型选择页（`AIModelTierView`）查看各档位特点并切换；
    /// 档位列表还没取到、或可选的档位不到两个时不显示。下方说明这只管快捷语音，AI 对话的模型在聊天页单独选。
    ///
    /// 客户端不认识服务端默认档位时 `displayTier(for:)` 为 nil，行尾留空，不冒充成别的档位。
    @ViewBuilder
    private var tierSection: some View {
        if let points, let tierList = points.tierList, tierList.selectableTiers.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                ProfileSettingsSection("ai.points.section.model") {
                    NavigationLink(value: ProfileRoute.aiModelTier) {
                        ProfileSettingsRow(
                            titleKey: AIModelScope.quickVoice.titleKey,
                            symbol: "cpu",
                            value: points.displayTier(for: .quickVoice).map { text($0.titleKey) } ?? ""
                        )
                    }
                    .accessibilityIdentifier("ai-points-tier")
                }

                footnote(text(AIModelScope.quickVoice.scopeNoteKey))
            }
        }
    }

    // MARK: - 隐私与数据

    /// 隐私与数据：“帮助改进 AI”的入口和清空本机对话记录。
    ///
    /// “帮助改进 AI”默认关闭，开关和上报说明在单独一页（`AITraceConsentView`），这里行尾显示是否开启。
    /// 对话记录只在本机，下方说明不进云同步和备份。
    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProfileSettingsSection("ai.points.section.privacy") {
                if let points {
                    NavigationLink(value: ProfileRoute.aiTraceConsent) {
                        ProfileSettingsRow(
                            titleKey: "ai.traceConsent.title",
                            symbol: "hand.raised",
                            value: text(points.isTraceConsented ? "ai.traceConsent.on" : "ai.traceConsent.off"),
                            valueTint: points.isTraceConsented ? Color(.ledgerGreen) : nil
                        )
                    }
                    .accessibilityIdentifier("ai-points-trace-consent")

                    ProfileSettingsRowDivider()
                }

                clearChatHistoryRow
            }

            footnote(text("ai.chatHistory.footnote"))
        }
        .confirmationDialog(
            text("ai.chatHistory.clear.confirm"),
            isPresented: $isClearChatHistoryConfirming,
            titleVisibility: .visible
        ) {
            Button(text("ai.chatHistory.clear"), role: .destructive) {
                clearChatHistory()
            }
            Button(text("common.cancel"), role: .cancel) {}
        }
        .alert(text("ai.chatHistory.clear.failed"), isPresented: $isClearChatHistoryFailed) {
            Button(text("common.close"), role: .cancel) {}
        }
    }

    /// 清空对话记录的一行：有记录时是红色的清空入口，没有记录时置灰；刚清空成功时换成绿色对勾和“对话记录已清空”，不能再点。
    @ViewBuilder
    private var clearChatHistoryRow: some View {
        if didClearChatHistory {
            Label(text("ai.chatHistory.cleared"), systemImage: "checkmark.circle")
                .labelStyle(ProfileExportLabelStyle(color: Color(.ledgerGreen)))
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .accessibilityIdentifier("ai-points-chat-history-cleared")
        } else {
            Button(role: .destructive) {
                isClearChatHistoryConfirming = true
            } label: {
                Label(text("ai.chatHistory.clear"), systemImage: "trash")
                    .labelStyle(ProfileExportLabelStyle(color: hasChatHistory ? .red : .secondary))
            }
            .disabled(!hasChatHistory)
            .transition(.opacity)
            .accessibilityIdentifier("ai-points-clear-chat-history")
        }
    }

    /// 清空本机对话记录；成功时震一下、读屏播报，并把入口换成“已清空”。
    private func clearChatHistory() {
        do {
            try AIChatHistoryStore(container: modelContext.container).clearAll()
        } catch {
            AppHaptics.play(.error)
            isClearChatHistoryFailed = true
            return
        }
        AppHaptics.play(.destructive)
        UIAccessibility.post(notification: .announcement, argument: text("ai.chatHistory.cleared"))
        hasChatHistory = false
        withAnimation(.snappy(duration: 0.3)) {
            didClearChatHistory = true
        }
    }

    // MARK: - 扣点规则

    /// 扣点规则：每说一句扣一次点、追问也算一句、失败不扣、点数有有效期。
    ///
    /// 快捷语音和 AI 对话可以选不同的档位，每句扣几点因档位而异，这里不写数字，各档位的点数在模型选择页看。
    private var rulesSection: some View {
        ProfileSettingsSection("ai.rules.title") {
            VStack(alignment: .leading, spacing: 14) {
                ruleRow(text("ai.rules.perTurn"), symbol: "mic")
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

    /// 分组卡片下方的说明文字，与卡片内的标题对齐。
    ///
    /// - Parameter content: 说明文案。
    private func footnote(_ content: String) -> some View {
        Text(content)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 20)
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

#Preview {
    NavigationStack { AIPointsView() }
        .environment(AuthStore())
        .environment(SignInPresentation())
}
