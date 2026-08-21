import Combine
import SwiftData
import SwiftUI

/// 账户资料编辑流程注入的显式保存动作。
typealias AccountEditSaveAction = @MainActor (AccountEditDraft) async throws -> Void

/// 编辑表单提交期间的状态，用于防止重复保存并保留可重试错误。
enum AccountEditSubmissionState: Equatable {
    /// 用户正在编辑资料。
    case editing

    /// 正在执行显式保存。
    case saving

    /// 最近一次保存失败。
    case failed
}

/// 持有账户资料编辑草稿并串行协调显式保存。
@MainActor
final class AccountEditFlow: ObservableObject {
    /// 当前编辑中的单份账户资料草稿。
    @Published var draft: AccountEditDraft

    /// 当前提交状态；保存进行中时拒绝后续提交。
    @Published private(set) var submissionState: AccountEditSubmissionState = .editing

    /// 由详情页注入的持久化动作。
    private let saveAction: AccountEditSaveAction

    /// 创建一条可测试的账户资料编辑提交流程。
    init(
        draft: AccountEditDraft,
        saveAction: @escaping AccountEditSaveAction
    ) {
        self.draft = draft
        self.saveAction = saveAction
    }

    /// 当前是否正在执行显式保存。
    var isSaving: Bool {
        submissionState == .saving
    }

    /// 最近一次保存是否失败，需要保留草稿并允许重试。
    var hasSaveError: Bool {
        submissionState == .failed
    }

    /// 提交当前账户资料；仅保存成功后调用关闭回调。
    func submit(
        onFailure: @escaping @MainActor () -> Void = {},
        onSaved: @escaping @MainActor () -> Void
    ) async {
        guard draft.isFormValid, !isSaving else { return }

        submissionState = .saving
        do {
            try await saveAction(draft)
            submissionState = .editing
            onSaved()
        } catch {
            submissionState = .failed
            onFailure()
        }
    }
}

/// 账户详情中的资料编辑页面；余额继续由独立调整流程管理。
struct AccountEditView: View {
    @Environment(\.locale) private var locale

    /// 当前编辑账户的值类型资料快照。
    let draft: AccountEditDraft

    /// 编辑页面注入的显式保存动作。
    private let saveAction: AccountEditSaveAction

    /// 资料保存成功后的上层刷新动作。
    private let onSaved: @MainActor () -> Void

    /// 创建账户资料编辑页面。
    init(
        draft: AccountEditDraft,
        save: @escaping AccountEditSaveAction,
        onSaved: @escaping @MainActor () -> Void = {}
    ) {
        self.draft = draft
        saveAction = save
        self.onSaved = onSaved
    }

    /// 兼容预览和既有调用方，将模型立即转换为值类型草稿。
    init(
        account: Account,
        save: @escaping AccountEditSaveAction,
        onSaved: @escaping @MainActor () -> Void = {}
    ) {
        self.init(draft: AccountEditDraft(account: account), save: save, onSaved: onSaved)
    }

    var body: some View {
        AccountEditFormView(
            draft: draft,
            locale: locale,
            saveAction: saveAction,
            onSaved: onSaved
        )
        .navigationTitle(AccountLocalization.string("account.edit.title", locale: locale))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 编辑账户资料的实际表单，类型和余额均由其他业务流程管理。
private struct AccountEditFormView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var flow: AccountEditFlow

    /// 编辑表单与保存动作共用的语言环境。
    let locale: Locale

    /// 初始化时解析的机构名称，避免输入变化时重复遍历模板列表。
    private let institution: String?

    /// 显式保存成功后的关闭动作。
    let onSaved: @MainActor () -> Void

    init(
        draft: AccountEditDraft,
        locale: Locale,
        saveAction: @escaping AccountEditSaveAction,
        onSaved: @escaping @MainActor () -> Void
    ) {
        _flow = StateObject(
            wrappedValue: AccountEditFlow(
                draft: draft,
                saveAction: saveAction
            )
        )
        self.locale = locale
        institution = draft.accountType.flatMap { accountType in
            guard accountType.showsInstitution else { return nil }
            return AccountListPresentation.template(
                id: draft.templateID,
                accountType: accountType
            )?.name(locale: locale)
        }
        self.onSaved = onSaved
    }

    var body: some View {
        Form {
            Section {
                if let institution {
                    LabeledContent(
                        AccountLocalization.string("account.detail.institution", locale: locale),
                        value: institution
                    )
                }

                if flow.draft.accountType?.showsEditableName ?? true {
                    TextField(
                        AccountLocalization.string("account.creation.field.name", locale: locale),
                        text: $flow.draft.name
                    )
                    .accessibilityIdentifier("account-edit-name")
                }

                if flow.draft.accountType?.showsLastFourDigits == true {
                    AccountLastFourDigitsField(
                        locale: locale,
                        text: $flow.draft.lastFourDigits,
                        accessibilityIdentifier: "account-edit-last-four-digits"
                    )
                }

                TextField(
                    AccountLocalization.string("account.creation.field.note", locale: locale),
                    text: $flow.draft.note
                )
                .accessibilityIdentifier("account-edit-note")
            }

            Section {
                Text(AccountLocalization.string("account.edit.immutable_message", locale: locale))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if flow.hasSaveError {
                Section {
                    Label(
                        AccountLocalization.string("account.edit.save_error.message", locale: locale),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("account-edit-save-error")
                }
            }

            Section {
                Button {
                    Task {
                        await flow.submit {
                            onSaved()
                            dismiss()
                        }
                    }
                } label: {
                    HStack {
                        if flow.isSaving {
                            ProgressView()
                                .accessibilityHidden(true)
                        }
                        Text(
                            AccountLocalization.string(
                                flow.hasSaveError ? "common.retry" : "common.save",
                                locale: locale
                            )
                        )
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(!flow.draft.isFormValid || flow.isSaving)
                .accessibilityIdentifier("account-edit-save")
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .disabled(flow.isSaving)
                .accessibilityLabel(AccountLocalization.string("common.close", locale: locale))
                .accessibilityIdentifier("account-edit-close")
            }
        }
        .interactiveDismissDisabled(flow.isSaving)
    }

}

#Preview {
    NavigationStack {
        AccountEditView(
            account: Account(
                id: UUID(),
                typeRawValue: AccountType.cash.rawValue,
                templateID: nil,
                name: "现金",
                note: nil,
                lastFourDigits: nil,
                balance: 40,
                currencyCode: "CNY",
                createdAt: .now,
                updatedAt: .now
            ),
            save: { _ in }
        )
    }
    .modelContainer(
        for: [Account.self, AccountTransaction.self, BookkeepingPreference.self],
        inMemory: true
    )
}
