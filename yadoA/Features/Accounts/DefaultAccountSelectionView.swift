import SwiftData
import SwiftUI

/// 选择唯一默认记账账户的列表页。
struct DefaultAccountSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.modelContext) private var modelContext
    @Query private var queriedAccounts: [Account]
    @Query private var preferences: [BookkeepingPreference]
    @State private var isSaveFailed = false

    var body: some View {
        let accounts = AccountListPresentation.sorted(queriedAccounts)
            .filter { $0.isEligibleForDefault }
        let defaultAccountID = BookkeepingPreference.resolvedAccountID(
            preference: preferences.first { $0.id == BookkeepingPreference.singletonID },
            accounts: queriedAccounts
        )

        Group {
            if accounts.isEmpty {
                ContentUnavailableView(
                    AccountLocalization.string("account.management.no_candidate", locale: locale),
                    systemImage: "star.slash"
                )
            } else {
                List(accounts) { account in
                    Button {
                        do {
                            try LocalAccountRepository(container: modelContext.container)
                                .setDefaultAccount(id: account.id)
                            dismiss()
                        } catch {
                            isSaveFailed = true
                        }
                    } label: {
                        AccountListRow(
                            presentation: AccountListPresentation.row(
                                for: account,
                                locale: locale,
                                isDefault: account.id == defaultAccountID
                            )
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("default-account-row-\(account.id.uuidString)")
                }
            }
        }
        .navigationTitle(AccountLocalization.string("account.management.choose_default", locale: locale))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(AccountLocalization.string("common.cancel", locale: locale)) {
                    dismiss()
                }
            }
        }
        .alert(
            AccountLocalization.string("account.default.save_error", locale: locale),
            isPresented: $isSaveFailed
        ) {
            Button(AccountLocalization.string("common.close", locale: locale), role: .cancel) {}
        }
    }
}
