---
date: 2026-10-18
topic: auth-profile
---

# 登录与用户资料 TODO

2026-10-18 对 yadoA 登录（Logto）与“我的”页资料功能做了一轮梳理，下面是待完善事项。
已完成：用户名改为只读（编辑弹层只展示、可长按复制，不再走密码验证改名）。

---

## 上架前必须完成

- [x] **App 内注销账号**（2026-11-09 已完成）
  - 实现：yadoA_be `DELETE /v1/me` 用 Logto Management API 删除用户并清云端同步数据，yado_ai `DELETE /v1/account` 清空点数账本；App 在 yado_ai 之后、yadoA_be 之前调 yado_hub 的 `DELETE /v1/account`，删除意见反馈对话、消息和诊断，反馈单只留不含用户和内容的匿名统计；App 设置页两步确认后依次调用，再按选择保留或清除本机账本并退出登录。
  - 2026-11-09：芽豆系列所有 App 共用一个芽豆账号，注销删的是整个 Logto 用户。入口和弹窗改叫「注销芽豆账号」，第一步警告先讲明会影响全部芽豆 App、各 App 的云端数据都会删除。
  - 2026-11-11：yado_hub 注销清理已接入。App 注销时依次调 yado_ai、yado_hub、yadoA_be；hub 在事务里删掉该用户所有产品下的反馈会话、消息（含设备信息和诊断），反馈单只留匿名统计。
  - 待办（其他仓库）：文案已承诺删除所有芽豆 App 的云端数据，但 yadoI_be（`yadoi` 物品、分类）目前还不会随注销清理。芽豆有物上线前必须补上，计划由各后端订阅 Logto 的用户删除事件，或由一处统一调用各服务清理。
  - App 支持注册，App Store 审核条款 5.1.1(v) 要求 App 内可发起删除账号。
  - Logto Account API 未见用户自助删除接口（未核实），大概率需要后端用 Management API 删除；删除前二次确认，并说明本地账本数据不受影响。
- [ ] **头像上传改为服务端签发 STS**
  - 目前 OSS 长期密钥只注入 Debug 构建，Release 包无法更换头像。
  - 方案已记录在 `AvatarUploadCredentials.swift` 的 TODO 中；可与注销账号、用户名修改合用同一个小后端。
- [x] **登录页补《隐私政策》《用户协议》链接**（2026-11-09）
  - 登录页底部加「登录即表示你已阅读并同意《用户协议》和《隐私政策》」，设置 › 关于加用户协议、隐私政策、第三方信息共享清单三行；都在 App 内用 Safari 视图打开 yado_run 网站上对应语言的页面（`LegalDocument`）。
  - 未做：Logto 托管登录页自身的协议勾选，需要在 Logto 控制台「登录体验」里填协议链接。

## 功能缺陷

- [x] **会话失效后界面仍显示已登录**（2026-10-20 随语音记账完成）
  - `refreshProfile` 与 `accessTokenForAIService` 遇到 `invalid_grant` / `invalid_target` 或缺少 refresh token 时清除本地凭证，界面回到未登录。
  - `updateProfile` 仍只报“不允许修改”，未接入同样的清理。
- [ ] **回到前台不刷新资料**
  - 目前只在“我的”页 `.task(id: isAuthenticated)` 时刷新；监听 `scenePhase` 变为 `.active` 时也调用 `refreshProfile()`。
- [ ] **社交登录用户的身份验证**
  - Apple 登录接通后（`AuthSocialProvider.apple.isConnected`），这类用户通常没有密码，甚至没有用户名。
  - 后续凡是需要验证身份的敏感操作（改用户名、绑定邮箱、注销），都要支持邮箱 / 短信验证码（Logto verification-code 接口），不能只靠密码。
  - 用户名为空时，编辑弹层目前显示“未设置”，需确认是否引导用户补充。
  - 2026-11-19：绑定邮箱已覆盖只有 Apple 的用户：Logto 不认 Apple 验证记录，App 带 `acr_values=urn:logto:acr:1fa` 重新打开托管页（step-up），由托管页让用户重新登录并设置邮箱或密码。

## 账号安全与找回

- [ ] **绑定邮箱**：只有用户名和密码的账号忘记密码后无法找回；用 Account API 支持绑定 / 更换邮箱（需验证码）。
  - 2026-11-19 App 端已完成，dev 开放、线上关闭（`AuthConfig.isEmailAccountAvailable`）：
    - 设置 › 账号分组第一行新增「账号与安全」：用户名（只读）、Apple 是否关联、邮箱（打码显示，可绑定 / 更换）、是否设置密码；「注销芽豆账号」从设置页搬到这一页底部，流程不变。
    - 绑定 / 更换邮箱：先验证身份（有密码输密码 → 否则给当前邮箱发 `UserPermissionValidation` 验证码 → 只有 Apple 时走 OIDC step-up），再给新邮箱发码、校验，`POST /api/my-account/primary-email` 保存。身份验证记录只存内存，10 分钟过期后重新验证。
    - 登录页在 Apple 和「账号密码」之间加「邮箱登录」，直接进入托管页的邮箱输入页。
    - 登录额外申请 `email`、`identities` scope；之前登录的会话在「账号与安全」页提示重新登录一次。step-up 或重新登录时在托管页登了别的账号，直接退出登录（本机账本和同步绑定保留，不会同步到新账号）。
  - 待办：dev 按下面的「Logto 后台配置清单」配好后真机走一遍；线上要先升级 Logto（线上 OIDC discovery 没有 `acr_values_supported`，不支持 step-up）、配好清单，再把 `AuthConfig.prod.isEmailAccountAvailable` 改为 true。
- [ ] **修改密码入口**：Account API 支持，成本较低。

## Logto 后台配置清单

邮箱登录和绑定邮箱依赖下面这些配置。dev 先配；线上要先升级 Logto（支持 `acr_values` step-up），再按同样的清单配，最后打开 `AuthConfig.prod.isEmailAccountAvailable`。

- [ ] **邮件连接器**：配一个邮件连接器（阿里云邮件推送或 SMTP），模板覆盖 SignIn / Register / ForgotPassword / BindNewIdentifier / UserPermissionValidation。没配时发验证码返回 501，App 提示「邮件服务暂未开通」。
- [ ] **登录体验**：开启邮箱 + 验证码登录（登录页「邮箱登录」按钮、只有 Apple 的用户 step-up 后设置邮箱都靠它）。
- [ ] **账户中心字段**：email = Edit，social = ReadOnly，password = ReadOnly，username = ReadOnly，name / avatar 保持 Edit。

## 用户名修改（远期）

- 当前：App 内只读。**需在 Logto Console → Sign-in & account → Account center 把 `username` 字段设为 `ReadOnly`**，防止绕过 App 直接调用 Account API 改名。
- Logto 本身不支持“修改冷却期”，只有 Off / ReadOnly / Edit 三档；webhook 只能事后通知，无法拦截。
- 若以后开放改名，走后端：Logto token 鉴权 → 校验冷却期（如 30 天一次）→ Management API 修改；上次修改时间存在用户不可写的位置（不要用对用户开放编辑的 `customData`）。
- 可考虑旧用户名保留一段时间不被他人注册，防止冒用。
- `LogtoAccountAPI` 中的 `username` 参数目前未被调用，保留备用；确定走后端方案后可删除。`verifyPassword` 已用于绑定邮箱前验证身份。

## 体验与细节

- [ ] “我的”页页头在昵称下方显示 `@username`，用户名只读后这是用户唯一能看到登录名的地方。
- [ ] 头像加缓存：`ProfileAvatarView` 使用 `AsyncImage`，没有持久缓存，每次进入页面都重新加载并闪一下占位图。
- [ ] OSS 旧头像清理：换头像后旧文件不会删除；上传成功但写回 Logto 失败时也会留下无引用文件。可由后端定期清理，或设置 OSS 生命周期规则。
- [ ] Logto Console 中用户头像不显示（见 `LogtoAccountAPI.swift` 的 TODO）：优先排查 OSS 防盗链（Referer 白名单）。
- [ ] 登录页加载失败时被归为“用户取消”而不提示（`AuthStore.isUserCancellation` 已记录的局限），可考虑在登录前检查网络可达性。
