import Foundation

/// 一个分类在某一时刻的只读快照，供记账面板、各类投影和管理页共用。
struct BookkeepingCategoryItem: Identifiable, Hashable, Sendable {
    /// 所属收支方向。
    let direction: BookkeepingEntryType

    /// 流水引用的分类 key。
    let key: String

    /// 自定义分类的用户名称；预置分类为 `nil`。
    let customName: String?

    /// 分类图标。
    let symbolName: String

    /// 同一方向内的展示顺序。
    let sortIndex: Int

    /// 是否在记账面板中隐藏。
    let isHidden: Bool

    /// 是否已删除（墓碑）。
    let isDeleted: Bool

    /// 删除时流水迁往的分类 key；未删除时为 `nil`。
    let replacementKey: String?

    /// 含方向前缀的稳定标识，避免收入与支出的同名 key 冲突。
    var id: String { "\(direction.rawValue).\(key)" }

    /// 是否为预置分类。
    var isPreset: Bool { BookkeepingCategoryKey.isPreset(key, direction: direction) }

    /// 是否为该方向的「其他」分类；它是删除迁移的兜底目标，不能隐藏。
    var isOther: Bool { key == BookkeepingCategoryKey.other }

    /// 只有自定义分类可以改名。
    var canRename: Bool { !isPreset }

    /// 只有自定义分类可以删除。
    var canDelete: Bool { !isPreset }

    /// 除「其他」外都可以隐藏。
    var canHide: Bool { !isOther }

    /// 返回当前语言环境下的分类名称；自定义分类按用户输入原样显示。
    ///
    /// - Parameter locale: 预置分类读取 String Catalog 使用的语言环境。
    /// - Returns: 分类名称。
    func title(locale: Locale = .current) -> String {
        if let customName { return customName }
        return AccountLocalization.string("\(direction.rawValue).category.\(key)", locale: locale)
    }

    /// 由预置默认配置生成快照。
    init(preset: BookkeepingPresetCategory) {
        self.init(
            direction: preset.direction,
            key: preset.key,
            customName: nil,
            symbolName: preset.symbolName,
            sortIndex: preset.sortIndex,
            isHidden: false,
            isDeleted: false,
            replacementKey: nil
        )
    }

    /// 由持久化分类生成快照；方向未知的损坏记录返回 `nil`。
    init?(category: BookkeepingCategory) {
        guard let direction = category.direction,
              BookkeepingCategoryKey.isValid(category.key, direction: direction)
        else { return nil }
        let isPreset = BookkeepingCategoryKey.isPreset(category.key, direction: direction)
        self.init(
            direction: direction,
            key: category.key,
            customName: isPreset ? nil : category.customName,
            symbolName: category.symbolName,
            sortIndex: category.sortIndex,
            isHidden: category.isHidden,
            isDeleted: category.isTombstoned,
            replacementKey: category.replacementKey
        )
    }

    /// 成员逐一初始化，供测试和预览构造快照。
    init(
        direction: BookkeepingEntryType,
        key: String,
        customName: String?,
        symbolName: String,
        sortIndex: Int,
        isHidden: Bool,
        isDeleted: Bool,
        replacementKey: String? = nil
    ) {
        self.direction = direction
        self.key = key
        self.customName = customName
        self.symbolName = symbolName
        self.sortIndex = sortIndex
        self.isHidden = isHidden
        self.isDeleted = isDeleted
        self.replacementKey = replacementKey
    }
}

/// 预置分类默认值与用户分类设置合并后的分类目录。
///
/// 存储中缺少某个预置分类的行时使用默认值兜底，所以即使启动补齐失败，
/// 记账和展示也不会出错。所有需要分类名称或图标的地方都通过它解析 key。
struct BookkeepingCategoryCatalog: Equatable, Sendable {
    /// 只含预置默认值的目录，供测试、预览和尚未读取存储的场景使用。
    static let presets = BookkeepingCategoryCatalog(items: [])

    /// 按 `BookkeepingCategoryItem.id` 索引的全部分类，包含已删除的墓碑。
    private let itemsByID: [String: BookkeepingCategoryItem]

    /// 每个方向下未删除的分类，已按展示顺序排列。
    private let orderedItems: [BookkeepingEntryType: [BookkeepingCategoryItem]]

    /// 由持久化分类构造目录。
    ///
    /// - Parameter categories: SwiftData 查询得到的全部分类行。
    init(categories: [BookkeepingCategory]) {
        self.init(items: categories.compactMap(BookkeepingCategoryItem.init(category:)))
    }

    /// 由分类快照构造目录；同一标识重复时保留第一条。
    ///
    /// - Parameter storedItems: 存储中的分类快照。
    init(items storedItems: [BookkeepingCategoryItem]) {
        var itemsByID: [String: BookkeepingCategoryItem] = [:]
        for item in storedItems where itemsByID[item.id] == nil {
            itemsByID[item.id] = item
        }
        for preset in BookkeepingCategoryKey.allPresets {
            let item = BookkeepingCategoryItem(preset: preset)
            if itemsByID[item.id] == nil {
                itemsByID[item.id] = item
            }
        }
        self.itemsByID = itemsByID

        var orderedItems: [BookkeepingEntryType: [BookkeepingCategoryItem]] = [:]
        for direction in BookkeepingEntryType.allCases {
            orderedItems[direction] = itemsByID.values
                .filter { $0.direction == direction && !$0.isDeleted }
                .sorted { lhs, rhs in
                    lhs.sortIndex == rhs.sortIndex ? lhs.key < rhs.key : lhs.sortIndex < rhs.sortIndex
                }
        }
        self.orderedItems = orderedItems
    }

    /// 指定方向下未删除的全部分类（含已隐藏），按展示顺序排列。
    func items(for direction: BookkeepingEntryType) -> [BookkeepingCategoryItem] {
        orderedItems[direction] ?? []
    }

    /// 指定方向下记账面板可选的分类。
    func visibleItems(for direction: BookkeepingEntryType) -> [BookkeepingCategoryItem] {
        items(for: direction).filter { !$0.isHidden }
    }

    /// 指定方向下已隐藏的分类。
    func hiddenItems(for direction: BookkeepingEntryType) -> [BookkeepingCategoryItem] {
        items(for: direction).filter(\.isHidden)
    }

    /// 记账面板展示的分类：可见分类，再补上当前已选但已隐藏的分类，避免编辑旧流水时选中项消失。
    ///
    /// - Parameters:
    ///   - direction: 收支方向。
    ///   - selectedKey: 当前草稿已选的分类 key。
    func pickerItems(
        for direction: BookkeepingEntryType,
        including selectedKey: String?
    ) -> [BookkeepingCategoryItem] {
        let visible = visibleItems(for: direction)
        guard let selectedKey,
              !visible.contains(where: { $0.key == selectedKey }),
              let selected = item(direction: direction, key: selectedKey),
              !selected.isDeleted
        else { return visible }
        return visible + [selected]
    }

    /// 精确查找分类，包含已删除的墓碑；不存在时返回 `nil`。
    func item(direction: BookkeepingEntryType, key: String) -> BookkeepingCategoryItem? {
        itemsByID["\(direction.rawValue).\(key)"]
    }

    /// 解析流水引用的分类；未知 key 按该方向的「其他」样式降级展示。
    func resolvedItem(direction: BookkeepingEntryType, key: String) -> BookkeepingCategoryItem {
        if let item = item(direction: direction, key: key) { return item }
        if let other = item(direction: direction, key: BookkeepingCategoryKey.other) { return other }
        return BookkeepingCategoryItem(
            preset: BookkeepingCategoryKey.preset(direction: direction, key: BookkeepingCategoryKey.other)!
        )
    }

    /// 新草稿默认使用的分类：该方向排序第一的可见分类。
    func defaultKey(for direction: BookkeepingEntryType) -> String {
        visibleItems(for: direction).first?.key ?? BookkeepingCategoryKey.other
    }
}
