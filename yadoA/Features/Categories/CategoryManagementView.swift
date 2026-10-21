import SwiftData
import SwiftUI

/// 分类编辑页的打开方式。
enum CategoryEditorRoute: Identifiable, Hashable {
    /// 在指定方向下新增自定义分类。
    case create(BookkeepingEntryType)

    /// 编辑自定义分类；预置分类的名称和图标固定，不会进入编辑页。
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

/// 一次删除请求：被删除的分类及删除对流水的影响。
struct CategoryDeletionRequest: Identifiable, Hashable {
    /// 要删除的分类，预置或自定义均可。
    let item: BookkeepingCategoryItem

    /// 该分类下的流水笔数及其中不能删除的笔数；没有流水时只需二次确认。
    let impact: CategoryDeletionImpact

    /// 使用分类标识作为 Sheet 标识。
    var id: String { item.id }
}

/// 分类管理页：支出、收入分类的新增、编辑、排序和删除。
///
/// 只有自定义分类显示进入编辑的箭头；除「其他」外都能左滑删除，「其他」没有左滑操作并在行内提示不能删除。
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

    /// 有流水的分类等待选择迁移或一并删除。
    @State private var deletionWithTransactions: CategoryDeletionRequest?

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
        let items = catalog.items(for: direction)

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
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    row(item)
                        .ledgerRow(seed: 300 + UInt64(index), showsRule: index != items.count - 1)
                }
                .onMove { source, destination in
                    move(items, from: source, to: destination)
                }
            } header: {
                Text(text("category.management.section.visible"))
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(.primary)
                    .ledgerHeadingRule(seed: 298)
            } footer: {
                Text(text("category.management.footer"))
            }
        }
        .environment(\.editMode, $editMode)
        .animation(.default, value: items.map(\.id))
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
        .sheet(item: $deletionWithTransactions) { request in
            NavigationStack {
                CategoryDeleteView(
                    request: request,
                    targets: catalog.items(for: request.item.direction)
                        .filter { $0.key != request.item.key },
                    onConfirm: { disposition in
                        delete(request.item, transactions: disposition)
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
                // 本机没有流水时也记下兜底目标，以后同步到其他设备时把那边的流水迁到「其他」。
                delete(request.item, transactions: .migrate(to: BookkeepingCategoryKey.other))
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

    /// 分类行：自定义分类点击进入编辑；除「其他」外左滑可删除。
    private func row(_ item: BookkeepingCategoryItem) -> some View {
        rowContent(item)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if item.canDelete {
                    // 不用 destructive 角色：List 会在点击时立即移除该行，用户取消确认后行就凭空消失了；
                    // 真正删除由确认框或删除页完成，这里只用红色提示操作性质。
                    Button {
                        requestDeletion(of: item)
                    } label: {
                        Label(text("category.delete.action"), systemImage: "trash")
                    }
                    .tint(Color(.ledgerRed))
                }
            }
            .accessibilityIdentifier("category-row-\(item.key)")
    }

    /// 分类行内容：只有可编辑的自定义分类是按钮并显示箭头，预置分类只展示。
    @ViewBuilder
    private func rowContent(_ item: BookkeepingCategoryItem) -> some View {
        if item.canEdit {
            Button {
                guard !editMode.isEditing else { return }
                editorRoute = .edit(item)
            } label: {
                CategoryRowLabel(item: item, subtitle: subtitle(for: item))
            }
            .buttonStyle(.plain)
        } else {
            CategoryRowLabel(item: item, subtitle: subtitle(for: item), showsChevron: false)
        }
    }

    /// 行内的补充说明：只给「其他」提示不能删除，其余分类不显示。
    private func subtitle(for item: BookkeepingCategoryItem) -> String? {
        item.isOther ? text("category.other.hint") : nil
    }

    // MARK: - 操作

    /// 把拖拽后的分类顺序写回存储。
    private func move(_ items: [BookkeepingCategoryItem], from source: IndexSet, to destination: Int) {
        var reordered = items
        reordered.move(fromOffsets: source, toOffset: destination)
        perform {
            try repository.reorder(reordered.map(\.key), direction: direction)
        }
    }

    /// 先统计流水：没有流水只需确认，有流水则让用户选择迁移还是一并删除。
    private func requestDeletion(of item: BookkeepingCategoryItem) {
        do {
            let impact = try repository.deletionImpact(key: item.key, direction: item.direction)
            let request = CategoryDeletionRequest(item: item, impact: impact)
            if impact.transactionCount == 0 {
                pendingDeletion = request
            } else {
                deletionWithTransactions = request
            }
        } catch {
            isOperationFailed = true
        }
    }

    /// 删除分类，并按用户选择迁移或删除它的流水。
    private func delete(_ item: BookkeepingCategoryItem, transactions disposition: CategoryTransactionDisposition) {
        perform {
            try repository.delete(key: item.key, direction: item.direction, transactions: disposition)
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

/// 分类行的图标、名称和补充说明，管理页与删除页共用。
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
