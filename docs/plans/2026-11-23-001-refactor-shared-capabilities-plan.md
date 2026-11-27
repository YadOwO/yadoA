---
title: "refactor: 芽豆系列公共能力盘点与共用方案"
type: refactor
date: 2026-11-23
status: 进行中
---

# refactor: 芽豆系列公共能力盘点与共用方案

## Summary

登录、签到、意见反馈这些能力不是记账独有的，以后每个芽豆产品都要用。现在的情况是：

- **服务端已经基本是公共的**：签到、点数、App 内购买在 yado_ai，意见反馈在 yado_hub，法律文档和产品目录在 yado_run，账号和资料在 Logto。这些服务都已经按产品代号区分。
- **客户端还是各写各的**：这些能力的 iOS 代码都在 yadoA 里，约 1.9 万行。yadoI 把 yadoA 的登录代码拷了一份，两份已经改得不一样了；yadoL 也拷了一份手绘图形。
- **跨产品的账号注销有漏洞**：所有芽豆 App 共用一个 Logto 账号，但注销由各 App 自己挨个调后端，只能删到这个 App 认识的那几个服务（见「二、1」）。

建议的做法：**一个公共能力 = 一个服务端（已有）+ 一个客户端 Swift 包（新建 `yado_kit`）+ 一份接入清单**。打个比方：服务端是公共食堂，现在每个 App 各自做了一套餐具去食堂打饭；要做的是统一发一套餐具（`yado_kit`），再在食堂门口贴一张"新来的怎么办卡"（接入清单）。

先修注销漏洞，再从意见反馈开始一块一块搬进 `yado_kit`，每搬一块，yadoA 的表现保持不变。

---

## 一、盘点

### 1.1 公共能力清单

| 能力 | 服务端 | yadoA 客户端代码（约行数） | 其他 App 现状 |
| --- | --- | --- | --- |
| 登录、令牌、资料编辑 | Logto（线上 yadoA、yadoI 同一租户，同一个账号） | `Features/Auth/*`、`Profile/ProfileEditView` | yadoI 有一份拷贝（`Core/Auth/`），约 60% 相同，已分叉；yadoI 独有"凭证是否属于当前环境"的 issuer 校验 |
| 账号与安全（邮箱、密码、关联 Apple、二次验证） | Logto Account API | `AccountSecurity`、`AccountCredentialChangeFlow`、`Profile/AccountSecurity*` | 没有 |
| 注销账号 | 各后端各一个删除接口，客户端挨个调 | `AccountDeletionAPI`、`AccountDeletionSheet` | yadoI_be 有接口，yadoI 没调 |
| 以上三项合计 | | 约 5,200 | |
| 意见反馈 | yado_hub `/v1/feedback/{product}/*` | `Features/Feedback/*`（1,450） | yadoI 没接（PROJECTS.md 已列为待办，hub 已认 yadoi） |
| 诊断信息（MetricKit，随反馈上传） | 随反馈存 yado_hub | `Features/Diagnostics/*`（220） | 没有 |
| 每日签到、补签卡、礼包 | yado_ai `/v1/billing/check-in*` | `Features/CheckIn/*` + 我的页徽章、飞入动画（3,700） | 没有 |
| AI 点数、明细、App 内购买 | yado_ai `/v1/billing/*`、`/v1/store/*` | `Features/AI/*` 中点数和购买部分（AI 文件夹共 4,600） | 没有 |
| 隐私政策同意、法律文档 | yado_run 静态页 `/legal/<app>/` | `Features/Legal/*`（400） | yadoI 没有；yadoL 只有静态说明页 |
| 应用锁（Face ID）、切后台遮挡 | 无 | `Features/AppLock/*`（630） | yadoL 有一份更简单的（70 行） |
| 新版本提醒、强制升级（426） | yadoA_be、yado_ai 的最低版本拦截；新版本查 iTunes | `AppVersion`、`AppUpdatePrompt`、`AppStoreUpdateNotice`（600） | 没有 |
| 更多芽豆产品 | yado_run `/api/series.json` | `Features/Series/*`（430） | yadoI 在引导页写死了一个列表 |
| 头像上传 | **没有服务端**，App 用打进 Debug 包的长期密钥自己签名 | `Profile/Avatar/*`（400） | 没有 |
| 线条头像 | 无 | `Profile/LineAvatar/*`（1,260） | 没有 |
| 通用小组件（Toast、对话气泡、App 内浏览器、触感、Tab 兼容） | 无 | `Components/`、`Support/` 中 7 个文件（550） | yadoI 拷了 Tab 兼容；yadoL 拷了手绘图形 |

### 1.2 先不当公共能力的

- **同步引擎**：yadoA（游标拉取 + 推送，2,800 行）和 yadoI（操作队列，880 行）是两套不同的设计，硬合并代价大。等 yadoI 同步第二期时再看要不要对齐。
- **设计系统**：yadoA 是纸张、账本、手绘风格，yadoI 有自己的主题系统。每个产品保留自己的外观；公共界面用系统语义色和各 App 的强调色（已检查，现有的公共界面基本只用了 `primary`、`secondary`、`accentColor`）。
- **记账、语音记账、AI 对话、引导页**：yadoA 独有。

---

## 二、现在的问题

### 1. 注销账号跨产品有漏洞（最重要）

所有芽豆 App 共用一个 Logto 账号，但注销是 App 自己挨个调：yadoA 依次调 yado_ai、yado_hub、yadoA_be，最后由 yadoA_be 删掉 Logto 用户。

- 在 yadoA 里注销：Logto 账号没了（yadoI 也登不上了），但 **yadoI_be 里的数据没人删**。
- 等 yadoI 接上注销：yadoI_be 删掉 Logto 用户，**yado_ai、yado_hub、yadoA_be 的数据没人删**。
- 每多一个产品，每个 App 都得知道所有服务，而且 Logto 一删就再也拿不到 token，漏掉的服务没机会补删。
- 删 Logto 用户的代码在 yadoA_be、yadoI_be 各有一份（`shared/logto-management.ts`），两边都要配 `LOGTO_M2M_*`。
- yado_hub 只有 24 小时的注销记录，没有永久注销名单，鉴权也不查注销名单。

App Store 要求注销账号时删除用户数据，这件事要在 yadoI 带登录正式上线之前解决。

### 2. 客户端代码靠复制，已经分叉

yadoI 的 `AuthStore`、`LogtoAccountAPI`、`AuthSocialProvider`、环境配置都是从 yadoA 拷的，之后两边各改各的：yadoA 加了二次验证、隐私同意前禁止联网、注销中禁止退出；yadoI 加了 issuer 校验。修一个登录 bug 要记得改两处，以后产品多了就是 N 处。

### 3. 产品代号写死、接入一个新产品要改十几处

- yadoA 客户端里 `"yadoa"` 写死在 4 处：`FeedbackAPI.product`、`AIBillingAPI.product`、`SeriesCatalog.currentProductCode`、`LegalDocument` 的路径。
- 服务端要登记新产品的地方有 12 处，分散在 yado_ai（6 处）、yado_hub、yado_console、yado_run、Logto、部署配置里，PROJECTS.md 只列了其中两处（yado_console 的 `PRODUCTS` 没列）。

### 4. 头像上传没有服务端

App 用打进 Debug 包的长期 AccessKey 自己签 OSS 请求，所以 Release 包把更换头像藏起来了。头像存在 Logto 资料里、全系列共用，上传凭证应该由公共服务发。

### 5. yado_ai 的最低版本只认 yadoA

`src/middleware/min-app-version.ts` 用 `MIN_APP_VERSION_YADOA` 判断所有带 `X-App-Version` 的请求。别的 App 一开始带这个头，就会被 yadoA 的最低版本误拦。

### 6. 签到和 AI 计费绑死

yado_ai 的类型要求每个产品必须同时配好开通赠送、签到规则和商品目录。想要签到但暂时不卖点数的产品接不进来。签到奖励就是 AI 点数，这本身没问题，只是配置项要允许缺省。

### 7. 后端基础代码复制了 4 份

鉴权中间件、环境变量校验、错误处理、OpenAPI、数据库连接、最低版本拦截、限流、Dockerfile、CI、部署脚本，四个后端基本是同一份拷贝，已经有小分叉（比如 yado_hub 的鉴权不查注销名单；健康检查有的数据库挂了返回 503，有的返回 200）。

---

## 三、方案

### 3.1 服务端

**A. 注销改由 yado_hub 统一编排**

- App 只调一个接口：yado_hub 的 `DELETE /v1/account`。
- yado_hub 依次执行：写入永久注销名单 → 调每个服务的内部删除接口（机器令牌鉴权，yado_hub 已有 agents 用的机器令牌中间件可以参照）→ 全部成功后最后删 Logto 用户。
- 任何一步失败就停下、返回错误，App 重试；各删除接口本来就可以重复调用。
- 要调哪些服务写在 yado_hub 的配置里，新产品后端接入时加一行。
- yadoA_be、yadoI_be 去掉删 Logto 用户的代码和 `LOGTO_M2M_*`，只留"删本服务数据"的内部接口，照旧写自己的注销名单。
- 兼容：yadoA 如果在这之前上线，老版本还会调原来三个接口，要保留到最低版本把老版本拦掉为止。赶在 yadoA 上线前做完最省事。

**B. 头像上传凭证由 yado_hub 发**

- 新接口返回一个短时有效的 OSS 预签名上传地址和上传后的公开地址；路径由服务端决定（`{product}/{sub}/{uuid}.jpg`）。
- 用预签名地址而不是 STS：服务端签一下就行，App 不用再带 `OSSRequestSigner` 和密钥。
- 做完后 Release 包可以放开更换头像。

**C. yado_ai 按产品区分**

- 最低版本改成按产品取值（App 带上产品代号，或按路由判断）。
- 签到、开通赠送、商品目录允许某个产品不配。
- 第二个产品要用 AI 点数时再做，不用现在做。

**D. 新产品接入清单**

把上面盘出来的 12 处登记点写进 `~/yado-code/PROJECTS.md`，作为一节"新产品接入清单"。暂时不做"一处配置自动生成"，产品少的时候清单就够用。

### 3.2 iOS：新建 `yado_kit` Swift 包

**仓库**：`~/yado-code/yado_kit`，一个 Swift Package，里面分几个可以单独引用的模块，App 用到哪个引哪个。yadoL 不登录，也可以只引应用锁和小组件。

| 模块 | 内容 | 从 yadoA 搬哪些 | 依赖 |
| --- | --- | --- | --- |
| `YadoCore` | 环境（dev / 线上）、产品配置、公共服务地址、带 token 的请求、`X-App-Version` 和 426 处理、文案取值、"取 token"协议 | `AppEnvironment`、`AuthConfig` 的公共部分、各 API 里重复的请求代码、`AccountLocalization` | 无 |
| `YadoUI` | Toast、对话气泡和文字选中、App 内浏览器、App Store 链接、触感、Tab 兼容、手绘图形 | `Components/` 和 `Support/` 里对应文件 | 无 |
| `YadoAccount` | 登录、令牌、登录页、资料编辑（昵称、头像）、账号与安全、注销 | `Features/Auth/*`、`Profile/` 里账号相关、`Avatar/*`、`LineAvatar/*`；合入 yadoI 的 issuer 校验 | Core、UI、Logto SDK |
| `YadoFeedback` | 意见反馈对话、诊断信息 | `Features/Feedback/*`、`Features/Diagnostics/*` | Core、UI |
| `YadoLegal` | 隐私政策同意、法律文档地址 | `Features/Legal/*` | Core |
| `YadoAppLock` | Face ID 应用锁、切后台遮挡 | `Features/AppLock/*` | UI |
| `YadoAppUpdate` | 新版本提醒、强制升级 | `AppVersion`、`AppUpdatePrompt`、`AppStoreUpdateNotice` | Core |
| `YadoSeries` | 更多芽豆产品 | `Features/Series/*` | Core |
| `YadoPoints` | AI 点数、明细、App 内购买、签到 | `Features/AI/*` 中点数和购买部分、`Features/CheckIn/*` | Core、UI |

关键设计：

- **产品配置启动时注入一次**。App 启动时告诉 `yado_kit` 自己是谁：产品代号、当前环境、Logto App ID、回调地址、自家后端的 resource。这样就去掉了写死的 4 处 `"yadoa"`。
  - Swift 包看不到 App 的编译标志（`ENV_DEV` / `ENV_PROD`），所以环境仍由 App 自己的 `#if ENV_DEV` 判断后传进来。`#error` 兜底留在 App 里。
  - 公共服务（Logto、yado_ai、yado_hub、yado_run）每套环境的地址各产品都一样，放在 `yado_kit` 里。
  - yadoA 独有的开关（重看引导、截图记账、语音耗时）留在 yadoA 自己的配置里。
- **模块之间靠协议解耦**。`YadoCore` 定义"取某个服务的 token"协议，反馈、点数只依赖这个协议，不依赖 `YadoAccount`。所以意见反馈可以先于登录搬家，App 现有的 `AuthStore` 实现这个协议就行。
- **外观跟着 App 走**。公共界面只用系统语义色和 App 的强调色，浅色、深色都适配。品牌插画（登录页的嫩芽、签到礼包的手绘图）由 App 传入，不传时用中性的默认样式。
- **文案**。`yado_kit` 有自己的 `Localizable.xcstrings`，沿用 yadoA 的写法：英文语义键、英文为源语言、带简体中文。对应的约 300 个键（`auth.*`、`feedback.*`、`checkIn.*`、`privacy.*`、`app_lock.*`、`appUpdate.*`、`series.*`、`account.security/email/password/delete/apple/reauth.*` 等）从 yadoA 搬过去，取值时指定 `Bundle.module`，保留 App 内切换语言的做法。和具体产品有关的文案（比如"登录后才能用语音记账"）由 App 传入。
- **编译设置和 App 对齐**。最低 iOS 18；Swift 语言模式、默认 MainActor 隔离设成和 yadoA、yadoI 一样，代码搬过去不用逐个补 `@MainActor`。要给 App 用的类型和方法加 `public`，这是搬家时主要的机械工作量。
- **测试跟着搬**。对应的单元测试移到 `yado_kit` 的测试 target，App 里只留集成相关的测试。

**App 怎么引用 `yado_kit`（推荐：版本号）**

- App 按 git 地址加版本号引用（Xcode 里选 "Up to Next Minor"），像引用 Logto SDK 一样。
- 平时开发：把本地的 `~/yado-code/yado_kit` 拖进 Xcode 工程，Xcode 会用本地这份盖掉远程版本，改了立刻生效。
- 发版前：给 `yado_kit` 打版本号，App 把引用升到这个版本再出包。
- 好处：yadoA 和 yadoI 各自决定什么时候升级，`yado_kit` 的改动不会悄悄进到正在出包的另一个 App；出包用的代码可以复现。
- 没选"直接引用本地路径"（yadoR 的做法）：省掉打版本号这一步，但出包时用的是旁边文件夹当时的状态，没提交的改动也可能带进包里，两个 App 也只能同步升级。
- 代价：发布流程要多一步"给 `yado_kit` 打版本号"，yado-release 和一次实现要认识这个仓库。

### 3.3 后端基础代码：`yado_server_kit`（不急）

- 一个 npm 包，放共用的：鉴权中间件（注销名单检查由各服务传入）、环境变量基础校验、错误处理、OpenAPI 工厂、数据库连接、最低版本拦截、限流（用 yado_hub 的工厂写法）。
- 部署：Dockerfile、CI、部署脚本做成可复用的 GitHub Actions workflow 加参数化脚本。
- 私有包要让 CI 和 Docker 构建能拉到（GitHub Packages 或 git 依赖都要配令牌），所以排在最后。这些文件很少改，等哪次要改再顺手抽出来。
- 注销改由 yado_hub 编排之后，`logto-management.ts` 只剩一份，这处重复自然消失。

---

## 四、分步计划

每一步做完，yadoA 的表现都不变（只是代码换了地方）；能单独上线、单独回退。

| 步 | 做什么 | 涉及仓库 | 什么时候做 |
| --- | --- | --- | --- |
| 0 | 新产品接入清单写进 PROJECTS.md；本方案定稿 | — | 现在 |
| 1 | 注销改由 yado_hub 编排；yadoA 改为只调 yado_hub；产品后端改为内部删除接口 | yado_hub、yadoA_be、yadoI_be、yado_ai、yadoA | 最好在 yadoA 上线前；最晚在 yadoI 带登录上线前 |
| 2 | 建 `yado_kit`：`YadoCore`、`YadoUI`、`YadoFeedback`；yadoA 改用；yadoI 接入意见反馈 | yado_kit、yadoA、yadoI | 第 1 步之后 |
| 3 | `YadoAccount`：合并两份 `AuthStore`（带上 yadoI 的 issuer 校验）；yadoA、yadoI 都改用；yadoI 顺带拿到账号与安全、注销 | yado_kit、yadoA、yadoI | 登录是关键路径，不要卡在 yadoA 首发前一刻做 |
| 4 | `YadoLegal`、`YadoAppUpdate`（同时做 yado_ai 按产品的最低版本）、`YadoAppLock`（yadoL 可用）、`YadoSeries`（yadoI 换掉写死列表） | yado_kit、yado_ai、各 App | 第 3 步之后，可以拆开做 |
| 5 | yado_hub 发头像上传地址；去掉 App 里的签名器和密钥；Release 放开更换头像 | yado_hub、yado_kit | 头像功能要对线上开放之前 |
| 6 | `YadoPoints`（点数、购买、签到）；yado_ai 配置允许缺省 | yado_kit、yado_ai | 第二个产品要用 AI 点数时 |
| 7 | `yado_server_kit` 和部署模板 | 四个后端 | 顺手做 |

---

## 五、已定的事（2026-11-23）

1. **`yado_kit` 的引用方式**：git 地址加版本号。GitHub 仓库建好之前，App 先用本地包引用 `../yado_kit` 过渡。
2. **注销编排赶在 yadoA 上线前做**：yadoA 还没发布，旧接口直接换掉，不留兼容。
3. **仓库名**：`yado_kit`；`yado_server_kit` 到第 7 步再定。
4. **第 1 步和第 2 步并行**：注销改造（分支 `feat/account-deletion-hub`）和 `yado_kit` + 意见反馈（分支 `feat/yado-kit-feedback`）同时做，各自在独立的 git worktree 里改；yadoA 里两边改的文件不重叠。第 0 步的接入清单已写进 PROJECTS.md。

### 调整（2026-11-23 晚）

- **公共能力以后端服务为主**。各产品页面样式本来就不一样，客户端的公共包意义不大：`yado_kit` 和意见反馈搬家（第 2 步）**不合并**，代码留在本机 `~/yado-code/yado_kit` 和 yadoA、yadoI 的 `feat/yado-kit-feedback` 工作副本里备查。调接口的代码各 App 自己写。
- **第 1 步已完成**：注销改由 yado_hub 编排，合进 yado_hub、yado_ai、yadoA_be、yadoI_be、yadoA 的 dev。实测重度用户（5 万条同步记录）注销 0.94 秒；下游挂掉 1.5 秒返回 502，下游卡住 10.75 秒返回 502，恢复后重试成功。dev、线上的配置步骤见各仓库 `deploy/pending.md`。
- **下一步**：头像上传（第 5 步，提前做）和最低 App 版本（第 4 步里 yado_ai 按产品区分的部分，改为每个产品在 yado_hub 配一处，各服务去 hub 取）。
- **不做**：云同步，各产品的同步策略不一样。

---

## 附：顺带发现的小问题

- yadoI_be 的 `.env.example` 里 `LOGTO_AUDIENCE=https://api.yado.com/yadoi`，App 用的是 `https://api.yado1225.top/yadoi`。
- yadoI_be 的迁移记录表在默认的 `drizzle` schema，其他服务都在自己的 schema 里。
- yadoI_be 仓库里没有服务器 compose 片段、nginx、postgres 初始化脚本，其他三个后端都有。
- PROJECTS.md 的产品代号登记点漏了 yado_console `src/lib/config.ts` 的 `PRODUCTS`。
- yado_ai 没有测试文件。
