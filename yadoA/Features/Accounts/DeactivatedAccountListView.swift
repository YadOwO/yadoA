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
                    NavigationLink(value: account.id) {
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
        .navigationDestination(for: UUID.self) { accountID in
            AccountDetailView(accountID: accountID)
        }
    }
}
