# 项目通用规则

本文件适用于整个仓库。后续新增规则统一记录在这里。

## Git 提交

- 本项目提交或推送代码时，不使用 `wb-commit` 技能；按照本仓库自身的 Git 约定执行。

## 系统版本兼容

- 本项目最低支持 **iOS 18**，所有功能必须在 iOS 18 上可编译、可运行。
- **鼓励使用 iOS 26 及更高版本的新 API**（如 Liquid Glass 系列 `glassEffect`、`GlassEffectContainer`、`tabBarMinimizeBehavior`、`scrollEdgeEffect`、`FoundationModels` 等），让高版本系统拿到更好的体验。
- 使用高版本 API 时必须做可用性判断与降级处理，保证 iOS 18 上有可接受的等价表现（可以是简化效果或原生替代方案，但不能崩溃、不能功能缺失）：
  - Swift 代码用 `if #available(iOS 26, *) { ... } else { ... }`；
  - SwiftUI 修饰符用条件包装（如自定义 `ViewModifier` + `@available` 分支）或 `if #available` 分支返回不同视图，不要直接裸调用。
- 禁止的只是**无降级分支的裸调用**，以及为了用新 API 而抬高工程最低版本。
- 新增依赖或 SPM 包前，需确认其 deployment target 不高于 iOS 18。
- 工程 `IPHONEOS_DEPLOYMENT_TARGET` 应保持为 18.x，不得随 Xcode 升级被自动抬高。

## 多语言与外观适配

- 所有面向用户的文案必须支持本地化，使用 iOS 原生本地化资源，不直接硬编码仅适用于单一语言的文案。
- 所有界面必须同时适配浅色和深色外观；优先使用系统语义色或在 Asset Catalog 中配置的动态颜色，避免写死只适用于单一外观的颜色值。

## 注释规范

- 新增或修改类型、属性、常量、方法和函数时，尽量补充中文文档注释，说明业务含义、职责或关键约束。
- Swift 的声明级文档注释统一使用 `///`，不要用 `/** */` 代替；需要补充参数、返回值或异常时使用 `- Parameter`、`- Returns`、`- Throws` 等 Swift 文档标记。
- 普通 `//` 只用于流程说明、局部实现细节和 `// MARK:` 分组；局部变量不要求逐个写文档注释，只有在含义不明显时补充说明。
