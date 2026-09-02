import SwiftData
import SwiftUI
import UIKit

/// 支持收支方向、分类选择且金额优先的记账录入页。
struct DiningExpenseEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Query private var accounts: [Account]
    @Query private var preferences: [BookkeepingPreference]
    @FocusState private var focusedField: FocusedField?
    @StateObject private var flow: DiningExpenseEntryFlow
    @State private var isPresentingCategorySelection = false
    @State private var hasPresentedInitialCategorySelection = false
    @State private var shouldFocusAmountAfterCategorySelection = false
    @State private var isPresentingAccountSelection = false
    @State private var hasAccountCreationError = false

    /// 创建支出录入页。
    ///
    /// - Parameters:
    ///   - draft: 可选的既有草稿，默认创建以今天为日期的新草稿。
    ///   - save: 上层注入的本地餐饮支出保存动作。
    init(
        draft: DiningExpenseDraft? = nil,
        save: @escaping DiningExpenseSaveAction
    ) {
        _flow = StateObject(
            wrappedValue: DiningExpenseEntryFlow(
                draft: draft,
                saveAction: save
            )
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                entryTypePicker
                categoryAndAmount
                accountSection
                detailSection
                inlineFeedback
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(AccountLocalization.string("bookkeeping.entry.title", locale: locale))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(
            isPresented: $isPresentingCategorySelection,
            onDismiss: focusAmountAfterCategorySelection
        ) {
            categorySelection
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isPresentingAccountSelection) {
            NavigationStack {
                ExpenseAccountSelectionView(
                    onSelectAccount: { accountID in
                        hasAccountCreationError = false
                        flow.selectAccount(id: accountID)
                    },
                    onCreationFailed: {
                        hasAccountCreationError = true
                    }
                )
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .interactiveDismissDisabled(flow.isSaving)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            submitButton
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(AccountLocalization.string("common.done", locale: locale)) {
                    focusedField = nil
                }
            }
        }
        .task {
            applyInitialDefaultIfNeeded()
            presentInitialCategorySelectionIfNeeded()
        }
    }

    /// 使用系统分段选择器切换支出与收入方向。
    private var entryTypePicker: some View {
        Picker(
            AccountLocalization.string("bookkeeping.entry.type", locale: locale),
            selection: Binding(
                get: { flow.draft.entryType },
                set: { entryType in
                    focusedField = nil
                    flow.selectEntryType(entryType)
                    shouldFocusAmountAfterCategorySelection = false
                    isPresentingCategorySelection = true
                }
            )
        ) {
            ForEach(BookkeepingEntryType.allCases) { entryType in
                Text(entryType.localizedTitle(locale: locale))
                .tag(entryType)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("bookkeeping-entry-type")
    }

    /// 根据当前收支方向展示对应分类面板。
    @ViewBuilder
    private var categorySelection: some View {
        switch flow.draft.entryType {
        case .expense:
            BookkeepingCategorySelectionView(
                entryType: .expense,
                categories: ExpenseCategory.allCases,
                selectedCategory: flow.selectedCategory,
                titleKey: "expense.category.selection.title",
                accessibilityPrefix: "expense-category",
                onSelectEntryType: flow.selectEntryType,
                onSelect: { category in
                    flow.selectCategory(category)
                    completeCategorySelection()
                }
            )
        case .income:
            BookkeepingCategorySelectionView(
                entryType: .income,
                categories: IncomeCategory.allCases,
                selectedCategory: flow.selectedIncomeCategory,
                titleKey: "income.category.selection.title",
                accessibilityPrefix: "income-category",
                onSelectEntryType: flow.selectEntryType,
                onSelect: { category in
                    flow.selectIncomeCategory(category)
                    completeCategorySelection()
                }
            )
        }
    }

    /// 完成分类选择后关闭面板，并在返回时聚焦金额。
    private func completeCategorySelection() {
        shouldFocusAmountAfterCategorySelection = true
        isPresentingCategorySelection = false
    }

    /// 当前分类入口和主视觉金额。
    private var categoryAndAmount: some View {
        VStack(spacing: 14) {
            Button {
                focusedField = nil
                shouldFocusAmountAfterCategorySelection = false
                isPresentingCategorySelection = true
            } label: {
                HStack(spacing: 8) {
                    selectedCategoryLabel
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .font(.headline)
                .foregroundStyle(.tint)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("expense-entry-category")

            TextField(
                AccountLocalization.string("expense.entry.amount", locale: locale),
                text: Binding(
                    get: { flow.draft.amountText },
                    set: {
                        flow.updateAmountText(
                            $0,
                            decimalSeparator: locale.decimalSeparator ?? "."
                        )
                    }
                ),
                prompt: Text(verbatim: "0")
            )
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .keyboardType(.decimalPad)
                .focused($focusedField, equals: .amount)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.55)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 72)
                .accessibilityLabel(
                    Text(AccountLocalization.string("expense.entry.amount", locale: locale))
                )
                .accessibilityValue(Text(verbatim: flow.displayedAmount))
                .accessibilityIdentifier("expense-entry-amount")
        }
    }

    /// 当前方向下的分类图标和标题。
    @ViewBuilder
    private var selectedCategoryLabel: some View {
        switch flow.draft.entryType {
        case .expense:
            if let category = flow.selectedCategory {
                Image(systemName: category.symbolName)
                Text(category.localizedTitle(locale: locale))
            } else {
                Image(systemName: "square.grid.2x2")
                Text(AccountLocalization.string("expense.category.selection.title", locale: locale))
            }
        case .income:
            if let category = flow.selectedIncomeCategory {
                Image(systemName: category.symbolName)
                Text(category.localizedTitle(locale: locale))
            } else {
                Image(systemName: "square.grid.2x2")
                Text(AccountLocalization.string("income.category.selection.title", locale: locale))
            }
        }
    }

    /// 页面底部始终可见的保存动作；系统键盘出现时会自动位于键盘上方。
    private var submitButton: some View {
        Button {
            focusedField = nil
            Task {
                await flow.submit {
                    provideSuccessFeedback()
                    dismiss()
                }
            }
        } label: {
            HStack(spacing: 8) {
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
                .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canSubmit)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .accessibilityIdentifier("expense-entry-save")
    }

    /// 当前账户摘要；点击后直接弹出账户选择框。
    private var accountSection: some View {
        Button {
            focusedField = nil
            hasAccountCreationError = false
            isPresentingAccountSelection = true
        } label: {
            HStack(spacing: 12) {
                if let account = selectedAccount {
                    let row = AccountListPresentation.row(for: account, locale: locale)
                    AccountIconView(presentation: row.icon)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                        Text(row.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 3) {
                        Text(row.formattedAmount)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.primary)
                        Text(row.amountLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(row.amountAccessibilityLabel)
                } else {
                    Label(
                        AccountLocalization.string(accountPlaceholderKey, locale: locale),
                        systemImage: "creditcard"
                    )
                    .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                }

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                Color.primary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("expense-entry-account")
    }

    /// 记账日期与可选备注输入。
    private var detailSection: some View {
        VStack(spacing: 0) {
            DatePicker(
                AccountLocalization.string("expense.entry.date", locale: locale),
                selection: Binding(
                    get: { flow.transactionDate },
                    set: flow.updateTransactionDate
                ),
                displayedComponents: .date
            )
            .frame(minHeight: 44)
            .accessibilityIdentifier("expense-entry-date")

            Divider()

            TextField(
                AccountLocalization.string("expense.entry.note.placeholder", locale: locale),
                text: Binding(
                    get: { flow.draft.note },
                    set: flow.updateNote
                ),
                axis: .vertical
            )
            .focused($focusedField, equals: .note)
            .lineLimit(1...4)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .accessibilityLabel(
                Text(AccountLocalization.string("expense.entry.note", locale: locale))
            )
            .accessibilityIdentifier("expense-entry-note")
        }
        .padding(.horizontal, 14)
        .background(
            Color.primary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    /// 不阻断保存的余额提醒，以及保留草稿后的失败反馈。
    @ViewBuilder
    private var inlineFeedback: some View {
        if flow.draft.entryType == .expense && showsInsufficientBalanceWarning {
            Label(
                AccountLocalization.string("expense.entry.insufficient_balance", locale: locale),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.footnote)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        if flow.hasSaveError {
            Label(
                AccountLocalization.string("expense.entry.save_failed", locale: locale),
                systemImage: "exclamationmark.circle.fill"
            )
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("expense-entry-save-error")
        }

        if hasAccountCreationError {
            Label(
                AccountLocalization.string(
                    "expense.entry.account_creation_failed",
                    locale: locale
                ),
                systemImage: "exclamationmark.circle.fill"
            )
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("expense-entry-account-creation-error")
        }
    }

    /// 草稿账户 UUID 当前解析出的持久账户。
    private var selectedAccount: Account? {
        guard let accountID = flow.draft.accountID else { return nil }
        return accounts.first { $0.id == accountID && $0.supportsBookkeeping }
    }

    /// 从当前查询快照解析一次 canonical 默认，不将偏好变化绑定到现有草稿。
    private func applyInitialDefaultIfNeeded() {
        let preference = preferences.first { $0.id == BookkeepingPreference.singletonID }
        let defaultAccountID = BookkeepingPreference.resolvedAccountID(
            preference: preference,
            accounts: accounts
        )
        flow.applyInitialDefault(defaultAccountID)
    }

    /// 新建支出首次进入时立即要求选择分类；恢复草稿则直接编辑原分类。
    private func presentInitialCategorySelectionIfNeeded() {
        guard !hasPresentedInitialCategorySelection else { return }
        hasPresentedInitialCategorySelection = true

        if flow.selectedCategory == nil {
            focusedField = nil
            shouldFocusAmountAfterCategorySelection = false
            isPresentingCategorySelection = true
        } else {
            focusedField = .amount
        }
    }

    /// 只有本次面板完成分类选择后才自动聚焦金额，取消时保持键盘收起。
    private func focusAmountAfterCategorySelection() {
        guard shouldFocusAmountAfterCategorySelection else { return }
        shouldFocusAmountAfterCategorySelection = false
        focusedField = .amount
    }

    /// 未选择和已失效选择使用不同的本地化提示。
    private var accountPlaceholderKey: String {
        flow.draft.accountID == nil
            ? "expense.entry.account.select"
            : "expense.entry.account.unavailable"
    }

    /// 页面需同时确认所选账户仍然存在，仓库保存时还会再次校验。
    private var canSubmit: Bool {
        flow.canSubmit && selectedAccount != nil
    }

    /// 资产类账户预计扣减后为负时展示轻提醒，但不影响 `canSubmit`。
    private var showsInsufficientBalanceWarning: Bool {
        guard let account = selectedAccount,
              account.accountType?.expenseBalanceEffect == .decreaseValue,
              let amount = flow.draft.amount
        else { return false }

        return account.balance - amount < 0
    }

    /// 保存成功后提供系统触觉和 VoiceOver 可播报反馈，再返回首页。
    private func provideSuccessFeedback() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        UIAccessibility.post(
            notification: .announcement,
            argument: AccountLocalization.string(
                "bookkeeping.entry.save_succeeded",
                locale: locale
            )
        )
    }

    /// 页面内可唤起系统键盘的输入区域。
    private enum FocusedField: Hashable {
        case amount
        case note
    }
}

/// 记账页复用的收支分类选择面板。
private struct BookkeepingCategorySelectionView<Category: BookkeepingCategoryPresentable>: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    /// 当前面板对应的收支方向。
    let entryType: BookkeepingEntryType

    /// 当前方向下可选择的全部分类。
    let categories: [Category]

    /// 打开面板时已经选中的分类。
    let selectedCategory: Category?

    /// 面板标题使用的本地化键。
    let titleKey: String

    /// 自动化标识使用的稳定前缀。
    let accessibilityPrefix: String

    /// 用户在面板中切换收支方向后的回调。
    let onSelectEntryType: (BookkeepingEntryType) -> Void

    /// 用户点击分类后的回调。
    let onSelect: (Category) -> Void

    /// 根据可用宽度自动调整列数，兼顾普通字号和辅助功能字号。
    private let columns = [
        GridItem(.adaptive(minimum: 76, maximum: 112), spacing: 16)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Picker(
                        AccountLocalization.string("bookkeeping.entry.type", locale: locale),
                        selection: Binding(
                            get: { entryType },
                            set: onSelectEntryType
                        )
                    ) {
                        entryTypePickerItems
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("bookkeeping-category-entry-type")

                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(categories) { category in
                            categoryButton(category)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .navigationTitle(
                AccountLocalization.string(titleKey, locale: locale)
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AccountLocalization.string("common.cancel", locale: locale)) {
                        dismiss()
                    }
                }
            }
        }
    }

    /// 分类面板内复用的收支方向选项。
    @ViewBuilder
    private var entryTypePickerItems: some View {
        ForEach(BookkeepingEntryType.allCases) { entryType in
            Text(entryType.localizedTitle(locale: locale))
            .tag(entryType)
        }
    }

    /// 单个分类使用系统图标、动态颜色和本地化名称。
    private func categoryButton(_ category: Category) -> some View {
        Button {
            onSelect(category)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: category.symbolName)
                    .font(.title2.weight(.medium))
                    .foregroundStyle(
                        category == selectedCategory ? Color.accentColor : Color.primary
                    )
                    .frame(width: 56, height: 56)
                    .background(
                        category == selectedCategory
                            ? Color.accentColor.opacity(0.16)
                            : Color.secondary.opacity(0.12),
                        in: Circle()
                    )

                Text(category.localizedTitle(locale: locale))
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .top)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(category == selectedCategory ? .isSelected : [])
        .accessibilityIdentifier("\(accessibilityPrefix)-\(category.rawValue)")
    }
}
