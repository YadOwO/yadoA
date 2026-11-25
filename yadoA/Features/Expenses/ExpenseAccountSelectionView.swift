import SwiftData
import SwiftUI

/// 支出流程中的账户选择框，负责选择现有账户或上下文创建首个账户。
///
/// 账户分组之后固定给出「不关联账户」：选它的收支只计入收支统计，不改变任何余额。
struct ExpenseAccountSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.modelContext) private var modelContext
    @Query private var queriedAccounts: [Account]
    /// 记账偏好，用于读取账户分类顺序。
    @Query private var preferences: [BookkeepingPreference]
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
        let order = AccountDisplayOrder(preferences: preferences)
        let accounts = AccountListPresentation.sorted(queriedAccounts, order: order)

        Group {
            if accounts.isEmpty {
                emptyContent
            } else {
                accountList(order.sections(accounts))
            }
        }
        .navigationTitle(
            AccountLocalization.string("expense.account.selection.title", locale: locale)
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(AccountLocalization.string("common.cancel", locale: locale), systemImage: "xmark") {
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
        .paperPage()
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

            Button(action: selectUnlinked) {
                Text(AccountLocalization.string("account.unlinked.name", locale: locale))
            }
            .accessibilityIdentifier("expense-account-selection-unlinked-empty")
        }
    }

    /// 复用账户列表展示转换和共享行，按分类分组，保持名称、类型、尾号与金额语义及顺序一致。
    ///
    /// - Parameter sections: 按统一顺序分好组的启用账户。
    private func accountList(_ sections: [AccountTypeSection]) -> some View {
        LedgerFormPage {
            AccountSectionCards(sections: sections) { account in
                Button {
                    onSelectAccount(account.id)
                    dismiss()
                } label: {
                    AccountListRow(
                        presentation: AccountListPresentation.row(for: account, locale: locale)
                    )
                    .ledgerCardRow()
                }
                .buttonStyle(.plain)
                .disabled(!account.supportsBookkeeping)
                .accessibilityIdentifier("expense-account-selection-row-\(account.id.uuidString)")
            }

            LedgerCard(seed: 919) {
                Button(action: selectUnlinked) {
                    unlinkedRow
                        .ledgerCardRow()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("expense-account-selection-unlinked")
            }
        }
    }

    /// 「不关联账户」一行：图标、名称和「只计入收支，不影响余额」的说明，没有金额。
    private var unlinkedRow: some View {
        let presentation = AccountListPresentation.unlinkedRow(locale: locale)
        return HStack(alignment: .center, spacing: 12) {
            AccountIconView(presentation: presentation.icon)
            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.name)
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                Text(presentation.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// 选中「不关联账户」：本机还没有时先建好再回填，失败时按创建账户失败提示，不改变外层草稿。
    private func selectUnlinked() {
        do {
            let repository = LocalAccountRepository(container: modelContext.container)
            let accountID = try repository.ensureUnlinkedAccount(locale: locale)
            onSelectAccount(accountID)
        } catch {
            onCreationFailed()
        }
        dismiss()
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
