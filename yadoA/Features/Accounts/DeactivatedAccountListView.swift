import SwiftData
import SwiftUI

/// 展示停用账户的只读入口；详情页保留历史并提供恢复操作。
struct DeactivatedAccountListView: View {
    @Environment(\.locale) private var locale
    @Query private var queriedAccounts: [Account]

    var body: some View {
        let accounts = queriedAccounts
            .filter { !$0.isActive }
            .sorted(by: AccountOrdering.newestFirst)

        Group {
            if accounts.isEmpty {
                ContentUnavailableView(
                    AccountLocalization.string("account.deactivated.empty", locale: locale),
                    systemImage: "archivebox"
                )
            } else {
                List(accounts) { account in
                    // 上级通过视图目标进入此列表，详情沿用同一种导航，避免值路由移除上级页面。
                    NavigationLink {
                        AccountDetailView(accountID: account.id)
                    } label: {
                        AccountListRow(
                            presentation: AccountListPresentation.row(
                                for: account,
                                locale: locale
                            )
                        )
                    }
                    .accessibilityIdentifier("deactivated-account-row-\(account.id.uuidString)")
                }
            }
        }
        .navigationTitle(AccountLocalization.string("account.deactivated.title", locale: locale))
        .navigationBarTitleDisplayMode(.inline)
    }
}
