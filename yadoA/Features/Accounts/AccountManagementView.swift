import SwiftData
import SwiftUI
import UIKit

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
                DataExportEntryView(container: modelContext.container)
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

/// 账户管理中的完整数据导出入口及其确认、分享和失败反馈。
private struct DataExportEntryView: View {
    @Environment(\.locale) private var locale
    @StateObject private var flow: DataExportFlow
    @State private var isPresentingConfirmation = false

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
            Label(
                AccountLocalization.string("account.management.export.title", locale: locale),
                systemImage: "square.and.arrow.up"
            )
        }
        .disabled(flow.isPreparing)
        .accessibilityIdentifier("account-management-export-data")
        .alert(
            AccountLocalization.string(
                "account.management.export.warning.title",
                locale: locale
            ),
            isPresented: $isPresentingConfirmation
        ) {
            Button(
                AccountLocalization.string(
                    "account.management.export.title",
                    locale: locale
                )
            ) {
                flow.startExport()
            }
            .accessibilityIdentifier("account-management-export-confirm")

            Button(
                AccountLocalization.string("common.cancel", locale: locale),
                role: .cancel
            ) {}
            .accessibilityIdentifier("account-management-export-cancel")
        } message: {
            Text(
                AccountLocalization.string(
                    "account.management.export.warning.message",
                    locale: locale
                )
            )
        }
        .alert(
            AccountLocalization.string("account.management.export.error", locale: locale),
            isPresented: failurePresented
        ) {
            Button(AccountLocalization.string("common.retry", locale: locale)) {
                flow.retry()
            }

            Button(
                AccountLocalization.string("common.close", locale: locale),
                role: .cancel
            ) {
                flow.dismissFailure()
            }
        }
        .sheet(item: shareItemBinding, onDismiss: flow.finishSharing) { item in
            DataExportShareSheet(url: item.url)
        }
    }

    /// 将状态机中的失败状态转换为系统 Alert 的布尔绑定。
    private var failurePresented: Binding<Bool> {
        Binding(
            get: { flow.failure != nil },
            set: { isPresented in
                if !isPresented {
                    flow.dismissFailure()
                }
            }
        )
    }

    /// 将状态机中的分享 URL 转换为 `.sheet(item:)` 所需的可选绑定。
    private var shareItemBinding: Binding<DataExportShareItem?> {
        Binding(
            get: { flow.shareItem },
            set: { _ in }
        )
    }
}

/// 以系统 UIKit 分享面板呈现备份文件，支持保存到 Files 或分享给其他目标。
private struct DataExportShareSheet: UIViewControllerRepresentable {
    /// 已生成的备份文件地址。
    let url: URL

    /// 创建系统分享面板。
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: [url],
            applicationActivities: nil
        )
    }

    /// 分享面板无须在 SwiftUI 状态变化时更新内容。
    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}
