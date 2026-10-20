import SwiftData
import SwiftUI

/// 新增或编辑一个自定义分类。
///
/// 预置分类的名称和图标固定，管理页不会为它们打开这个页面。
/// 名称规则在输入时实时提示，同时禁用保存，不等点了保存才报错。
struct CategoryEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Query private var categories: [BookkeepingCategory]

    /// 打开方式：新增或编辑。
    let route: CategoryEditorRoute

    /// 名称输入框的当前内容。
    @State private var name: String

    /// 当前选中的图标；新增时需要用户主动选择。
    @State private var symbolName: String?

    /// 最近一次保存是否失败。
    @State private var isSaveFailed = false

    /// - Parameter route: 新增或编辑的目标。
    init(route: CategoryEditorRoute) {
        self.route = route
        switch route {
        case .create:
            _name = State(initialValue: "")
            _symbolName = State(initialValue: nil)
        case let .edit(item):
            _name = State(initialValue: item.customName ?? "")
            _symbolName = State(initialValue: item.symbolName)
        }
    }

    /// 正在编辑的分类；新增时为 `nil`。
    private var editingItem: BookkeepingCategoryItem? {
        if case let .edit(item) = route { return item }
        return nil
    }

    /// 当前名称不满足的规则。
    private var nameIssue: CategoryNameIssue? {
        LocalCategoryRepository.nameIssue(
            name,
            direction: route.direction,
            excludingKey: editingItem?.key,
            catalog: BookkeepingCategoryCatalog(categories: categories),
            locale: locale
        )
    }

    /// 名称合法且已选图标时才允许保存。
    private var canSave: Bool {
        nameIssue == nil && symbolName != nil
    }

    var body: some View {
        Form {
            Section {
                symbolPreview
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }

            Section {
                TextField(
                    text("category.edit.name.placeholder"),
                    text: $name
                )
                .accessibilityIdentifier("category-edit-name")
            } header: {
                Text(text("category.edit.name"))
            } footer: {
                nameFooter
            }

            Section {
                NavigationLink {
                    CategorySymbolPickerView(selection: $symbolName)
                } label: {
                    HStack {
                        Text(text(symbolName == nil ? "category.edit.symbol.choose" : "category.edit.symbol.change"))
                        Spacer()
                        if let symbolName {
                            Image(systemName: symbolName)
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .accessibilityIdentifier("category-edit-symbol")
            } header: {
                Text(text("category.edit.symbol"))
            }
        }
        .paperPage()
        .navigationTitle(text(editingItem == nil ? "category.edit.title.create" : "category.edit.title.edit"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(text("common.cancel")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(text("common.save")) { save() }
                    .disabled(!canSave)
                    .accessibilityIdentifier("category-edit-save")
            }
        }
        .alert(text("category.management.failed"), isPresented: $isSaveFailed) {
            Button(text("common.close"), role: .cancel) {}
        }
    }

    /// 页面顶部的大图标；还没选图标时显示虚线占位。
    private var symbolPreview: some View {
        let displayedSymbol = symbolName ?? "questionmark"
        return Image(systemName: displayedSymbol)
            .font(.largeTitle.weight(.medium))
            .foregroundStyle(symbolName == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
            .frame(width: 88, height: 88)
            .background {
                HandDrawnBlob(seed: (editingItem?.key ?? "new-category").handDrawnSeed)
                    .fill(Color.accentColor.opacity(0.08))
            }
            .accessibilityHidden(true)
    }

    /// 名称下方的字数和实时校验结果。
    private var nameFooter: some View {
        let count = LocalCategoryRepository.cleanedName(name).count
        return HStack(alignment: .firstTextBaseline) {
            if let message = issueMessage {
                Text(message)
                    .foregroundStyle(Color(.ledgerRed))
                    .accessibilityIdentifier("category-edit-name-issue")
            }
            Spacer()
            Text(verbatim: "\(count)/\(LocalCategoryRepository.nameLengthLimit)")
                .monospacedDigit()
                .foregroundStyle(
                    count > LocalCategoryRepository.nameLengthLimit
                        ? AnyShapeStyle(Color(.ledgerRed))
                        : AnyShapeStyle(.secondary)
                )
        }
    }

    /// 需要提示给用户的名称问题；空名称只禁用保存，不显示红字，避免刚打开页面就报错。
    private var issueMessage: String? {
        switch nameIssue {
        case .none, .empty:
            nil
        case .tooLong:
            String(
                format: text("category.edit.name.too_long"),
                locale: locale,
                LocalCategoryRepository.nameLengthLimit
            )
        case let .duplicate(existingTitle):
            String(
                format: text("category.edit.name.duplicate"),
                locale: locale,
                route.direction.localizedTitle(locale: locale),
                existingTitle
            )
        }
    }

    /// 通过仓库保存；成功后关闭页面，失败保留输入并提示。
    private func save() {
        guard canSave, let symbolName else { return }
        let repository = LocalCategoryRepository(container: modelContext.container)
        do {
            switch route {
            case let .create(direction):
                try repository.create(
                    name: name,
                    symbolName: symbolName,
                    direction: direction,
                    locale: locale
                )
            case let .edit(item):
                try repository.update(
                    key: item.key,
                    direction: item.direction,
                    name: name,
                    symbolName: symbolName,
                    locale: locale
                )
            }
            dismiss()
        } catch {
            isSaveFailed = true
        }
    }

    /// 按当前应用语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}
