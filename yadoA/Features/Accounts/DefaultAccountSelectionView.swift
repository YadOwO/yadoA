import SwiftData
import SwiftUI

/// 选择唯一默认记账账户的列表页；没有候选账户时提供添加账户入口。
struct DefaultAccountSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.modelContext) private var modelContext
    @Query private var queriedAccounts: [Account]
    @Query private var preferences: [BookkeepingPreference]
    @State private var isSaveFailed = false

    /// 是否展示空状态发起的添加账户表单。
    @State private var isPresentingCreation = false

    /// 刚创建且符合默认资格的账户；表单关闭后设为默认并返回。
    @State private var createdCandidateID: UUID?

    var body: some View {
        let accounts = AccountListPresentation.sorted(queriedAccounts)
            .filter { $0.isEligibleForDefault }
        let defaultAccountID = BookkeepingPreference.resolvedAccountID(
            preference: preferences.first { $0.id == BookkeepingPreference.singletonID },
            accounts: queriedAccounts
        )

        Group {
            if accounts.isEmpty {
                emptyContent
            } else {
                LedgerFormPage {
                    LedgerCard(seed: 120) {
                        ForEach(accounts) { account in
                            Button {
                                do {
                                    try LocalAccountRepository(container: modelContext.container)
                                        .setDefaultAccount(id: account.id)
                                    AppHaptics.play(.selection)
                                    dismiss()
                                } catch {
                                    AppHaptics.play(.error)
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
                                .ledgerCardRow()
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("default-account-row-\(account.id.uuidString)")
                        }
                    }
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
        .sheet(isPresented: $isPresentingCreation, onDismiss: finishCreation) {
            AccountCreationView { draft in
                try LocalAccountRepository(container: modelContext.container)
                    .save(draft, locale: locale)
                // 投资、负债等类型不能作默认，创建后仍停留在空状态。
                if draft.accountType.isEligibleForDefault {
                    createdCandidateID = draft.id
                }
            }
        }
        .alert(
            AccountLocalization.string("account.default.save_error", locale: locale),
            isPresented: $isSaveFailed
        ) {
            Button(AccountLocalization.string("common.close", locale: locale), role: .cancel) {}
        }
        .paperPage()
    }

    /// 没有可作默认的账户时，说明原因并直接提供添加账户入口。
    private var emptyContent: some View {
        ContentUnavailableView {
            Label {
                Text(AccountLocalization.string("account.default.empty.title", locale: locale))
            } icon: {
                HandDrawnCardIllustration()
            }
        } description: {
            Text(AccountLocalization.string("account.management.no_candidate", locale: locale))
        } actions: {
            Button {
                createdCandidateID = nil
                isPresentingCreation = true
            } label: {
                Label(AccountLocalization.string("account.list.add", locale: locale), systemImage: "plus")
            }
            .accessibilityIdentifier("default-account-empty-add")
        }
        .accessibilityIdentifier("default-account-empty")
    }

    /// 添加表单关闭后，新账户可作默认时直接设为默认并关闭选择页。
    private func finishCreation() {
        guard let accountID = createdCandidateID else { return }
        createdCandidateID = nil
        do {
            // 仓库保存首个合格账户时通常已自动设为默认，这里再显式写一次，保证结果与用户意图一致。
            try LocalAccountRepository(container: modelContext.container)
                .setDefaultAccount(id: accountID)
            dismiss()
        } catch {
            isSaveFailed = true
        }
    }
}
