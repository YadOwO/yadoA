---
title: "feat: Add category management"
type: feat
date: 2026-10-20
origin: docs/brainstorms/2026-10-20-category-management-requirements.md
---

# feat: Add category management

## Summary

新增持久化模型 `BookkeepingCategory`，用来保存分类的排序、隐藏状态、删除墓碑和自定义分类。流水依旧只存一个字符串 key，所有展示层改为通过分类目录（catalog）把 key 解析成名称和图标。schema 升到 V6。App 还没有上线，不考虑存量用户的数据迁移和旧备份兼容。

---

## Key Technical Decisions

- **KTD1. 流水用字符串 key 引用分类。** `AccountTransaction.categoryRawValue` 保留不动，取值分两种：
  - 预置分类：现有 rawValue，如 `dining`、`salary`；
  - 自定义分类：`custom.<小写 UUID>`。

  预置分类的 key 可读且各设备一致，语音记账、本地化和以后的同步都可以直接用；不同设备新建的自定义 key 也天然不会冲突。
- **KTD2. 预置定义保留在代码里，用户改动存在 `BookkeepingCategory` 中。**
  - `ExpenseCategory` / `IncomeCategory` 枚举保留，作为「预置目录」：负责默认顺序、默认图标和本地化 key。
  - 每个分类对应一行 `BookkeepingCategory`，字段如下：
    - `id: UUID`（唯一）
    - `directionRawValue`（`expense` / `income`）
    - `key`
    - `customName: String?`（预置分类为 nil）
    - `symbolName`
    - `sortIndex`
    - `isHidden`
    - `updatedAt`
    - `deletedAt: Date?`
    - `replacementKey: String?`
- **KTD3. 读取时容错，启动时补齐。** `LocalDataBootstrap` 在启动后幂等地补齐缺失的预置行。catalog 合并「预置定义 + 已存行」时，缺行就用默认值兜底，所以即使补齐失败，记账和展示也不会坏。
- **KTD4. 用 catalog 统一解析。** 新增值类型 `BookkeepingCategoryCatalog`，由 `[BookkeepingCategory]` 快照构造，提供：
  - `visibleItems(direction)`：记账面板使用；
  - `item(direction, key)`：展示使用。删除记录也能解析出原名，未知 key 回退为「其他」的样式。

  `AccountTransactionPayload` 改为 `.expense(categoryKey:amount:)` / `.income(categoryKey:amount:)`，原先的 `categoryTitle`、`categorySymbolName` 改为接收 catalog 参数。首页、图表、搜索、详情、账户流水这些投影都加一个 catalog 入参，视图层用 `@Query` 取分类后传进去。
- **KTD5. 写入时校验存在性，载荷层只校验格式。** `validatedPayload` 只检查 key 格式：要么是该方向的预置 rawValue，要么符合 `custom.<uuid>`。分类是否存在、是否已隐藏，由仓库在新建流水时检查。编辑已有流水时允许保留它当前的分类，即使该分类已隐藏。
- **KTD6. 删除用软删除，一次保存完成迁移。**
  - `LocalCategoryRepository.delete(key:migratingTo:)` 在同一个 manual-save context 里完成三件事：把相关流水改写为目标 key；写入 `deletedAt` 和 `replacementKey`；最后 save 一次。
  - 失败就整体回滚。
  - 删除记录不出现在列表里，但不做物理删除，为以后同步时「其他设备按同一目标迁移」预留。
- **KTD7. 同步身份。** 预置分类以「方向 + key」作为跨设备身份。自定义分类的 key 本身就包含 UUID。本期不接同步，只保证以后不需要再改数据结构。
- **KTD8. 名称校验放在仓库里，界面复用同一份结果。** 名称规则：
  - 去掉首尾空白后不能为空，长度不超过 10 个字符（按 `Character` 计数）；
  - 同方向下不能和未删除分类重名，包括预置分类的当前语言名称；比较时不区分大小写。

  仓库提供 `validateName(_:direction:excluding:) -> CategoryNameIssue?`，编辑页输入时实时调用，用来显示提示和禁用保存，保存时再校验一次。
- **KTD9. 图标库是静态数据。**
  - `CategorySymbolLibrary` 里放 14 个分组、约 250 个 symbol。
  - 每个 symbol 带中英文关键词，直接写在 `CategorySymbolLibrary.swift` 的静态数据里（关键词不是界面文案，不走 String Catalog）。搜索时同时匹配所有语言的关键词，所以中文界面输入 coffee 也能搜到。
  - 分组标题走 String Catalog 本地化。
- **KTD10. 备份新增分类数据。** App 未上线，格式版本保持 1，直接新增 `categories: [BackupCategory]`，包含删除记录。导入时，流水引用的 key 必须是预置分类，或者存在于备份的 categories 中，否则整体返回 `invalidContent`。
- **KTD11. 重置数据和撤销。** `LocalDataResetService.eraseAll` 会同时删除分类行，下次启动时补齐预置行。`DataUndoService` 基于备份快照工作，备份带上分类后自动包含分类，不需要额外改动。

---

## Implementation Units

### U1. 模型、schema 与补齐

- **新增文件：**
  - `yadoA/Models/BookkeepingCategory.swift`：模型和 key 工具。
  - `yadoA/Persistence/LocalCategoryRepository.swift`：先只实现 `ensurePresets()`。
- **修改：**
  - `AccountDataContainer`：schema 升到 `6.0.0`，加入新模型。
  - `LocalDataBootstrapView`：启动时调用 `ensurePresets()`。
  - `LocalDataResetService`：重置时一并删除分类。
- **测试：**
  - 首次启动后预置行齐全；
  - `ensurePresets` 重复执行不会产生重复行；
  - 重置后分类行被清空。

### U2. catalog 与载荷重构

- **新增：** `yadoA/Models/BookkeepingCategoryCatalog.swift`。
- **修改：**
  - `AccountTransaction.swift`：payload 改为用 key；工厂方法 `validatingExpense` / `validatingIncome` 改为接收 key，同时保留接收枚举的便捷重载，减少测试和夹具的改动。
  - `ExpenseCategoryPresentation.swift`：改为由 catalog 驱动。
  - `HomeOverviewPresentation`、`ChartOverviewPresentation`、`CategoryBreakdownPresentation`、`BookkeepingSearchPresentation`、`AccountTransactionHistoryPresentation`、`BookkeepingTransactionDetailView`：都接入 catalog。
  - 草稿：`DiningExpenseDraft` / `DiningExpenseEditDraft` 改为存 key。新草稿的默认分类取该方向排序第一的可见分类。
- **测试：**
  - 自定义分类的名称和图标在首页、图表、搜索中都能正确显示；
  - 改名后历史流水同步显示新名称；
  - 隐藏的分类仍参与统计和搜索；
  - 未知 key 按「其他」降级显示；
  - 中英文 locale 下搜索都能匹配到自定义分类名称。

### U3. 分类仓库写操作

- **方法：** `create`、`rename`、`changeSymbol`、`setHidden`、`move(direction:from:to:)`、`delete(key:migratingTo:)`、`transactionCount(key:)`、`validateName`。
- **约束：**
  - 预置分类的名称和图标固定，不能修改，但可以删除；
  - 「其他」不能隐藏或删除；
  - 迁移目标必须是同方向、未隐藏、未删除的分类，且不能是被删除的分类本身；
  - 新建的分类排在最后。
- **约定：** 沿用 `Local*Repository` 的写法：`@MainActor`、使用新的 manual-save context、提供 `beforeSave` 故障注入点、只 save 一次。
- **测试：** 覆盖每条约束；验证迁移的原子性（注入保存失败后，流水和分类都保持原样）；排序后 `sortIndex` 连续。

### U4. 图标库与图标选择页

- **新增文件：**
  - `yadoA/Features/Categories/CategorySymbolLibrary.swift`
  - `CategorySymbolPickerView.swift`
- **交互：**
  - 页面按分组用网格展示，顶部用 `.searchable` 实时过滤；
  - 没有结果时显示 `ContentUnavailableView.search`。
- **测试：**
  - 每个 symbol 都能用 `UIImage(systemName:)` 加载出来，在 iOS 18 模拟器上跑，作为 iOS 18 可用性的门槛；
  - 不同分组之间没有重复的 symbol；
  - 关键词匹配：「咖啡」「coffee」「猫」能搜到预期图标，「zzz」搜不到。

### U5. 分类管理页与入口

- **新增文件：** `yadoA/Features/Categories/` 下的 `CategoryManagementView`、`CategoryEditView`、`CategoryDeleteMigrationView`。
- **列表：**
  - 顶部用 `LedgerSwitch` 切换支出/收入；
  - 列表分为「分类」和「已隐藏」两个 section；
  - 右上角的「排序」按钮进入编辑模式，用 `.onMove` 拖拽调整顺序。
- **左滑操作：**
  - 自定义分类：「删除」，用破坏色；
  - 预置分类：「隐藏」，用普通色；
  - 「其他」：没有左滑操作，行内附说明文字。
- **编辑页：**
  - 预置分类的名称显示为只读，并附上说明；
  - 名称输入框带 `n/10` 计数，有重名或超长问题时实时提示并禁用保存按钮。
- **删除：**
  - 没有流水：用 `confirmationDialog` 确认后删除；
  - 有流水：弹出迁移页，标题为「将 N 笔流水移到」，默认选中「其他」，按钮文案为「移动并删除」。
- **入口：**
  - `ProfileView` 新增「分类管理」行；
  - `BookkeepingCategorySelectionView` 网格末尾加一个「管理」入口，在面板自己的 `NavigationStack` 里 push 管理页。
  - 记账面板改为显示 `visibleItems`，如果当前选中的分类已隐藏，也把它补进面板。
- **UI 测试：**
  - 新增分类后，记账面板中能看到它；
  - 拖拽排序后，记账面板顺序跟着变；
  - 删除带流水的分类并迁移后，图表里的数据随之变化；
  - 隐藏分类后，面板里看不到它，但搜索仍能找到历史流水。

### U6. 备份导入导出

- **修改：** `BackupFile` 新增 `BackupCategory`。`BackupExportService` 和 `BackupImportService` 的 restore 改为覆盖分类行，沿用「同 id 覆盖、多余的删除、缺少的插入」的做法。
- **测试：**
  - 备份往返导出导入后保持一致，包括删除记录；
  - 流水引用了不存在的自定义 key 时整体失败；
  - 撤销快照包含分类。

### U7. 本地化与收尾

- `Localizable.xcstrings` 补充中英文文案：管理页、编辑页、迁移页、各类错误提示、图标分组名。
- 更新 `HomeUITestFixture`，增加带自定义分类的夹具，同时更新 `HomeDesignPreview`。
- 新增界面全部使用系统语义色。iOS 26 及以上可以给管理页底部按钮加 `glassEffect`，iOS 18 降级为 `.regularMaterial`。

---

## Scope Boundaries

- 不做同步、二级分类、分类颜色、自定义图片或 emoji 图标。
- 删除分类不接入「撤销最近操作」，删除前确认受影响的流水笔数（已与产品确认）。
- 语音记账还没有实现，等它实现时直接读取 catalog 的 `visibleItems` 即可。

---

## Risks

- **改动面广：** payload 签名变化会影响所有投影和约 6 个测试文件。缓解办法是保留接收枚举的便捷工厂方法，让测试和夹具尽量不用改。
- **catalog 传递遗漏：** 如果某个投影忘了传 catalog，自定义分类就会显示成「其他」。实现时为了不改动约 70 处测试调用，投影的 catalog 参数默认 `.presets`；所有视图调用点已逐一传入 `@Query` 构造的目录，新增投影调用点时需注意。
- **图标在 iOS 18 不可用：** 图标库中有新版本才加入的 symbol 时会显示空白。用 U4 的加载测试作为门槛来防止。

---

## Verification Focus（交付时请开发者重点验证）

1. 删除带流水的自定义分类并迁移，确认首页、图表、搜索、账户流水的结果一致。
2. 在 iOS 18 设备上浏览图标库，确认没有空白图标。
3. 导出备份后在另一台设备导入，确认分类、排序、流水归属都一致。
4. 开发机上的旧数据如果打不开，删 App 重装即可（未上线，不做兼容）。
