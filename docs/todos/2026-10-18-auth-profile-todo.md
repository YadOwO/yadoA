---
date: 2026-10-18
topic: auth-profile
---

# 登录与用户资料 TODO

2026-10-18 对 yadoA 登录（Logto）与“我的”页资料功能做了一轮梳理，下面是待完善事项。
已完成：用户名改为只读（编辑弹层只展示、可长按复制，不再走密码验证改名）。

---

## 上架前必须完成

- [ ] **App 内注销账号**
  - App 支持注册，App Store 审核条款 5.1.1(v) 要求 App 内可发起删除账号。
  - Logto Account API 未见用户自助删除接口（未核实），大概率需要后端用 Management API 删除；删除前二次确认，并说明本地账本数据不受影响。
- [ ] **头像上传改为服务端签发 STS**
  - 目前 OSS 长期密钥只注入 Debug 构建，Release 包无法更换头像。
  - 方案已记录在 `AvatarUploadCredentials.swift` 的 TODO 中；可与注销账号、用户名修改合用同一个小后端。
- [ ] **登录页补《隐私政策》《用户协议》链接**
  - `SignInView` 目前没有，上架和合规都需要；文案需中英文本地化。

## 功能缺陷

- [ ] **会话失效后界面仍显示已登录**
  - `AuthStore.isAuthenticated` 只看本地是否有凭证；refresh token 被撤销、用户被删除时，`refreshProfile` 静默失败，直到保存资料才报“不允许修改”。
  - 处理：在刷新资料、获取 access token 时识别 `invalid_grant` 一类错误，清除本地凭证并提示重新登录。
- [ ] **回到前台不刷新资料**
  - 目前只在“我的”页 `.task(id: isAuthenticated)` 时刷新；监听 `scenePhase` 变为 `.active` 时也调用 `refreshProfile()`。
- [ ] **社交登录用户的身份验证**
  - Apple 登录接通后（`AuthSocialProvider.apple.isConnected`），这类用户通常没有密码，甚至没有用户名。
  - 后续凡是需要验证身份的敏感操作（改用户名、绑定邮箱、注销），都要支持邮箱 / 短信验证码（Logto verification-code 接口），不能只靠密码。
  - 用户名为空时，编辑弹层目前显示“未设置”，需确认是否引导用户补充。

## 账号安全与找回

- [ ] **绑定邮箱**：只有用户名和密码的账号忘记密码后无法找回；用 Account API 支持绑定 / 更换邮箱（需验证码）。
- [ ] **修改密码入口**：Account API 支持，成本较低。

## 用户名修改（远期）

- 当前：App 内只读。**需在 Logto Console → Sign-in & account → Account center 把 `username` 字段设为 `ReadOnly`**，防止绕过 App 直接调用 Account API 改名。
- Logto 本身不支持“修改冷却期”，只有 Off / ReadOnly / Edit 三档；webhook 只能事后通知，无法拦截。
- 若以后开放改名，走后端：Logto token 鉴权 → 校验冷却期（如 30 天一次）→ Management API 修改；上次修改时间存在用户不可写的位置（不要用对用户开放编辑的 `customData`）。
- 可考虑旧用户名保留一段时间不被他人注册，防止冒用。
- `LogtoAccountAPI` 中的 `verifyPassword` 与 `username` 参数目前未被调用，保留备用；确定走后端方案后可删除。

## 体验与细节

- [ ] “我的”页页头在昵称下方显示 `@username`，用户名只读后这是用户唯一能看到登录名的地方。
- [ ] 头像加缓存：`ProfileAvatarView` 使用 `AsyncImage`，没有持久缓存，每次进入页面都重新加载并闪一下占位图。
- [ ] OSS 旧头像清理：换头像后旧文件不会删除；上传成功但写回 Logto 失败时也会留下无引用文件。可由后端定期清理，或设置 OSS 生命周期规则。
- [ ] Logto Console 中用户头像不显示（见 `LogtoAccountAPI.swift` 的 TODO）：优先排查 OSS 防盗链（Referer 白名单）。
- [ ] 登录页加载失败时被归为“用户取消”而不提示（`AuthStore.isUserCancellation` 已记录的局限），可考虑在登录前检查网络可达性。
