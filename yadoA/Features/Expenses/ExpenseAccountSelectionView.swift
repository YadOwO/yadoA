import SwiftData
import SwiftUI

/// 餐饮支出流程中的账户选择框，负责选择现有账户或上下文创建首个账户。
struct ExpenseAccountSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.modelContext) private var modelContext
    @Query private var queriedAccounts: [Account]
    @State private var isPresentingCreation = false
    @State private var creationResult: ContextualAccountCreationResult?

    /// 选中账户后只向外层记账流程回传稳定 UUID。
    private let onSelectAccount: @MainActor (UUID) -> Void

    /// 上下文创建失败后回传轻提醒，不改变外层记账草稿。
    private let onCreationFailed: @MainActor () -> Void

    /// 创建账户选择页。
    ///
    /// - Parameters:
    ///   - onSelectAccount: 选中已有账户或成功创建首个账户后的回填动作。
    ///   - onCreationFailed: 上下文创建失败后的提示动作。
    init(
        onSelectAccount: @escaping @MainActor (UUID) -> Void,
        onCreationFailed: @escaping @MainActor () -> Void
    ) {
        self.onSelectAccount = onSelectAccount
        self.onCreationFailed = onCreationFailed
    }

    var body: some View {
        let accounts = AccountListPresentation.sorted(queriedAccounts)

        Group {
            if accounts.isEmpty {
                emptyContent
            } else {
                accountList(accounts)
            }
        }
        .navigationTitle(
            AccountLocalization.string("expense.account.selection.title", locale: locale)
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(AccountLocalization.string("common.cancel", locale: locale)) {
                    dismiss()
                }
            }
        }
        .sheet(isPresented: $isPresentingCreation, onDismiss: finishContextualCreation) {
            AccountCreationView(
                save: { draft in
                    let repository = LocalAccountRepository(container: modelContext.container)
                    try repository.save(draft, locale: locale)
                },
                onContextResult: { result in
                    creationResult = result
                }
            )
        }
    }

    /// 当前没有账户时展示唯一的上下文创建入口。
    private var emptyContent: some View {
        ContentUnavailableView {
            Label(
                AccountLocalization.string("account.list.empty.title", locale: locale),
                systemImage: "tray"
            )
        } description: {
            Text(AccountLocalization.string("account.list.empty.message", locale: locale))
        } actions: {
            Button {
                creationResult = nil
                isPresentingCreation = true
            } label: {
                Label(
                    AccountLocalization.string("account.list.add", locale: locale),
                    systemImage: "plus"
                )
            }
            .accessibilityIdentifier("expense-account-selection-create")
        }
    }

    /// 复用账户列表展示转换和共享行，保持名称、类型、尾号与金额语义一致。
    private func accountList(_ accounts: [Account]) -> some View {
        List(accounts) { account in
            Button {
                onSelectAccount(account.id)
                dismiss()
            } label: {
                AccountListRow(
                    presentation: AccountListPresentation.row(for: account, locale: locale)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(account.accountType == nil)
            .accessibilityIdentifier("expense-account-selection-row-\(account.id.uuidString)")
        }
    }

    /// 创建 sheet 关闭后统一返回记账页；只有成功结果会替换所选账户。
    private func finishContextualCreation() {
        if case let .saved(accountID) = creationResult {
            onSelectAccount(accountID)
        } else if creationResult == .failed {
            onCreationFailed()
        }
        creationResult = nil
        dismiss()
    }
}
