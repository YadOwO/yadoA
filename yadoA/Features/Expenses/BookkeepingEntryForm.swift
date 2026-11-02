import SwiftData
import SwiftUI
import UIKit

/// 新增与编辑两个入口在同一套票据页面上的差异。
struct BookkeepingEntryFormConfiguration {
    /// 收支方向选择器的自动化标识。
    let typeIdentifier: String

    /// 其余控件自动化标识的稳定前缀。
    let identifierPrefix: String

    /// 票据下方的补充说明文案键；为空时不展示。
    let footnoteKey: String?

    /// 保存失败提示的文案键。
    let saveFailedKey: String

    /// 保存成功后 VoiceOver 播报的文案键。
    let saveSucceededKey: String

    /// 是否按"当前余额减去金额"提示余额不足；编辑时原金额已经入账，这个算法不成立。
    let warnsInsufficientBalance: Bool

    /// 日期一行的项目名文案键。
    var dateLabelKey = "expense.entry.date"

    /// 日期是否只能选今天及以后；周期记账的下一期不能选过去，否则一保存就补记好几笔。
    var startsFromToday = false

    /// 新增一笔记账。
    static let entry = BookkeepingEntryFormConfiguration(
        typeIdentifier: "bookkeeping-entry-type",
        identifierPrefix: "expense-entry",
        footnoteKey: nil,
        saveFailedKey: "expense.entry.save_failed",
        saveSucceededKey: "bookkeeping.entry.save_succeeded",
        warnsInsufficientBalance: true
    )

    /// 编辑一笔已有流水。
    static let edit = BookkeepingEntryFormConfiguration(
        typeIdentifier: "expense-edit-type",
        identifierPrefix: "expense-edit",
        footnoteKey: "bookkeeping.edit.balance_hint",
        saveFailedKey: "expense.edit.save_failed",
        saveSucceededKey: "expense.edit.save_succeeded",
        warnsInsufficientBalance: false
    )

    /// 新建或修改一条周期记账。
    static let recurring = BookkeepingEntryFormConfiguration(
        typeIdentifier: "recurring-edit-type",
        identifierPrefix: "recurring-edit",
        footnoteKey: "recurring.edit.footnote",
        saveFailedKey: "recurring.edit.save_failed",
        saveSucceededKey: "recurring.edit.save_succeeded",
        warnsInsufficientBalance: false,
        dateLabelKey: "recurring.edit.next_date",
        startsFromToday: true
    )
}

/// 新增记账与编辑记账共用的票据页面。
///
/// 版式与记账详情的收据一致：上半是分类和金额，一条线之后逐行写备注、账户和日期，
/// 区别只在于这里的每一项都可以填写。备注决定列表主行，所以紧跟金额，账户和日期多用默认值放在后面。导航标题、取消按钮等入口差异由外层页面负责。
/// `Accessory` 是接在日期后面的额外几行，周期记账用它放重复频率和结束日期。
struct BookkeepingEntryForm<Flow: BookkeepingEntryFormFlow, Accessory: View>: View {
    @Environment(\.locale) private var locale
    @Query private var accounts: [Account]
    @Query private var categories: [BookkeepingCategory]
    @FocusState private var focusedField: FocusedField?
    @ObservedObject private var flow: Flow
    @State private var isPresentingCategorySelection = false
    @State private var hasHandledInitialPresentation = false
    @State private var shouldFocusAmountAfterCategorySelection = false
    @State private var isPresentingAccountSelection = false
    @State private var hasAccountCreationError = false
    /// 截图预览默认收起，优先为金额和分类保留可见空间。
    @State private var isScreenshotExpanded = false
    /// 正在输入的算式，例如 `28+15`；普通金额时为空。算式的结果实时写入草稿，离开金额框后输入框换成结果。
    @State private var amountExpression: String?

    /// 当前入口的标识与文案配置。
    private let configuration: BookkeepingEntryFormConfiguration
    /// 快捷指令传入的临时参考图，不作为流水附件持久化。
    private let screenshot: UIImage?
    /// 进入页面后是否先处理分类：未选分类时弹出选择面板，已选时直接聚焦金额。
    private let startsWithCategorySelection: Bool
    /// 保存成功并完成反馈后的收尾动作。
    private let onSaved: @MainActor () -> Void
    /// 首次进入时、决定是否弹出分类面板之前调用，外层可在这里补全草稿。
    private let prepareInitialDraft: @MainActor () -> Void
    /// 接在日期后面的额外几行。
    private let accessory: Accessory

    /// 创建票据页面。
    ///
    /// - Parameters:
    ///   - flow: 外层持有的草稿流程。
    ///   - configuration: 当前入口的标识与文案配置。
    ///   - screenshot: 截图入口的参考图片，为空时不展示预览。
    ///   - startsWithCategorySelection: 进入页面后是否先引导选择分类。
    ///   - onSaved: 保存成功后的收尾动作，通常是关闭页面。
    ///   - prepareInitialDraft: 首次进入时补全草稿的动作，例如预选最近分类。
    ///   - accessory: 接在日期后面的额外几行。
    init(
        flow: Flow,
        configuration: BookkeepingEntryFormConfiguration,
        screenshot: UIImage? = nil,
        startsWithCategorySelection: Bool = false,
        onSaved: @escaping @MainActor () -> Void,
        prepareInitialDraft: @escaping @MainActor () -> Void = {},
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.flow = flow
        self.configuration = configuration
        self.screenshot = screenshot
        self.startsWithCategorySelection = startsWithCategorySelection
        self.onSaved = onSaved
        self.prepareInitialDraft = prepareInitialDraft
        self.accessory = accessory()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let screenshot {
                    screenshotPreview(screenshot)
                }
                entryTypePicker
                slip
                if let footnoteKey = configuration.footnoteKey {
                    Text(text(footnoteKey))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                inlineFeedback
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
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
                        AppHaptics.play(.selection)
                        hasAccountCreationError = false
                        flow.selectFormAccount(id: accountID)
                    },
                    onCreationFailed: {
                        hasAccountCreationError = true
                    }
                )
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            submitButton
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if focusedField == .amount {
                    ForEach(AmountExpression.Operator.allCases) { operation in
                        Button {
                            appendOperator(operation)
                        } label: {
                            Text(verbatim: operation.rawValue)
                                .font(.title3.weight(.medium))
                                .frame(minWidth: 32)
                        }
                        .accessibilityLabel(text(operation.accessibilityKey))
                        .accessibilityIdentifier("\(configuration.identifierPrefix)-operator-\(operation.id)")
                    }
                }
                Spacer()
                Button(text("common.done")) {
                    focusedField = nil
                }
            }
        }
        .task {
            handleInitialPresentationIfNeeded()
        }
        // 离开金额框时算式已经算完，输入框换成结果
        .onChange(of: focusedField) { oldField, newField in
            if oldField == .amount, newField != .amount {
                amountExpression = nil
            }
        }
        .onChange(of: selectedCategoryItem?.isDeleted) { _, isDeleted in
            // 已选分类在分类管理里被删除时：流水迁走了就跟随迁移目标，流水一并删除了就撤销选择，
            // 避免保存时引用已删除的分类。
            guard isDeleted == true else { return }
            if let replacementKey = selectedCategoryItem?.replacementKey {
                flow.selectCategory(key: replacementKey)
            } else {
                flow.clearCategory()
            }
        }
        // 余额不足提醒出现的那一刻提示一下，金额继续变化时不再重复
        .appHaptic(.warning, trigger: showsInsufficientBalanceWarning) { _, shows in shows }
        .appHaptic(.error, trigger: flow.hasSaveError) { _, failed in failed }
        .paperPage()
    }

    // MARK: - 票据

    /// 一张手绘方框里的票据：分类与金额在上，各项资料逐行写在下面。
    private var slip: some View {
        VStack(spacing: 0) {
            categoryAndAmount
                .padding(.bottom, 14)

            noteRow
            fieldRule(seed: 63)
            accountRow
            fieldRule(seed: 64)
            dateRow
            accessory
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .ledgerFormBorder(seed: 59)
    }

    /// 分类入口和主视觉金额；金额写在一条手绘的横线上。
    private var categoryAndAmount: some View {
        VStack(spacing: 10) {
            Button {
                focusedField = nil
                shouldFocusAmountAfterCategorySelection = false
                isPresentingCategorySelection = true
            } label: {
                VStack(spacing: 8) {
                    Image(systemName: selectedCategorySymbolName)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.tint)
                        .frame(width: 52, height: 52)
                        .background {
                            HandDrawnBlob(seed: selectedCategoryTitle.handDrawnSeed)
                                .fill(Color.accentColor.opacity(0.08))
                        }
                    HStack(spacing: 6) {
                        Text(selectedCategoryTitle)
                            .font(.system(.headline, design: .serif))
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                .foregroundStyle(Color.primary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("\(configuration.identifierPrefix)-category")

            TextField(
                text("expense.entry.amount"),
                text: Binding(
                    get: { amountExpression ?? flow.formAmountText },
                    set: { updateAmountInput($0) }
                ),
                prompt: Text(verbatim: "0")
            )
            .font(.system(.largeTitle, design: .serif, weight: .medium))
            .monospacedDigit()
            .keyboardType(.decimalPad)
            .focused($focusedField, equals: .amount)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.55)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 56)
            .accessibilityLabel(Text(text("expense.entry.amount")))
            .accessibilityValue(
                Text(verbatim: flow.formAmountText.isEmpty ? "0" : flow.formAmountText)
            )
            .accessibilityIdentifier("\(configuration.identifierPrefix)-amount")

            HandDrawnRule(seed: 61)
                .stroke(Color.primary.opacity(0.6), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                .frame(height: 3)
                .accessibilityHidden(true)

            if let amountExpression, let result = AmountExpression.result(of: amountExpression) {
                Text(verbatim: "= \(result.formatted(.currency(code: "CNY").locale(locale)))")
                    .font(.system(.callout, design: .serif).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(configuration.identifierPrefix)-amount-result")
            }
        }
    }

    /// 接收金额框的输入：带运算符时按算式处理，把结果写入草稿；否则走原来的金额规则。
    ///
    /// - Parameter input: 输入框当前的文字。
    private func updateAmountInput(_ input: String) {
        let decimalSeparator = locale.decimalSeparator ?? "."
        let canonical = AccountAmountParser.canonicalized(input, decimalSeparator: decimalSeparator)
        guard AmountExpression.containsOperator(canonical) else {
            amountExpression = nil
            flow.updateAmountText(input, decimalSeparator: decimalSeparator)
            return
        }
        guard AmountExpression.isValidInput(canonical) else { return }
        amountExpression = canonical
        // 算式还算不出结果（如结果不大于零）时清空金额，保存按钮随之不可用
        flow.updateAmountText(
            AmountExpression.result(of: canonical).map(AmountExpression.amountText) ?? "",
            decimalSeparator: "."
        )
    }

    /// 点键盘上方的运算符。
    ///
    /// - Parameter operation: 点选的运算符。
    private func appendOperator(_ operation: AmountExpression.Operator) {
        guard let appended = AmountExpression.appending(
            operation,
            to: amountExpression ?? flow.formAmountText
        ) else { return }
        AppHaptics.play(.selection)
        updateAmountInput(appended)
    }

    /// 当前账户及其余额；点击后弹出账户选择框。
    private var accountRow: some View {
        Button {
            focusedField = nil
            hasAccountCreationError = false
            isPresentingAccountSelection = true
        } label: {
            fieldRow("bookkeeping.search.detail.account", alignment: .center) {
                HStack(spacing: 8) {
                    if let account = selectedAccount {
                        let row = AccountListPresentation.row(for: account, locale: locale)
                        // 图标紧挨在名称前面，一眼认出是哪个账户，不必读字。
                        AccountIconView(presentation: row.icon)
                            .scaleEffect(0.8)
                            .frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name)
                                .foregroundStyle(Color.primary)
                            Text(verbatim: "\(row.amountLabel) \(row.formattedAmount)")
                                .font(.system(.caption, design: .serif))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .multilineTextAlignment(.leading)
                    } else {
                        // 原账户已停用或删除时用账本红提示，尚未选择时只是普通占位。
                        Text(text(accountPlaceholderKey))
                            .foregroundStyle(
                                flow.formAccountID == nil
                                    ? AnyShapeStyle(.tertiary)
                                    : AnyShapeStyle(Color(.ledgerRed))
                            )
                    }
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("\(configuration.identifierPrefix)-account")
    }

    /// 记账日期，沿用系统紧凑日期选择器。
    private var dateRow: some View {
        DatePicker(
            selection: Binding(
                get: { flow.formTransactionDate },
                set: flow.updateTransactionDate
            ),
            in: (configuration.startsFromToday ? Calendar.current.startOfDay(for: .now) : .distantPast)...,
            displayedComponents: .date
        ) {
            Text(text(configuration.dateLabelKey))
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 50)
        .accessibilityIdentifier("\(configuration.identifierPrefix)-date")
    }

    /// 可选备注，内容多时向下换行。
    private var noteRow: some View {
        // 多行输入框的基线取在最后一行，按基线对齐会让右边掉下去；同字号下顶对齐即首行对齐。
        fieldRow("expense.entry.note", alignment: .top) {
            TextField(
                text("expense.entry.note.placeholder"),
                text: Binding(
                    get: { flow.formNote },
                    set: flow.updateNote
                ),
                axis: .vertical
            )
            .focused($focusedField, equals: .note)
            .lineLimit(1...4)
            .multilineTextAlignment(.trailing)
            .accessibilityLabel(Text(text("expense.entry.note")))
            .accessibilityIdentifier("\(configuration.identifierPrefix)-note")
        }
    }

    /// 票据里的一行：左边是灰色的项目名，右边是可填写的内容。
    private func fieldRow<Content: View>(
        _ titleKey: String,
        alignment: VerticalAlignment = .firstTextBaseline,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: alignment, spacing: 16) {
            Text(text(titleKey))
                .foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .frame(minHeight: 50)
    }

    /// 两行之间的手绘细线。
    private func fieldRule(seed: UInt64) -> some View {
        HandDrawnRule(seed: seed)
            .stroke(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            .frame(height: 3)
            .accessibilityHidden(true)
    }

    // MARK: - 票据之外

    /// 明确展示传入图片和手动填写提示，收起时不占用金额输入区域。
    private func screenshotPreview(_ image: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation { isScreenshotExpanded.toggle() }
            } label: {
                HStack {
                    Label(text("shortcut.screenshot.received"), systemImage: "photo")
                    Spacer(minLength: 8)
                    Image(systemName: isScreenshotExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .accessibilityIdentifier("screenshot-entry-preview")

            if isScreenshotExpanded {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 320)
                    .clipShape(.rect(cornerRadius: 12))
                    .accessibilityLabel(text("shortcut.screenshot.input"))
                    .accessibilityIdentifier("screenshot-entry-image")
            }
            Text(text("shortcut.screenshot.manual_hint"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.leading)
    }

    /// 票据上方手写的"支出 / 收入"两个词，切换记账方向。
    private var entryTypePicker: some View {
        LedgerSwitch(
            label: text("bookkeeping.entry.type"),
            selection: Binding(
                get: { flow.formEntryType },
                set: { entryType in
                    focusedField = nil
                    flow.selectEntryType(entryType)
                    // 新方向下还没有确认过分类时，立即请用户选一个。
                    if !hasSelectedCategory {
                        shouldFocusAmountAfterCategorySelection = false
                        isPresentingCategorySelection = true
                    }
                }
            ),
            options: BookkeepingEntryType.ledgerSwitchOptions(
                identifier: configuration.typeIdentifier,
                locale: locale
            )
        )
        .frame(maxWidth: .infinity)
    }

    /// 不阻断保存的余额提醒、流水已被删除的提示，以及保留草稿后的失败反馈。
    @ViewBuilder
    private var inlineFeedback: some View {
        if showsInsufficientBalanceWarning {
            Label(
                text("expense.entry.insufficient_balance"),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.footnote)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        if flow.isEntryRemoved {
            Label(text("expense.edit.removed"), systemImage: "exclamationmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(Color(.ledgerRed))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("\(configuration.identifierPrefix)-removed")
        }

        if flow.hasSaveError {
            Label(text(configuration.saveFailedKey), systemImage: "exclamationmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(Color(.ledgerRed))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("\(configuration.identifierPrefix)-save-error")
        }

        if hasAccountCreationError {
            Label(
                text("expense.entry.account_creation_failed"),
                systemImage: "exclamationmark.circle.fill"
            )
            .font(.footnote)
            .foregroundStyle(Color(.ledgerRed))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("\(configuration.identifierPrefix)-account-creation-error")
        }
    }

    /// 页面底部始终可见的保存动作；系统键盘出现时会自动位于键盘上方。
    private var submitButton: some View {
        Button {
            focusedField = nil
            Task {
                await flow.submit {
                    provideSuccessFeedback()
                    onSaved()
                }
            }
        } label: {
            HStack(spacing: 8) {
                if flow.isSaving {
                    ProgressView()
                        .accessibilityHidden(true)
                }
                Text(text(flow.hasSaveError ? "common.retry" : "common.save"))
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .onAccentForeground()
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canSubmit)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .background(Color(.paperBackground))
        .accessibilityIdentifier("\(configuration.identifierPrefix)-save")
    }

    // MARK: - 分类

    /// 存储中的分类设置与预置默认值合并后的目录。
    private var catalog: BookkeepingCategoryCatalog {
        BookkeepingCategoryCatalog(categories: categories)
    }

    /// 根据当前收支方向展示对应分类面板。
    private var categorySelection: some View {
        let entryType = flow.formEntryType
        return BookkeepingCategorySelectionView(
            entryType: entryType,
            categories: catalog.items(for: entryType),
            selectedKey: flow.formCategoryKey,
            titleKey: "\(entryType.rawValue).category.selection.title",
            accessibilityPrefix: "\(entryType.rawValue)-category",
            onSelectEntryType: flow.selectEntryType,
            onSelect: { item in
                AppHaptics.play(.selection)
                flow.selectCategory(key: item.key)
                completeCategorySelection()
            }
        )
    }

    /// 当前方向下是否已有确认过的分类。
    private var hasSelectedCategory: Bool {
        flow.formCategoryKey != nil
    }

    /// 当前已确认分类在目录中的快照。
    private var selectedCategoryItem: BookkeepingCategoryItem? {
        flow.formCategoryKey.map {
            catalog.resolvedItem(direction: flow.formEntryType, key: $0)
        }
    }

    /// 当前分类的系统图标；未选择时使用通用的分类图标。
    private var selectedCategorySymbolName: String {
        selectedCategoryItem?.symbolName ?? "square.grid.2x2"
    }

    /// 当前分类的名称；未选择时提示选择分类。
    private var selectedCategoryTitle: String {
        selectedCategoryItem?.title(locale: locale)
            ?? text("\(flow.formEntryType.rawValue).category.selection.title")
    }

    /// 完成分类选择后关闭面板；金额还空着时，返回后直接聚焦金额。
    private func completeCategorySelection() {
        shouldFocusAmountAfterCategorySelection = flow.formAmountText.isEmpty
        isPresentingCategorySelection = false
    }

    /// 只有本次面板完成分类选择后才自动聚焦金额，取消时保持键盘收起。
    private func focusAmountAfterCategorySelection() {
        guard shouldFocusAmountAfterCategorySelection else { return }
        shouldFocusAmountAfterCategorySelection = false
        focusedField = .amount
    }

    /// 新增记账首次进入时，没有可用分类就先要求选择；预选了最近分类或恢复出的草稿已有分类时，直接聚焦金额。
    private func handleInitialPresentationIfNeeded() {
        guard !hasHandledInitialPresentation else { return }
        hasHandledInitialPresentation = true
        // 放在这里而不是外层的 task：父子视图 task 的先后没有保证，必须先补全草稿再判断是否弹出面板
        prepareInitialDraft()
        guard startsWithCategorySelection else { return }

        if hasSelectedCategory {
            focusedField = .amount
        } else {
            focusedField = nil
            shouldFocusAmountAfterCategorySelection = false
            isPresentingCategorySelection = true
        }
    }

    // MARK: - 账户与提交

    /// 草稿账户 UUID 当前解析出的、仍可用于记账的持久账户。
    private var selectedAccount: Account? {
        guard let accountID = flow.formAccountID else { return nil }
        return accounts.first {
            $0.id == accountID && $0.supportsBookkeeping && $0.currencyCode == "CNY"
        }
    }

    /// 未选择和已失效选择使用不同的本地化提示。
    private var accountPlaceholderKey: String {
        flow.formAccountID == nil
            ? "expense.entry.account.select"
            : "expense.entry.account.unavailable"
    }

    /// 页面需同时确认所选账户仍然存在，仓库保存时还会再次校验。
    private var canSubmit: Bool {
        flow.canSubmit && selectedAccount != nil
    }

    /// 资产类账户预计扣减后为负时展示轻提醒，但不影响 `canSubmit`。
    private var showsInsufficientBalanceWarning: Bool {
        guard configuration.warnsInsufficientBalance,
              flow.formEntryType == .expense,
              let account = selectedAccount,
              account.accountType?.expenseBalanceEffect == .decreaseValue,
              let amount = AccountAmountParser.cnyAmount(fromNormalized: flow.formAmountText),
              amount > 0
        else { return false }

        return account.balance - amount < 0
    }

    /// 保存成功后提供系统触觉和 VoiceOver 可播报反馈。
    private func provideSuccessFeedback() {
        AppHaptics.play(.success)
        UIAccessibility.post(
            notification: .announcement,
            argument: text(configuration.saveSucceededKey)
        )
    }

    /// 按当前应用语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }

    /// 页面内可唤起系统键盘的输入区域。
    private enum FocusedField: Hashable {
        case amount
        case note
    }
}

extension BookkeepingEntryForm where Accessory == EmptyView {
    /// 创建没有额外几行的票据页面。
    ///
    /// - Parameters:
    ///   - flow: 外层持有的草稿流程。
    ///   - configuration: 当前入口的标识与文案配置。
    ///   - screenshot: 截图入口的参考图片，为空时不展示预览。
    ///   - startsWithCategorySelection: 进入页面后是否先引导选择分类。
    ///   - onSaved: 保存成功后的收尾动作，通常是关闭页面。
    ///   - prepareInitialDraft: 首次进入时补全草稿的动作，例如预选最近分类。
    init(
        flow: Flow,
        configuration: BookkeepingEntryFormConfiguration,
        screenshot: UIImage? = nil,
        startsWithCategorySelection: Bool = false,
        onSaved: @escaping @MainActor () -> Void,
        prepareInitialDraft: @escaping @MainActor () -> Void = {}
    ) {
        self.init(
            flow: flow,
            configuration: configuration,
            screenshot: screenshot,
            startsWithCategorySelection: startsWithCategorySelection,
            onSaved: onSaved,
            prepareInitialDraft: prepareInitialDraft,
            accessory: { EmptyView() }
        )
    }
}

/// 票据页面复用的收支分类选择面板。
private struct BookkeepingCategorySelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    /// 当前面板对应的收支方向。
    let entryType: BookkeepingEntryType

    /// 当前方向下可选择的分类，已按用户排序。
    let categories: [BookkeepingCategoryItem]

    /// 打开面板时已经选中的分类 key。
    let selectedKey: String?

    /// 面板标题使用的本地化键。
    let titleKey: String

    /// 自动化标识使用的稳定前缀。
    let accessibilityPrefix: String

    /// 用户在面板中切换收支方向后的回调。
    let onSelectEntryType: (BookkeepingEntryType) -> Void

    /// 用户点击分类后的回调。
    let onSelect: (BookkeepingCategoryItem) -> Void

    /// 根据可用宽度自动调整列数，兼顾普通字号和辅助功能字号。
    private let columns = [
        GridItem(.adaptive(minimum: 76, maximum: 112), spacing: 16)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    LedgerSwitch(
                        label: AccountLocalization.string("bookkeeping.entry.type", locale: locale),
                        selection: Binding(
                            get: { entryType },
                            set: onSelectEntryType
                        ),
                        options: BookkeepingEntryType.ledgerSwitchOptions(
                            identifier: "bookkeeping-category-entry-type",
                            locale: locale
                        )
                    )

                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(categories) { category in
                            categoryButton(category)
                        }
                        manageButton
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .paperPage()
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

    /// 单个分类：系统图标落在随手涂出的色块上，选中的那个涂成实墨色。
    private func categoryButton(_ category: BookkeepingCategoryItem) -> some View {
        let isSelected = category.key == selectedKey

        return Button {
            onSelect(category)
        } label: {
            categoryLabel(
                symbolName: category.symbolName,
                title: category.title(locale: locale),
                seed: category.key.handDrawnSeed,
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("\(accessibilityPrefix)-\(category.key)")
    }

    /// 网格末尾的「管理」入口，在面板自己的导航栈里打开分类管理页。
    private var manageButton: some View {
        NavigationLink {
            CategoryManagementView(initialDirection: entryType)
        } label: {
            categoryLabel(
                symbolName: "slider.horizontal.3",
                title: AccountLocalization.string("category.management.entry", locale: locale),
                seed: "category-management".handDrawnSeed,
                isSelected: false
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("\(accessibilityPrefix)-manage")
    }

    /// 分类按钮与「管理」入口共用的图标加名称样式。
    private func categoryLabel(
        symbolName: String,
        title: String,
        seed: UInt64,
        isSelected: Bool
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbolName)
                .font(.title2.weight(.medium))
                .foregroundStyle(isSelected ? Color(.onAccent) : Color.primary)
                .frame(width: 56, height: 56)
                .background {
                    HandDrawnBlob(seed: seed)
                        .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.08))
                }

            Text(title)
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .top)
    }
}
