# App Store 隐私标签与数据清单

芽豆资产上传到我们服务器或第三方的全部数据，以及它们在 App Store Connect「App 隐私」问卷里怎么填。

三处要保持一致，任何一处变了，另外两处一起改：

| 位置 | 内容 |
| --- | --- |
| `yadoA/PrivacyInfo.xcprivacy` | 隐私清单：收集的数据类型、required-reason API |
| App Store Connect › App 隐私 | 隐私标签，按本文第二节填写 |
| yado_run `src/content/legal/yadoa/` | 隐私政策、第三方信息共享清单（`https://my.yado1225.top/zh/legal/yadoa/privacy/`） |

**什么时候要改：** 新增一种上传到服务器的数据、新接一个 AI 服务商或 SDK、用到新的 required-reason API（文件时间戳、开机时间、磁盘空间、键盘列表、UserDefaults）。

整理日期：2026-11-09，依据当时 `dev` 上的代码（含 App 内注销、意见反馈附带诊断）。

## 一、数据从哪来、到哪去

基本记账不登录也能用，数据只在本机 SwiftData 里，不上传。下面这些都需要登录，而且大多由用户主动触发。

| 功能 | 上传的数据 | 去向 | 何时发生 | 代码位置 |
| --- | --- | --- | --- | --- |
| 登录 | Logto 账号 ID（`sub`）、昵称、头像地址；Apple 登录时 Apple 提供的姓名和邮箱（可能是中转邮箱） | 自建 Logto（`accounts.yado1225.top`，阿里云广州） | 用户点登录 | `Features/Auth/` |
| 修改资料 | 昵称；头像图片（目前只有 Debug 构建能上传，Release 隐藏入口） | Logto；阿里云 OSS `yado-avatars` | 用户主动修改 | `Features/Profile/ProfileEditView.swift`、`Features/Profile/Avatar/` |
| 云同步 | 账户（名称、备注、卡号后四位、期初余额、币种）、流水（金额、分类、备注、日期、对方账户）、分类、默认账户、周期规则；App 随机生成的设备 ID | yadoA_be（`yadoa-api.yado1225.top`），**明文 JSON，无端到端加密** | 默认关闭，用户开启后自动同步 | `Features/Sync/`、`Persistence/Sync/` |
| AI 记账 | 说的话转成的文字或打的字、图片、账户列表（名称、类型、余额、是否停用）、分类列表、对话上下文（含查到的流水和周期规则）、当前时间和时区、App 语言 | yado_ai（`ai-api.yado1225.top`），再转发给 AI 服务商（见共享清单）；不转发账号 ID | 用户每次发起 | `Features/Voice/API/VoiceSessionContract.swift` |
| AI 点数、签到 | 点数获得和消耗记录（时间、功能、模型档位、点数）、签到日期、每次请求的不可还原输入指纹 | yado_ai | 使用 AI、点签到时 | `Features/AI/AIBillingAPI.swift` |
| 意见反馈 | 反馈文字；App 版本、系统版本、设备型号、App 语言；**用户打开开关时**附带最近最多 5 份 MetricKit 崩溃、卡顿、磁盘写入报告 | yado_hub（`hub-api.yado1225.top`） | 用户发送反馈 | `Features/Feedback/`、`Features/Diagnostics/` |
| 服务器日志 | IP 地址、时间、接口、结果、耗时；部分服务记账号 ID 和设备 ID | 各后端 | 每次请求 | 各后端 |

**不上传的：** 语音音频（只在本机转文字；不支持离线识别的设备由 iOS 直接发给 Apple，我们收不到）、AI 对话记录（本机保存 90 天）、搜索记录、导出的备份文件、提醒设置。

**没有：** 第三方统计、崩溃收集、广告、推送 SDK；IDFA；跨 App 追踪。

## 二、App Store Connect 怎么填

第一个问题「你或你的第三方合作伙伴是否从此 App 收集数据？」选 **是，我们从此 App 收集数据**。

每种数据类型都按同样的三问回答：

- **用途：** 只勾「App 功能」；
- **是否与用户身份关联：** 是（所有请求都带登录凭证，能对应到账号）；
- **是否用于追踪：** 否。

要勾选的数据类型：

| App Store Connect 分类 | 数据类型 | 对应的数据 |
| --- | --- | --- |
| 联系信息 | 姓名 | 昵称、Apple 登录提供的姓名 |
| 联系信息 | 电子邮件地址 | Apple 登录提供的邮箱（存在 Logto） |
| 财务信息 | 其他财务信息 | 同步的账本；AI 记账时发送的账户余额和流水 |
| 用户内容 | 照片或视频 | 发给 AI 的图片；头像 |
| 用户内容 | 客户支持 | 意见反馈 |
| 用户内容 | 其他用户内容 | 发给 AI 的文字 |
| 标识符 | 用户 ID | Logto 账号 ID |
| 标识符 | 设备 ID | 云同步的设备 ID |
| 使用数据 | 产品交互 | AI 点数记录、签到 |
| 诊断 | 崩溃数据 | 反馈附带的崩溃报告 |
| 诊断 | 性能数据 | 反馈附带的卡顿、磁盘写入报告 |
| 诊断 | 其他诊断数据 | 反馈里的 App 版本、系统版本、设备型号 |

**不勾的及原因：**

| 数据类型 | 原因 |
| --- | --- |
| 付款信息、信用信息 | 没有内购；卡号后四位是用户记在账本里的内容，算在「其他财务信息」 |
| 位置（精确、粗略） | 不读定位；服务器日志里的 IP 只用于安全和排障，不用来推算位置 |
| 音频数据 | 语音只在本机或由 iOS 交给 Apple 转文字，我们只收到文字 |
| 搜索历史 | 记账搜索记录只存在本机 |
| 通讯录、健康与健身、浏览历史、敏感信息、其他数据 | 不收集 |
| 购买项目、广告数据、其他使用数据 | 没有内购和广告，不做统计 |

**隐私政策网址**（App 信息页，按语言分别填）：

- 简体中文：`https://my.yado1225.top/zh/legal/yadoa/privacy/`
- 英文：`https://my.yado1225.top/legal/yadoa/privacy/`

**许可协议（EULA）：** 保留 Apple 标准 EULA 即可，不用自定义。我们的用户协议在 App 内（登录页、设置 › 关于）和网站上提供，里面已包含 Apple 要求的最低条款。

**用户隐私选择网址（可选）：** 不填。

## 三、隐私清单（PrivacyInfo.xcprivacy）

| 项目 | 取值 | 依据 |
| --- | --- | --- |
| `NSPrivacyTracking` | false | 不追踪 |
| `NSPrivacyTrackingDomains` | 空 | 不追踪 |
| `NSPrivacyCollectedDataTypes` | 第二节表里的 12 项，全部关联用户、不追踪、用途 App 功能 | — |
| UserDefaults | `CA92.1`：只读写本 App 自己的偏好 | 各处 `@AppStorage` / `UserDefaults.standard`，没有 App Group |
| 文件时间戳 | `C617.1`：读取 App 容器内文件的时间 | `Features/Diagnostics/DiagnosticStore.swift` 读诊断文件的修改时间来排序、清理 |

没有用到开机时间、磁盘空间、键盘列表这几类 API。第三方 SPM 包（Logto Swift SDK、JOSESwift、KeychainAccess）都不在 Apple 要求自带清单的常用 SDK 名单里。

**验证：** Xcode › Product › Archive，在 Organizer 里右键归档 › Generate Privacy Report，报告里应列出上面的数据类型和两类 API，没有缺项。

## 四、上架前还要对上的事

这些是隐私政策已经承诺、但要在上架前确认的：

- yado_ai 的模型从魔搭切到阿里云百炼，与共享清单一致；
- 首次使用 AI 记账前单独征得同意（共享清单里写了「首次使用前会单独征得你的同意」）；
- Release 版隐藏「帮助改进 AI」入口，Langfuse 上线前政策里没有这一项；
- 中国区首次启动的隐私政策同意弹窗；
- Logto 托管登录页填上用户协议和隐私政策链接。
