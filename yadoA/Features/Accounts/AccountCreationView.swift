import SwiftUI

struct AccountCreationView: View {
    @State private var path: [AccountCreationRoute] = []
    @State private var isCompletionAlertPresented = false

    var body: some View {
        NavigationStack(path: $path) {
            List(AccountType.allCases) { accountType in
                NavigationLink(value: accountType.nextRoute) {
                    AccountTypeRow(accountType: accountType)
                }
            }
            .navigationTitle("添加账户")
            .navigationDestination(for: AccountCreationRoute.self) { route in
                destination(for: route)
            }
            .alert("账户信息已填写", isPresented: $isCompletionAlertPresented) {
                Button("好", role: .cancel) {}
            } message: {
                Text("当前为功能原型，本轮暂不保存数据。")
            }
        }
    }

    @ViewBuilder
    private func destination(for route: AccountCreationRoute) -> some View {
        switch route {
        case let .templates(accountType):
            AccountTemplateListView(accountType: accountType)
        case let .form(accountType, template):
            AccountFormView(accountType: accountType, template: template) { _ in
                path.removeAll()
                isCompletionAlertPresented = true
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
    AccountCreationView()
}

private struct AccountTypeRow: View {
    let accountType: AccountType

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(accountType.title)

                if let subtitle = accountType.subtitle {
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
    let accountType: AccountType

    var body: some View {
        List(accountType.templates) { template in
            NavigationLink(value: AccountCreationRoute.form(accountType, template)) {
                HStack(spacing: 12) {
                    AccountTemplateIcon(template: template)
                    Text(template.name)
                }
                    .padding(.vertical, 4)
            }
        }
        .navigationTitle("添加\(accountType.title)")
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
    let onSave: (AccountDraft) -> Void

    @State private var draft: AccountDraft

    init(
        accountType: AccountType,
        template: AccountTemplate?,
        onSave: @escaping (AccountDraft) -> Void
    ) {
        self.onSave = onSave
        _draft = State(initialValue: AccountDraft(accountType: accountType, template: template))
    }

    var body: some View {
        Form {
            Section {
                if draft.accountType.showsInstitution, let template = draft.template {
                    LabeledContent("所属机构", value: template.name)
                }

                if draft.accountType.showsEditableName {
                    TextField("名称", text: $draft.name)
                }

                if draft.accountType.showsLastFourDigits {
                    TextField("卡号（后四位，可选）", text: $draft.lastFourDigits)
                        .keyboardType(.numberPad)
                        .onChange(of: draft.lastFourDigits) { _, newValue in
                            let cleanedValue = String(newValue.filter(\.isNumber).prefix(4))
                            if cleanedValue != newValue {
                                draft.lastFourDigits = cleanedValue
                            }
                        }
                }

                TextField("备注（可选）", text: $draft.note)

                TextField(draft.accountType.amountLabel, text: $draft.amountText)
                    .keyboardType(.decimalPad)
            }

            Section {
                Button("保存") {
                    onSave(draft)
                }
                .frame(maxWidth: .infinity)
                .disabled(!draft.isFormValid)
            }
        }
        .navigationTitle("添加\(draft.template?.name ?? draft.accountType.title)")
    }
}

private extension AccountType {
    var tint: Color {
        switch self {
        case .cash: .green
        case .debitCard, .creditCard, .virtualAccount, .investment: .orange
        case .liability: .red
        case .receivable: .blue
        case .customAsset: .indigo
        }
    }
}
