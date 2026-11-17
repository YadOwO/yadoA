import SwiftData
import SwiftUI

/// 账户页列表中一个分类分组的标题：衬线小标题加一道墨线，与首页日期标题一致。
struct AccountSectionHeader: View {
    /// 已本地化的分类名称。
    let title: String

    /// 墨线的笔迹种子。
    let seed: UInt64

    var body: some View {
        Text(title)
            .font(.system(.callout, design: .serif, weight: .medium))
            .foregroundStyle(Color.primary)
            .padding(.top, 2)
            .accessibilityAddTraits(.isHeader)
            .ledgerHeadingRule(seed: seed)
    }
}

/// 选账户类页面的分组卡片：每个分类一个小标题和一张手绘方框，分组与顺序和账户页一致。
///
/// 放在 `LedgerFormPage` 里使用；行内容由调用方提供，并自行调用 `ledgerCardRow()`。
struct AccountSectionCards<Row: View>: View {
    @Environment(\.locale) private var locale

    /// 由 `AccountDisplayOrder.sections(_:)` 分好的组。
    let sections: [AccountTypeSection]

    /// 一个账户对应的行。
    @ViewBuilder let row: (Account) -> Row

    var body: some View {
        ForEach(sections) { section in
            VStack(alignment: .leading, spacing: 8) {
                Text(section.title(locale: locale))
                    .font(.system(.subheadline, design: .serif, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .accessibilityAddTraits(.isHeader)

                LedgerCard(seed: section.id.handDrawnSeed) {
                    ForEach(section.accounts) { account in
                        row(account)
                    }
                }
            }
        }
    }
}
