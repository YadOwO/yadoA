import SwiftUI

/// 签到引导：登录后第一次在“我的”页看到签到气泡时，从气泡弹出的说明卡片。
///
/// 告诉用户每天点一下芽豆能随机领 AI 点数，连签还能开礼包；点数范围、有效期和礼包天数都取服务端返回的签到状态，
/// 状态里没有礼包规则（旧服务端）时只说“连续签到还能开礼包”。每个账号只弹一次，是否看过由 `AIPointsStore` 按账号记在本机。
struct CheckInGuideCard: View {
    @Environment(\.locale) private var locale

    /// 当前的签到状态，提供点数范围、有效期和礼包规则。
    let status: AICheckInStatus?

    /// 点“知道了”。
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "leaf.fill")
                    .foregroundStyle(Color(.ledgerGreen))
                    .accessibilityHidden(true)
                Text(text("checkIn.guide.title"))
                    .font(.system(.headline, design: .serif))
                    .accessibilityAddTraits(.isHeader)
            }

            Text(message)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            Text(giftsLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(action: onDismiss) {
                    Text(text("checkIn.guide.dismiss"))
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 6)
                        .onAccentForeground()
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .accessibilityIdentifier("check-in-guide-dismiss")
            }
        }
        .padding(18)
        .frame(width: 280, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("check-in-guide")
    }

    /// “每天点一下芽豆，领取随机 AI 点数，24 小时内有效。”；不写具体能领多少点。
    private var message: String {
        AccountLocalization.formatted(
            "checkIn.guide.message",
            value: (status?.validHours ?? 24).formatted(.number.locale(locale)),
            locale: locale
        )
    }

    /// “连续签到满 7、30、365 天还能开礼包。”；规则不是三档时换成不带天数的说法。
    private var giftsLine: String {
        let days = status?.giftTiers.map(\.everyDays) ?? []
        guard days.count == 3 else { return text("checkIn.guide.giftsGeneric") }
        return String(
            format: text("checkIn.guide.gifts"),
            locale: locale,
            days[0].formatted(.number.locale(locale)),
            days[1].formatted(.number.locale(locale)),
            days[2].formatted(.number.locale(locale))
        )
    }

    /// 按应用当前语言解析文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}
