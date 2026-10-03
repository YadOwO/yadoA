# 截图记账预设

[添加 yadoA 截图记账](https://www.icloud.com/shortcuts/adf5ca5c26d8471596bbc6f09d57c8d9)

预设包含两个动作：系统「截屏」，然后调用 yadoA 的 `ScreenshotBookkeepingIntent`。
第二步的 `screenshot` 参数已连接到第一步输出。用户只需确认添加，再到系统设置绑定「轻点背面」。

- `ScreenshotBookkeeping.plist`：从已发布的 iCloud 模板下载的可读源文件。
- `yadoA 截图记账.shortcut`：同一模板的苹果签名文件，使用「任何人」导入模式。
- App 入口：`yadoA/Features/Shortcuts/ScreenshotShortcutTemplate.swift`。

模板依赖已安装并包含该 Intent 的 iOS 版 yadoA，Bundle ID 为 `com.yado.yadoA`。
未安装 yadoA 的 Mac 会将第二步显示为未知动作；不要因此删除或替换该动作。
当前已核对线上模板的两个动作、Intent 标识和图片连接，真机完整执行仍需验证。

后续修改动作或参数时，应重新签名、导入并生成 iCloud 共享链接，再更新 App 中的 URL 和这里的两个模板文件。
不要直接编辑签名后的 `.shortcut` 文件，也不要把入口改回空白的 `shortcuts://create-shortcut`。

苹果参考：[分享快捷指令](https://support.apple.com/guide/shortcuts-mac/share-shortcuts-apdf01f8c054/mac)、[使用命令行签名](https://support.apple.com/en-gb/guide/shortcuts-mac/apd455c82f02/mac)。
