import Foundation
import SwiftData
import SwiftUI

/// 账户列表顶部的资产汇总卡片，突出净资产并并列展示资产和负债；首次引导的示例也用它。
struct AccountSummaryCard: View {
    @Environment(\.locale) private var locale

    /// 用户选择的启动页面；账户页是启动页时汇总卡片才带装饰。
    @AppStorage(AppStartPage.storageKey) private var startPage: AppStartPage = .home

    let presentation: AccountSummaryPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(
                    AccountLocalization.string(
                        "account.summary.net_assets",
                        locale: locale
                    )
                )
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

                Text(presentation.formattedNetAssets)
                    .font(.system(.largeTitle, design: .serif, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .amountTone(presentation.netAssetsTone)
            }

            HStack(alignment: .top, spacing: 16) {
                AccountSummaryMetric(
                    title: AccountLocalization.string("account.summary.assets", locale: locale),
                    amount: presentation.formattedAssets
                )

                AccountSummaryMetric(
                    title: AccountLocalization.string(
                        "account.summary.liabilities",
                        locale: locale
                    ),
                    amount: presentation.formattedLiabilities,
                    tone: presentation.liabilitiesTone
                )
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // 框内铺纸色，启动页装饰的垫纸只从框的右下边缘露出来。
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(.paperBackground))
            HandDrawnBox(cornerRadius: 22, seed: 21)
                .stroke(
                    Color.primary.opacity(0.85),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                )
        }
        .startPageDecoration(isEnabled: startPage == .accounts, cornerRadius: 22, seed: 21)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityIdentifier("account-list-summary-card")
    }
}

/// 汇总卡片中资产或负债的次级金额指标。
private struct AccountSummaryMetric: View {
    let title: String
    let amount: String

    /// 金额的上色语义；资产保持墨色，有欠款的负债用负向色。
    var tone: AmountTone = .neutral

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(amount)
                .font(.system(.title3, design: .serif, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .amountTone(tone)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
