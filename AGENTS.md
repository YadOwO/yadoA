# 项目通用规则

本文件适用于整个仓库。后续新增规则统一记录在这里。

## Git 提交

- 本项目提交或推送代码时，不使用 `wb-commit` 技能；按照本仓库自身的 Git 约定执行。

## 测试与验证

- 代码改完即可交付，不主动执行编译、单元测试或 UI 测试（如 `xcodebuild build/test`、启动模拟器）；验证由开发者本人完成。
- 仍需同步维护受影响的测试代码（新增或更新断言），只是不运行；交付时说明哪些内容未经验证、建议重点测试什么。
- 只有在开发者明确要求时才运行测试。

## 环境与构建配置

- 环境只有两套：dev（Mac mini 上的整套服务，独立的 Logto、数据库和各后端，经 `dev-*.yado1225.top` 这组公网域名访问）和线上。由构建配置在编译时决定，见 `Features/Auth/AppEnvironment.swift`。

  | 配置 | 环境 | Bundle ID | 图标 | Scheme | 用途 |
  | --- | --- | --- | --- | --- | --- |
  | Debug | dev | `com.yado.yadoA.dev` | `AppIconDev` | `yadoA` | 日常开发、测试 |
  | DebugProd | 线上 | `top.yado1225.yadoA` | `AppIcon` | `yadoA-prod` | 断点排查线上问题 |
  | Release | 线上 | `top.yado1225.yadoA` | `AppIcon` | 各 Scheme 的 Archive | 出包（TestFlight 和上架是同一个包） |

- dev 包靠图标区分：`AppIconDev.icon` 是 `AppIcon.icon` 的副本，换成蓝色背景、右上角加黄色「DEV」丝带。改正式图标时同步改这份副本。显示名两个包相同，因为 `InfoPlist.xcstrings` 按语言给 `CFBundleDisplayName` 定了值，会盖过构建设置。

- 登录、各后端地址、本机数据整套跟着环境走：dev 包和线上包是两个 App，数据各一份，不要做"同一个包里切环境"。
- 随环境变化的值只放在 `AuthConfig` 的 `dev` / `prod` 两套取值里，业务代码读 `AuthConfig.xxx`，不要在别处写死地址或自己按环境分支。
- 开发机上不跑后端：dev 的服务都在 Mac mini 上，App 里没有"改连本机服务"的开关，不要再加。
- 新增构建配置必须带 `ENV_DEV` 或 `ENV_PROD` 标志，否则编译失败。

## 系统版本兼容

- 截至 **2026-09-30**，当前最新系统版本为 **iOS 27**；开发与适配时应同时考虑 iOS 27、iOS 26 和最低支持版本 iOS 18。
- 本项目最低支持 **iOS 18**，所有功能必须在 iOS 18 上可编译、可运行。
- **鼓励使用 iOS 26 及更高版本的新 API**（如 Liquid Glass 系列 `glassEffect`、`GlassEffectContainer`、`tabBarMinimizeBehavior`、`scrollEdgeEffect`、`FoundationModels` 等），让高版本系统拿到更好的体验。
- 使用高版本 API 时必须做可用性判断与降级处理，保证 iOS 18 上有可接受的等价表现（可以是简化效果或原生替代方案，但不能崩溃、不能功能缺失）：
  - Swift 代码按 API 实际引入版本判断，例如 `if #available(iOS 27, *) { ... } else { ... }` 或 `if #available(iOS 26, *) { ... } else { ... }`；
  - SwiftUI 修饰符用条件包装（如自定义 `ViewModifier` + `@available` 分支）或 `if #available` 分支返回不同视图，不要直接裸调用。
- 禁止的只是**无降级分支的裸调用**，以及为了用新 API 而抬高工程最低版本。
- 新增依赖或 SPM 包前，需确认其 deployment target 不高于 iOS 18。
- 工程 `IPHONEOS_DEPLOYMENT_TARGET` 应保持为 18.x，不得随 Xcode 升级被自动抬高。
- 底部导航固定为记账、图表、账户、“我的”四个一级入口，不再设搜索 Tab；记账搜索是记账页右上角进入的二级页面。启动页面对应的 Tab 排第一，“我的”始终在最右。

## 多语言与外观适配

- 所有面向用户的文案必须支持本地化，使用 iOS 原生本地化资源，不直接硬编码仅适用于单一语言的文案。
- 所有界面必须同时适配浅色和深色外观；优先使用系统语义色或在 Asset Catalog 中配置的动态颜色，避免写死只适用于单一外观的颜色值。

## 对话文字交互

- 对话类页面（意见反馈、AI 对话、语音卡片）里用户的话和回复正文加 `conversationTextSelection()`，气泡底色用 `conversationBubble(_:in:)`，都在 `Components/ConversationStyle.swift`；不要直接写 `.textSelection(.enabled)` 或自己挑气泡底色。
- 背后是系统的长按选中：iOS 27 起出现选择手柄，可以选中一段；iOS 18～26 弹出系统菜单，拷贝或共享整段。强调色是中性墨色，选中颜色因此改用系统蓝，气泡也只用浅底，不用墨色实心。
- 同一段文字不要再叠 `.contextMenu`，会和长按选中冲突；`Button` 里的文字系统不支持选中。

## 注释规范

- 新增或修改类型、属性、常量、方法和函数时，尽量补充中文文档注释，说明业务含义、职责或关键约束。
- Swift 的声明级文档注释统一使用 `///`，不要用 `/** */` 代替；需要补充参数、返回值或异常时使用 `- Parameter`、`- Returns`、`- Throws` 等 Swift 文档标记。
- 普通 `//` 只用于流程说明、局部实现细节和 `// MARK:` 分组；局部变量不要求逐个写文档注释，只有在含义不明显时补充说明。

## 本地数据模型改动

- 本地 SwiftData 库从 `FinanceSchemaV1`（`versionIdentifier` 9.0.0）开始版本化，所有版本和迁移步骤都在 `Persistence/FinanceSchema.swift` 的 `FinanceMigrationPlan` 里；`AccountDataContainer` 的文件容器和内存容器都带这个迁移计划打开，`AccountDataContainer.schema` 始终取最新版本。
- 上线后改任何 `@Model`（加字段、改关系、改类型、删字段），按下面的顺序做：
  1. 先把当前版本的模型定义原样冻结进旧版本的 VersionedSchema：把要改的模型复制成 `FinanceSchemaV<n>` 的嵌套 `@Model` 类。类名、存储属性、`@Attribute` / `@Relationship` 和初始化方法照抄，计算属性和业务方法不用带。旧版本的 `models` 改为引用这些冻结副本，旧版本里不能再引用这次要改的顶层类。写法参照 yadoI 的 `LocalDataSchemaV1.LocalItemRecord`。没改的模型可以继续引用顶层类。
  2. 再改顶层模型，新建 `FinanceSchemaV<n+1>`：`versionIdentifier` 必须比上一版大且不重复，例如 V2 用 10.0.0；`models` 引用顶层类。
  3. 把新版本追加到 `FinanceMigrationPlan.schemas` 末尾，在 `stages` 里追加对应的一步：能轻量迁移的（新增可选字段或带默认值的字段、新增模型等）用 `.lightweight`；不能的写 `.custom`，在 `willMigrate` / `didMigrate` 里搬数据。
  4. `AccountDataContainer.schema` 改为取 `FinanceSchemaV<n+1>.schema`。`ModelConfiguration` 的名字（`FinanceSchemaV9` / `FinanceSchemaV9Preview`）和默认存储路径不要改，否则用户手机上的库会找不到。
  5. 同时补一条迁移测试：在临时目录用 `FinanceSchemaV<n>.schema` 建文件库，写入数据后关掉，再用 `AccountDataContainer.fileBacked(storeURL:)` 打开，校验记录数和关键字段，参照 `yadoATests/FinanceSchemaMigrationTests.swift`。
- 已发布的版本只追加，不修改也不删除。不要直接改模型后指望 SwiftData 自动推断迁移：推断失败时启动会停在「本地数据暂不可用」的阻断页，用户打不开 App。

## 经验

动手改代码前先读 `docs/agent-lessons/` 下的文件：以前的 agent 犯过的错总结成的规则，由 yado_agents 自动维护。
