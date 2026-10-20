import SwiftData
import SwiftUI

/// 分类编辑页的打开方式。
enum CategoryEditorRoute: Identifiable, Hashable {
    /// 在指定方向下新增自定义分类。
    case create(BookkeepingEntryType)

    /// 编辑已有分类；预置分类只能换图标。
    case edit(BookkeepingCategoryItem)

    /// Sheet 使用的稳定标识。
    var id: String {
        switch self {
        case let .create(direction): "create.\(direction.rawValue)"
        case let .edit(item): "edit.\(item.id)"
        }
    }

    /// 编辑页对应的收支方向。
    var direction: BookkeepingEntryType {
        switch self {
        case let .create(direction): direction
        case let .edit(item): item.direction
        }
    }
}

/// 一次删除请求：被删除的分类及引用它的流水笔数。
struct CategoryDeletionRequest: Identifiable, Hashable {
    /// 要删除的自定义分类。
    let item: BookkeepingCategoryItem

    /// 引用该分类的流水笔数；为零时只需二次确认，不需要选择迁移目标。
    let transactionCount: Int

    /// 使用分类标识作为 Sheet 标识。
    var id: String { item.id }
}

/// 分类管理页：支出、收入分类的新增、编辑、排序、隐藏和删除。
///
/// 规则限制都在界面上直接表达：预置分类左滑只有「隐藏」，自定义分类左滑是「删除」，
/// 「其他」没有左滑操作并在行内说明用途，避免用户点了没反应才发现做不了。
struct CategoryManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.locale) private var locale
    @Query private var categories: [BookkeepingCategory]

    /// 当前管理的收支方向。
    @State private var direction: BookkeepingEntryType

    /// 是否处于拖拽排序状态。
    @State private var editMode: EditMode = .inactive

    /// 正在打开的新增或编辑页。
    @State private var editorRoute: CategoryEditorRoute?

    /// 没有流水的分类等待二次确认删除。
    @State private var pendingDeletion: CategoryDeletionRequest?

    /// 有流水的分类等待选择迁移目标。
    @State private var migrationRequest: CategoryDeletionRequest?

    /// 最近一次写操作是否失败。
    @State private var isOperationFailed = false

    /// - Parameter initialDirection: 打开时显示的收支方向；从记账面板进入时与面板一致。
    init(initialDirection: BookkeepingEntryType = .expense) {
        _direction = State(initialValue: initialDirection)
    }

    /// 存储中的分类设置与预置默认值合并后的目录。
    private var catalog: BookkeepingCategoryCatalog {
        BookkeepingCategoryCatalog(categories: categories)
    }

    var body: some View {
        let visibleItems = catalog.visibleItems(for: direction)
        let hiddenItems = catalog.hiddenItems(for: direction)

        List {
            Section {
                LedgerSwitch(
                    label: text("bookkeeping.entry.type"),
                    selection: $direction,
                    options: BookkeepingEntryType.ledgerSwitchOptions(
                        identifier: "category-management-type",
                        locale: locale
                    )
                )
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section {
                ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                    visibleRow(item)
                        .ledgerRow(seed: 300 + UInt64(index), showsRule: index != visibleItems.count - 1)
                }
                .onMove { source, destination in
                    move(visibleItems, hiddenItems: hiddenItems, from: source, to: destination)
                }
            } header: {
                Text(text("category.management.section.visible"))
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(.primary)
                    .ledgerHeadingRule(seed: 298)
            } footer: {
                Text(text("category.management.footer"))
            }

            if !hiddenItems.isEmpty {
                Section {
                    ForEach(Array(hiddenItems.enumerated()), id: \.element.id) { index, item in
                        hiddenRow(item)
                            .ledgerRow(seed: 400 + UInt64(index), showsRule: index != hiddenItems.count - 1)
                    }
                } header: {
                    Text(text("category.management.section.hidden"))
                        .font(.system(.headline, design: .serif))
                        .foregroundStyle(.primary)
                        .ledgerHeadingRule(seed: 299)
                } footer: {
                    Text(text("category.management.hidden.footer"))
                }
            }
        }
        .environment(\.editMode, $editMode)
        .animation(.default, value: categories.count)
        .paperPage()
        .navigationTitle(text("category.management.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(text(editMode.isEditing ? "common.done" : "category.management.sort")) {
                    withAnimation {
                        editMode = editMode.isEditing ? .inactive : .active
                    }
                }
                .accessibilityIdentifier("category-management-sort")

                Button {
                    editorRoute = .create(direction)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(text("category.management.add"))
                .accessibilityIdentifier("category-management-add")
                .disabled(editMode.isEditing)
            }
        }
        .sheet(item: $editorRoute) { route in
            NavigationStack {
                CategoryEditView(route: route)
            }
        }
        .sheet(item: $migrationRequest) { request in
            NavigationStack {
                CategoryDeleteMigrationView(
                    request: request,
                    targets: catalog.visibleItems(for: request.item.direction)
                        .filter { $0.key != request.item.key },
                    onConfirm: { targetKey in
                        delete(request.item, migratingTo: targetKey)
                    }
                )
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog(
            pendingDeletion.map {
                String(format: text("category.delete.confirm.title"), locale: locale, $0.item.title(locale: locale))
            } ?? "",
            isPresented: isPresented($pendingDeletion),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { request in
            Button(text("category.delete.action"), role: .destructive) {
                delete(request.item, migratingTo: BookkeepingCategoryKey.other)
            }
            Button(text("common.cancel"), role: .cancel) {}
        } message: { _ in
            Text(text("category.delete.confirm.message"))
        }
        .alert(text("category.management.failed"), isPresented: $isOperationFailed) {
            Button(text("common.close"), role: .cancel) {}
        }
    }

    // MARK: - 行

    /// 可见分类：点击进入编辑；左滑按分类类型给出「删除」或「隐藏」。
    private func visibleRow(_ item: BookkeepingCategoryItem) -> some View {
        Button {
            guard !editMode.isEditing else { return }
            editorRoute = .edit(item)
        } label: {
            CategoryRowLabel(item: item, subtitle: subtitle(for: item))
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if item.canDelete {
                Button(role: .destructive) {
                    requestDeletion(of: item)
                } label: {
                    Label(text("category.delete.action"), systemImage: "trash")
                }
            } else if item.canHide {
                Button {
                    setHidden(true, item: item)
                } label: {
                    Label(text("category.hide.action"), systemImage: "eye.slash")
                }
                .tint(.gray)
            }
        }
        .accessibilityIdentifier("category-row-\(item.key)")
    }

    /// 已隐藏分类：行尾直接给出「恢复」，不用左滑也能找到。
    private func hiddenRow(_ item: BookkeepingCategoryItem) -> some View {
        HStack {
            CategoryRowLabel(item: item, subtitle: nil, showsChevron: false)
                .opacity(0.6)
            Button(text("category.unhide.action")) {
                setHidden(false, item: item)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("category-unhide-\(item.key)")
        }
        .accessibilityIdentifier("category-hidden-row-\(item.key)")
    }

    /// 行内的补充说明：「其他」说明它的兜底用途，其余预置分类标明是系统分类。
    private func subtitle(for item: BookkeepingCategoryItem) -> String? {
        if item.isOther { return text("category.other.hint") }
        if item.isPreset { return text("category.preset.badge") }
        return nil
    }

    // MARK: - 操作

    /// 把拖拽后的可见分类顺序写回存储；已隐藏的分类保持原顺序排在后面。
    private func move(
        _ visibleItems: [BookkeepingCategoryItem],
        hiddenItems: [BookkeepingCategoryItem],
        from source: IndexSet,
        to destination: Int
    ) {
        var reordered = visibleItems
        reordered.move(fromOffsets: source, toOffset: destination)
        perform {
            try repository.reorder(
                reordered.map(\.key) + hiddenItems.map(\.key),
                direction: direction
            )
        }
    }

    /// 隐藏或恢复分类。
    private func setHidden(_ isHidden: Bool, item: BookkeepingCategoryItem) {
        perform {
            try repository.setHidden(isHidden, key: item.key, direction: item.direction)
        }
    }

    /// 先统计流水：没有流水只需确认，有流水则让用户选择迁移目标。
    private func requestDeletion(of item: BookkeepingCategoryItem) {
        do {
            let count = try repository.transactionCount(key: item.key, direction: item.direction)
            let request = CategoryDeletionRequest(item: item, transactionCount: count)
            if count == 0 {
                pendingDeletion = request
            } else {
                migrationRequest = request
            }
        } catch {
            isOperationFailed = true
        }
    }

    /// 删除分类并把流水迁到目标分类。
    private func delete(_ item: BookkeepingCategoryItem, migratingTo targetKey: String) {
        perform {
            try repository.delete(key: item.key, direction: item.direction, migratingTo: targetKey)
        }
    }

    /// 执行一次写操作，失败时统一提示。
    private func perform(_ work: () throws -> Void) {
        do {
            try work()
        } catch {
            isOperationFailed = true
        }
    }

    /// 当前容器上的分类仓库。
    private var repository: LocalCategoryRepository {
        LocalCategoryRepository(container: modelContext.container)
    }

    /// 把可选状态转换为确认框需要的布尔绑定。
    private func isPresented<Value>(_ value: Binding<Value?>) -> Binding<Bool> {
        Binding(
            get: { value.wrappedValue != nil },
            set: { if !$0 { value.wrappedValue = nil } }
        )
    }

    /// 按当前应用语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 分类行的图标、名称和补充说明，管理页与迁移页共用。
struct CategoryRowLabel: View {
    @Environment(\.locale) private var locale

    /// 要展示的分类。
    let item: BookkeepingCategoryItem

    /// 名称下方的补充说明；为空时不显示。
    let subtitle: String?

    /// 是否在行尾显示进入编辑的箭头。
    var showsChevron = true

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: item.symbolName)
                .font(.title3.weight(.medium))
                .foregroundStyle(Color.primary)
                .frame(width: 44, height: 44)
                .background {
                    HandDrawnBlob(seed: item.key.handDrawnSeed)
                        .fill(Color.primary.opacity(0.08))
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title(locale: locale))
                    .font(.body)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack {
        CategoryManagementView()
    }
    .modelContainer(try! AccountDataContainer.inMemory().modelContainer)
}
