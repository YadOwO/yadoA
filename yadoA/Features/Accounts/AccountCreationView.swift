import Combine
import SwiftUI

/// 账户创建流程注入的显式保存动作。
typealias AccountCreationSaveAction = @MainActor (AccountDraft) async throws -> Void

/// 表单提交期间的状态，用于控制防重与可重试错误展示。
enum AccountCreationSubmissionState: Equatable {
    case editing
    case saving
    case failed
}

/// 持有单份创建草稿并串行协调显式保存。
@MainActor
final class AccountCreationFlow: ObservableObject {
    /// 用户在类型、模板和表单阶段确定的同一份草稿。
    @Published var draft: AccountDraft

    /// 当前提交状态；保存进行中时拒绝任何后续提交。
    @Published private(set) var submissionState: AccountCreationSubmissionState = .editing

    /// 由列表或其他上层注入的持久化动作。
    private let saveAction: AccountCreationSaveAction

    /// 创建一条可测试的账户创建提交流程。
    init(draft: AccountDraft, saveAction: @escaping AccountCreationSaveAction) {
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

    /// 校验并提交当前草稿；同一时刻最多执行一次保存。
    ///
    /// - Parameter onSaved: 仅在注入的显式保存成功后调用的关闭回调。
    func submit(
        locale: Locale = .current,
        onSaved: @escaping @MainActor () -> Void
    ) async {
        guard draft.isFormValid(locale: locale), !isSaving else { return }

        submissionState = .saving
        do {
            try await saveAction(draft)
            submissionState = .editing
            onSaved()
        } catch {
            submissionState = .failed
        }
    }
}

struct AccountCreationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var path: [AccountCreationRoute] = []
    @State private var isSaving = false

    /// 由账户列表注入的显式保存动作。
    private let saveAction: AccountCreationSaveAction

    /// 创建账户 sheet；生产调用方应注入真实本地仓库保存动作。
    init(save: @escaping AccountCreationSaveAction) {
        saveAction = save
    }

    var body: some View {
        NavigationStack(path: $path) {
            List(AccountType.allCases) { accountType in
                NavigationLink(value: accountType.nextRoute) {
                    AccountTypeRow(accountType: accountType)
                }
                .accessibilityIdentifier("account-creation-type-\(accountType.rawValue)")
            }
            .navigationTitle(AccountLocalization.string("account.creation.title", locale: locale))
            .navigationDestination(for: AccountCreationRoute.self) { route in
                destination(for: route)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AccountLocalization.string("common.cancel", locale: locale)) {
                        dismiss()
                    }
                    .disabled(isSaving)
                    .accessibilityIdentifier("account-creation-cancel")
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    @ViewBuilder
    private func destination(for route: AccountCreationRoute) -> some View {
        switch route {
        case let .templates(accountType):
            AccountTemplateListView(accountType: accountType)
        case let .form(accountType, template):
            AccountFormView(
                accountType: accountType,
                template: template,
                locale: locale,
                isSheetSaving: $isSaving,
                saveAction: saveAction
            ) {
                dismiss()
            }
        }
    }
}

private enum AccountCreationRoute: Hashable {
    case templates(AccountType)
    case form(AccountType, AccountTemplate?)
}

private extension AccountType {
    var nextRoute: AccountCreationRoute {
        requiresTemplateSelection ? .templates(self) : .form(self, nil)
    }
}

#Preview {
    AccountCreationView(save: { _ in })
}

private struct AccountTypeRow: View {
    @Environment(\.locale) private var locale
    let accountType: AccountType

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(accountType.title(locale: locale))

                if let subtitle = accountType.subtitle(locale: locale) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: accountType.symbolName)
                .foregroundStyle(accountType.tint)
        }
        .padding(.vertical, 4)
    }
}

private struct AccountTemplateListView: View {
    @Environment(\.locale) private var locale
    let accountType: AccountType

    var body: some View {
        List(accountType.templates) { template in
            NavigationLink(value: AccountCreationRoute.form(accountType, template)) {
                HStack(spacing: 12) {
                    AccountTemplateIcon(template: template)
                    Text(template.name(locale: locale))
                }
                    .padding(.vertical, 4)
            }
            .accessibilityIdentifier("account-creation-template-\(template.id)")
        }
        .navigationTitle(
            AccountLocalization.formatted(
                "account.creation.navigation.title_format",
                value: accountType.title(locale: locale),
                locale: locale
            )
        )
    }
}

private struct AccountTemplateIcon: View {
    let template: AccountTemplate

    var body: some View {
        Group {
            if let brandImageName = template.brandImageName {
                Image(brandImageName)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: template.symbolName)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
                    .foregroundStyle(.tint)
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }
}

private struct AccountFormView: View {
    @StateObject private var flow: AccountCreationFlow
    @Binding private var isSheetSaving: Bool

    /// 创建与持久化共同使用的语言环境。
    let locale: Locale

    /// 显式保存成功后由 sheet 执行的关闭动作。
    let onSaved: @MainActor () -> Void

    init(
        accountType: AccountType,
        template: AccountTemplate?,
        locale: Locale,
        isSheetSaving: Binding<Bool>,
        saveAction: @escaping AccountCreationSaveAction,
        onSaved: @escaping @MainActor () -> Void
    ) {
        _flow = StateObject(
            wrappedValue: AccountCreationFlow(
                draft: AccountDraft(
                    accountType: accountType,
                    template: template,
                    locale: locale
                ),
                saveAction: saveAction
            )
        )
        _isSheetSaving = isSheetSaving
        self.locale = locale
        self.onSaved = onSaved
    }

    var body: some View {
        Form {
            Section {
                if flow.draft.accountType.showsInstitution, let template = flow.draft.template {
                    LabeledContent(
                        AccountLocalization.string("account.creation.field.institution", locale: locale),
                        value: template.name(locale: locale)
                    )
                }

                if flow.draft.accountType.showsEditableName {
                    TextField(
                        AccountLocalization.string("account.creation.field.name", locale: locale),
                        text: $flow.draft.name
                    )
                    .accessibilityIdentifier("account-creation-name")
                }

                if flow.draft.accountType.showsLastFourDigits {
                    TextField(
                        AccountLocalization.string("account.creation.field.last_four_digits", locale: locale),
                        text: $flow.draft.lastFourDigits
                    )
                        .keyboardType(.numberPad)
                        .onChange(of: flow.draft.lastFourDigits) { _, newValue in
                            let cleanedValue = String(newValue.filter(\.isNumber).prefix(4))
                            if cleanedValue != newValue {
                                flow.draft.lastFourDigits = cleanedValue
                            }
                        }
                        .accessibilityIdentifier("account-creation-last-four-digits")
                }

                TextField(
                    AccountLocalization.string("account.creation.field.note", locale: locale),
                    text: $flow.draft.note
                )
                .accessibilityIdentifier("account-creation-note")

                TextField(
                    flow.draft.accountType.amountLabel(locale: locale),
                    text: $flow.draft.amountText
                )
                    .keyboardType(.decimalPad)
                    .accessibilityIdentifier("account-creation-amount")
            }

            if flow.hasSaveError {
                Section {
                    Label(
                        AccountLocalization.string("account.creation.save_error.message", locale: locale),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("account-creation-save-error")
                }
            }

            Section {
                Button {
                    isSheetSaving = true
                    Task {
                        await flow.submit(locale: locale, onSaved: onSaved)
                        isSheetSaving = false
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
                .disabled(!flow.draft.isFormValid(locale: locale) || flow.isSaving)
                .accessibilityIdentifier("account-creation-save")
            }
        }
        .navigationTitle(
            AccountLocalization.formatted(
                "account.creation.navigation.title_format",
                value: flow.draft.template?.name(locale: locale)
                    ?? flow.draft.accountType.title(locale: locale),
                locale: locale
            )
        )
        .navigationBarBackButtonHidden(flow.isSaving)
    }
}
