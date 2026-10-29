import SwiftUI

/// “我的 › AI 点数 › AI 模型”：列出可选的模型档位及各自特点，点选后保存在本机。
///
/// 每个档位显示名称、每句扣的点数、一句话特点和几条具体说明，服务端的默认档位带“默认”标记；
/// 客户端不认识或服务端未配置好的档位不显示。以后接入新档位时只需在 `AIModelTier` 补上文案，本页自动列出。
/// 档位列表与所选档位来自根部注入的 `AIPointsStore`，下拉刷新时重新查询。
struct AIModelTierView: View {
    @Environment(\.locale) private var locale
    /// 当前账号的 AI 点数；预览中没有注入时为 nil。
    @Environment(AIPointsStore.self) private var points: AIPointsStore?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ProfileSettingsSection(nil, seed: "ai.tier.list") {
                    if let points, let tierList = points.tierList {
                        if tierList.selectableTiers.isEmpty {
                            Text(text("ai.tier.empty"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                                .accessibilityIdentifier("ai-tier-empty")
                        } else {
                            ForEach(Array(tierList.selectableTiers.enumerated()), id: \.element) { index, tier in
                                if index > 0 {
                                    ProfileSettingsRowDivider()
                                }
                                tierRow(tier, in: tierList, isSelected: tier == points.displayTier)
                            }
                        }
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                }
                .accessibilityIdentifier("ai-tier-list")

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

    /// 一个档位：图标、名称与默认标记、每句点数、一句话特点和具体特点，选中的在行尾打勾，整行可点。
    ///
    /// - Parameters:
    ///   - tier: 档位。
    ///   - tierList: 服务端的档位列表，用来取每句点数和默认档位。
    ///   - isSelected: 是否为当前使用的档位。
    private func tierRow(_ tier: AIModelTier, in tierList: AIModelTierList, isSelected: Bool) -> some View {
        Button {
            points?.selectTier(tier)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Image(systemName: tier.symbol)
                    .font(.system(size: 21, weight: .regular))
                    .frame(width: 28)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(text(tier.titleKey))
                                .font(.body.weight(.medium))
                            if tier.rawValue == tierList.defaultTier {
                                defaultBadge
                            }
                        }
                        if let pointsPerTurn = tierList.pointsPerTurn(for: tier.rawValue) {
                            Text(
                                AccountLocalization.formatted(
                                    "ai.tier.perTurn",
                                    value: pointsPerTurn.formatted(.number.locale(locale)),
                                    locale: locale
                                )
                            )
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
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
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("ai-tier-\(tier.rawValue)")
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
