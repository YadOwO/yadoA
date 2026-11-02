import SwiftUI

/// “我的 › AI 点数 › AI 模型”：每个可选的模型档位一张卡片，介绍特点、每句点数和按余额还能说几句，点选后保存在本机。
///
/// 卡片显示名称、每句扣的点数、按当前余额还能说几句、一句话特点和几条具体说明，服务端的默认档位带“默认”标记；
/// 选中的卡片用浅底色和加粗边框标出。客户端不认识或服务端未配置好的档位不显示。
/// 以后接入新档位时只需在 `AIModelTier` 补上文案，本页自动列出。
/// 档位列表、余额与所选档位来自根部注入的 `AIPointsStore`，下拉刷新时重新查询。
/// 除了 AI 点数页，语音记账因点数不够所用档位而失败时也会以弹层打开本页。
struct AIModelTierView: View {
    @Environment(\.locale) private var locale
    /// 当前账号的 AI 点数；预览中没有注入时为 nil。
    @Environment(AIPointsStore.self) private var points: AIPointsStore?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let points, let tierList = points.tierList {
                    if tierList.selectableTiers.isEmpty {
                        ProfileSettingsSection(nil, seed: "ai.tier.empty") {
                            Text(text("ai.tier.empty"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                        }
                        .accessibilityIdentifier("ai-tier-empty")
                    } else {
                        ForEach(tierList.selectableTiers) { tier in
                            tierCard(
                                tier,
                                in: tierList,
                                turnsLeft: points.turnsLeft(for: tier),
                                isSelected: tier == points.displayTier
                            )
                        }
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }

                Text(text("ai.tier.footnote"))
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
        .navigationTitle(text("ai.tier.title"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await points?.refresh() }
        // 只跟用户的选择震动；刷新后默认档位变化引起的勾选变化不震
        .appHaptic(.selection, trigger: points?.selectedTier)
    }

    // MARK: - 卡片

    /// 一个档位的卡片：图标、名称与默认标记、点数信息、一句话特点和具体特点，选中的打勾并加强调底色，整张可点。
    ///
    /// - Parameters:
    ///   - tier: 档位。
    ///   - tierList: 服务端的档位列表，用来取每句点数和默认档位。
    ///   - turnsLeft: 按当前余额还能说几句；还没取到余额时为 nil，不显示。
    ///   - isSelected: 是否为当前使用的档位。
    private func tierCard(
        _ tier: AIModelTier,
        in tierList: AIModelTierList,
        turnsLeft: Int?,
        isSelected: Bool
    ) -> some View {
        let pointsPerTurn = tierList.pointsPerTurn(for: tier.rawValue)
        return Button {
            points?.selectTier(tier)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Image(systemName: tier.symbol)
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .frame(width: 28)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(text(tier.titleKey))
                                .font(.system(.title3, design: .serif, weight: .semibold))
                            if tier.rawValue == tierList.defaultTier {
                                defaultBadge
                            }
                        }
                        if let pointsPerTurn {
                            Text(pointsLine(pointsPerTurn: pointsPerTurn, turnsLeft: turnsLeft))
                                .font(.footnote)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Text(text(tier.summaryKey))
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(tier.highlights) { highlight in
                            highlightRow(highlight)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // 不选中时也占位，切换时文字不跳动
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .background { cardBackground(seed: "ai.tier.\(tier.rawValue)".handDrawnSeed, isSelected: isSelected) }
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.2), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("ai-tier-\(tier.rawValue)")
    }

    /// 卡片的手绘底框：选中时加浅强调色底、边框加粗加深，与首次引导里的选项一致。
    ///
    /// - Parameters:
    ///   - seed: 笔迹种子，每个档位固定。
    ///   - isSelected: 是否选中。
    private func cardBackground(seed: UInt64, isSelected: Bool) -> some View {
        ZStack {
            HandDrawnBox(cornerRadius: 16, seed: seed)
                .fill(Color.accentColor.opacity(isSelected ? 0.1 : 0))
            HandDrawnBox(cornerRadius: 16, seed: seed)
                .stroke(
                    Color.primary.opacity(isSelected ? 0.9 : 0.4),
                    style: StrokeStyle(lineWidth: isSelected ? 1.8 : 1.1, lineCap: .round, lineJoin: .round)
                )
        }
    }

    /// 点数信息，例如“每句 2 点 · 余额可说 49 句”；余额不够说一句时后半句用账本红提醒，还没取到余额时只显示每句点数。
    ///
    /// 拼成一段富文本而不是并排几个 `Text`，大字号下可以整体换行。
    ///
    /// - Parameters:
    ///   - pointsPerTurn: 该档位每句扣的点数。
    ///   - turnsLeft: 按当前余额还能说几句；为 nil 时不显示后半句。
    private func pointsLine(pointsPerTurn: Int, turnsLeft: Int?) -> AttributedString {
        var line = AttributedString(
            AccountLocalization.formatted(
                "ai.tier.perTurn",
                value: pointsPerTurn.formatted(.number.locale(locale)),
                locale: locale
            )
        )
        guard let turnsLeft else { return line }

        line += AttributedString(" · ")
        if turnsLeft > 0 {
            line += AttributedString(
                AccountLocalization.formatted(
                    "ai.tier.turnsLeft",
                    value: turnsLeft.formatted(.number.locale(locale)),
                    locale: locale
                )
            )
        } else {
            var warning = AttributedString(text("ai.tier.turnsLeft.none"))
            warning.swiftUI.foregroundColor = Color(.ledgerRed)
            line += warning
        }
        return line
    }

    /// 服务端默认档位名称后的小标签：用户没选过档位时用的就是它。
    private var defaultBadge: some View {
        Text(text("ai.tier.default"))
            .font(.caption2.weight(.medium))
            .foregroundStyle(.tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.14), in: Capsule())
    }

    /// 一条特点：小图标与说明首行对齐，说明可换行。
    ///
    /// - Parameter highlight: 特点。
    private func highlightRow(_ highlight: AIModelTierHighlight) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: highlight.symbol)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(text(highlight.textKey))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

#Preview {
    NavigationStack { AIModelTierView() }
}
