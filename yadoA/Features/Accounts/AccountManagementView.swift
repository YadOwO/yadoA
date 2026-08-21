import SwiftData
import SwiftUI

/// 账户生命周期与默认账户的集中管理入口。
struct AccountManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.modelContext) private var modelContext
    @Query private var queriedAccounts: [Account]
    @Query private var preferences: [BookkeepingPreference]
    @State private var isPresentingDefaultSelection = false
    @State private var isPresentingCreation = false

    var body: some View {
        let accounts = AccountListPresentation.sorted(queriedAccounts)
        let defaultAccountID = BookkeepingPreference.resolvedAccountID(
            preference: preferences.first { $0.id == BookkeepingPreference.singletonID },
            accounts: queriedAccounts
        )

        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        AccountLocalization.string("account.management.default.title", locale: locale),
                        systemImage: "star.circle.fill"
                    )
                    .font(.headline)

                    Text(AccountLocalization.string("account.management.default.message", locale: locale))
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if let defaultAccountID,
                       let account = queriedAccounts.first(where: { $0.id == defaultAccountID })
                    {
                        AccountListRow(
                            presentation: AccountListPresentation.row(
                                for: account,
                                locale: locale,
                                isDefault: true
                            )
                        )
                    } else {
                        Text(AccountLocalization.string("account.management.no_default", locale: locale))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)

                Button {
                    isPresentingDefaultSelection = true
                } label: {
                    Label(
                        AccountLocalization.string("account.management.choose_default", locale: locale),
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .accessibilityIdentifier("account-management-choose-default")

                if !accounts.contains(where: { $0.isEligibleForDefault }) {
                    Button {
                        isPresentingCreation = true
                    } label: {
                        Label(
                            AccountLocalization.string("account.list.add", locale: locale),
                            systemImage: "plus"
                        )
                    }
                    .accessibilityIdentifier("account-management-create-account")
                }
            }

            Section {
                NavigationLink {
                    DeactivatedAccountListView()
                } label: {
                    Label(
                        AccountLocalization.string("account.deactivated.title", locale: locale),
                        systemImage: "archivebox"
                    )
                    Spacer()
                    Text(queriedAccounts.filter { !$0.isActive }.count.formatted())
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("account-management-deactivated")
            }
        }
        .navigationTitle(AccountLocalization.string("account.management.title", locale: locale))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(AccountLocalization.string("common.close", locale: locale)) {
                    dismiss()
                }
                .accessibilityIdentifier("account-management-close")
            }
        }
        .sheet(isPresented: $isPresentingDefaultSelection) {
            NavigationStack {
                DefaultAccountSelectionView()
            }
        }
        .sheet(isPresented: $isPresentingCreation) {
            AccountCreationView { draft in
                try LocalAccountRepository(container: modelContext.container)
                    .save(draft, locale: locale)
            }
        }
    }
}
