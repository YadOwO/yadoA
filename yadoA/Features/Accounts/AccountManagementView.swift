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

    /// 已停用账户的数量；为 0 时隐藏入口。
    private var deactivatedAccountCount: Int {
        queriedAccounts.count { !$0.isActive && !$0.isUnlinked }
    }

    var body: some View {
        let defaultAccountID = BookkeepingPreference.resolvedAccountID(
            preference: BookkeepingPreference.canonical(in: preferences),
            accounts: queriedAccounts
        )

        LedgerFormPage {
            LedgerCard(seed: 117) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        AccountLocalization.string("account.management.default.title", locale: locale),
                        systemImage: "star.circle.fill"
                    )
                    .font(.system(.headline, design: .serif))

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
                .ledgerCardRow()

                Button {
                    isPresentingDefaultSelection = true
                } label: {
                    Label(
                        AccountLocalization.string("account.management.choose_default", locale: locale),
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .accessibilityIdentifier("account-management-choose-default")

                if !queriedAccounts.contains(where: { $0.isEligibleForDefault }) {
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

            LedgerCard(seed: 119) {
                NavigationLink {
                    AccountTypeOrderView()
                } label: {
                    HStack(spacing: 12) {
                        Label(
                            AccountLocalization.string("account.type_order.title", locale: locale),
                            systemImage: "arrow.up.arrow.down"
                        )
                        .labelStyle(.titleAndIcon)
                        Spacer(minLength: 8)
                        LedgerChevron()
                    }
                    .ledgerCardRow()
                }
                .accessibilityIdentifier("account-management-type-order")

                // 没有已停用账户时不显示入口。
                if deactivatedAccountCount > 0 {
                    NavigationLink {
                        DeactivatedAccountListView()
                    } label: {
                        HStack(spacing: 12) {
                            Label(
                                AccountLocalization.string("account.deactivated.title", locale: locale),
                                systemImage: "archivebox"
                            )
                            .labelStyle(.titleAndIcon)
                            Spacer(minLength: 8)
                            Text(deactivatedAccountCount.formatted())
                                .foregroundStyle(.secondary)
                            LedgerChevron()
                        }
                        .ledgerCardRow()
                    }
                    .accessibilityIdentifier("account-management-deactivated")
                }
            }

            LedgerCard(seed: 118) {
                DataExportEntryView(container: modelContext.container)
                DataImportEntryView(container: modelContext.container)
            }
        }
        .buttonStyle(.plain)
        .labelStyle(LedgerCardRowLabelStyle())
        .navigationTitle(AccountLocalization.string("account.management.title", locale: locale))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(AccountLocalization.string("common.close", locale: locale), systemImage: "xmark") {
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

/// 账户管理中的完整数据导出入口及其确认、分享和失败反馈。
///
/// 标题下一行小字显示上次备份时间；只有分享面板确认完成的导出才算备份。
struct DataExportEntryView: View {
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @StateObject private var flow: DataExportFlow
    @State private var isPresentingConfirmation = false
    /// 上次备份时间戳；写入发生在导出流程里，这里只负责观察并刷新小字。
    @AppStorage(BackupReminderStore.lastExportedAtKey) private var lastExportedAt: Double?

    /// 使用当前应用容器创建导出流程；流程初始化时清扫上次残留文件。
    init(container: ModelContainer) {
        _flow = StateObject(
            wrappedValue: DataExportFlow(
                service: BackupExportService(container: container)
            )
        )
    }

    var body: some View {
        Button {
            isPresentingConfirmation = true
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(AccountLocalization.string("account.management.export.title", locale: locale))
                    Text(
                        BackupStatusText.text(
                            lastBackupAt: BackupReminderStore.date(fromStored: lastExportedAt),
                            now: .now,
                            calendar: calendar,
                            locale: locale
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "square.and.arrow.up")
            }
        }
        .disabled(flow.isPreparing)
        .accessibilityIdentifier("account-management-export-data")
        .dataExportPresentation(flow: flow, isPresentingConfirmation: $isPresentingConfirmation)
    }
}
