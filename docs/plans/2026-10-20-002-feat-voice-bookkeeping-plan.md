---
title: "feat: Add voice bookkeeping"
type: feat
date: 2026-10-20
origin: docs/brainstorms/2026-10-20-voice-bookkeeping-requirements.md
---

# feat: Add voice bookkeeping

## Summary

记账页底部悬浮按钮改为麦克风，长按说一句、松手发送；「＋」手动记账移到导航栏右上角。语音在 App 端转成文字，发给 yado_ai 的 `POST /v1/yadoa/voice-session/turn`。服务端按会话规则决定本步要执行的工具（新增、修改、删除、查询、汇总）、追问或回复；工具全部由 App 在本地执行，写入走与手动记账相同的仓库校验和余额逻辑。每一轮可整体撤销。会话规则见 [语音记账会话规则](../rules/voice-bookkeeping-session-rules.md)。

---

## Key Technical Decisions

- **KTD1. 服务端无状态，App 保存会话事件。** App 维护本次会话的 `events`（user / assistant / tool_call / tool_result），每一步完整发送。工具调用原样回传：契约模型手写 Codable，必填的可空字段（如 `note`）显式编码为 `null`，修改的 `patch.note` 区分「不改」与「清空」。
- **KTD2. 一句话尽量一次请求。** 服务端在 `tool_calls` 响应中返回 `canFinishLocally`：本步只有新增、修改、删除，模型通过工具参数 `finishesTurn` 声明这句话要做的事已全部发出，且没有被搁置的追问或被丢弃的调用；模型漏填按未完成处理，最多多请求一次。为 true 且全部执行成功时，App 在本地生成「已记 2 笔：午饭 ¥28、打车 ¥35」，追加为 assistant 事件后结束本轮，不再请求。
- **KTD3. 回复语言跟随 App。** 请求带 `locale`（`zh-Hans` / `en`），模型回复、追问和服务端固定提示都按它输出；本地生成的结果提示走 String Catalog。
- **KTD4. 上下文映射。**
  - 分类：id 用 key（预置 rawValue 或 `custom.<uuid>`），名称用当前语言的显示名，已删除的不发送。
  - 账户：全部发送（最多 50 个，启用在前），`isActive` 取 `supportsBookkeeping` 且币种为 CNY；停用账户用于识别查询结果里的历史流水。
  - 默认账户：`BookkeepingPreference.resolvedAccountID`。
  - `now` 用设备时区的 ISO 8601（带偏移）。
- **KTD5. 写入复用仓库，新增「一次保存的批量变更」。** `LocalExpenseRepository.apply(_:)` 接收 `BookkeepingEntryMutation`（insert / replace / delete）数组，在同一个 manual-save context 内逐条校验账户、分类、余额，最后保存一次，失败整体回滚。`update(_:)` 与 `apply` 共用同一套替换逻辑。语音的每个工具调用各自 `apply` 一次（结果逐条回传）；撤销一轮时把这一轮的反向变更放进同一次 `apply`，保证不会只撤销一半。
- **KTD6. 撤销。** 每次成功的变更记录反向操作：新增 → 删除；修改 → 用修改前的完整快照替换；删除 → 按原 UUID、`savedAt`、标题和备注插回。撤销后把这一轮的事件从 `events` 中移除，模型不会再引用已不存在的 id；界面上该轮保留并标为已撤销。只能从最近一轮往前依次撤销。
- **KTD7. 失败处理。**
  - 本轮还没有写入数据时请求失败：移除本轮的 user 事件，提示原因，可重试或带转写文字去手动记账。
  - 已写入后的后续请求失败：保留写入，在本地生成结果提示追加为 assistant 事件，用户可撤销。
- **KTD8. 语音识别在端上。** iOS 26+ 优先 `SpeechAnalyzer` + `SpeechTranscriber`，首次使用通过 `AssetInventory` 下载模型并显示「准备中」；语言不支持或 iOS 18 时用 `SFSpeechRecognizer`（设备支持时强制端上识别）。账户名、分类名作为 contextual strings 提高专名识别率。音频处理放在 `nonisolated` 类型中，避免默认 MainActor 隔离的闭包在音频线程执行。
- **KTD9. 登录。** `LogtoConfig` 加入 resource `https://api.yado1225.top/ai`，取 token 时指定该 resource。refresh token 失效（`invalid_grant` / `invalid_target`）或缺失时清除本地凭证，界面回到未登录（顺带修复登录待办「会话失效后界面仍显示已登录」）。开发机需要重新登录一次才能拿到新 resource 的授权。
- **KTD10. 首页标红支持多条。** `HomeRecentEntryHighlight.pending` 改为数组，首页按条播放新增、修改、删除提示，切到第一条所在的月份。

---

## Interaction

- **麦克风按钮：** 空闲 → 按住收音（按钮上方气泡实时显示转写，上滑到阈值变为「松手取消」）→ 处理中（转圈，不响应）→ 结果条。按住不足 0.3 秒按点按处理（打开对话面板）；没识别到文字时静默取消。
- **结果条：** 显示最近一轮的回复或追问，以及本轮变更的流水（金额、分类、账户，推断字段标「待确认」，点按打开详情）。右侧「撤销」，追问时有候选项胶囊；追问未回答或请求失败时提供「手动记账」（带转写文字）。关闭结果条即结束会话。
- **对话面板（点按）：** 本次会话完整记录与本会话变更的流水；底部可打字发送，也可长按麦克风说话。
- **会话结束：** 关闭结果条或面板的「结束」、离开记账页、约 2 分钟没有新一轮。
- **未登录：** 按麦克风先弹出登录提示，登录成功后打开对话面板。
- **无障碍：** 按钮默认动作打开对话面板，自定义动作「开始说话 / 结束说话」切换收音；每轮结果用 VoiceOver 播报。

---

## Implementation Units

| 单元 | 文件 | 内容 |
| --- | --- | --- |
| U1 服务端 | yado_ai `voice-session` | `locale`、`canFinishLocally`（已完成） |
| U2 登录 | `AuthConfig`、`AuthStore` | AI resource、`accessTokenForAIService()`、凭证失效清理 |
| U3 仓库 | `LocalExpenseRepository` | `BookkeepingEntrySnapshot`、`BookkeepingEntryMutation`、`apply(_:)` |
| U4 契约与网络 | `Features/Voice/API/` | Codable 契约、`VoiceSessionAPI`、错误映射 |
| U5 执行器 | `Features/Voice/Session/VoiceToolExecutor.swift` | 工具映射、查询汇总、反向变更、首页提示快照 |
| U6 会话 | `Features/Voice/Session/VoiceSession.swift` | 会话循环、撤销、超时、上下文构建、本地结果提示 |
| U7 语音 | `Features/Voice/Speech/` | 两套识别实现、权限、音频采集 |
| U8 界面 | `Features/Voice/UI/`、`HomeView` | 麦克风、结果条、对话面板、「＋」入口、多条标红 |
| U9 资源 | `Localizable.xcstrings`、`InfoPlist.xcstrings`、`yadoA-Info.plist` | 中英文文案、麦克风与语音识别权限说明 |
| U10 测试 | `yadoATests/` | 契约编解码、仓库批量变更、执行器、会话循环（假 API）、多条标红 |

---

## Risks

- `SpeechAnalyzer` 系列为 iOS 26 新 API，未在本机编译验证，需重点检查编译与真机识别。
- 模型延迟：本地验证时 modelscope 一步约 5–13 秒，需选更快的模型或厂商。
- iOS 18 设备不支持端上识别时，音频会发给 Apple 识别，隐私政策需写明。
- 限流按步计数（每用户每分钟 30 次、每天 200 次），多轮会话消耗更快。
