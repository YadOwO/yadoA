---
title: "feat: Add cloud sync"
type: feat
date: 2026-10-22
origin: docs/brainstorms/2026-10-22-cloud-sync-requirements.md
---

# feat: Add cloud sync

## Summary

登录用户可以开启云端同步，服务端用 `yadoA_be`。客户端仍以本地为主：新增一张本地「同步台账」，记录每条业务记录的修改时间、删除标记和待上传状态，由统一的保存入口 `saveOrRollback` 自动登记，各仓库的写入逻辑不需要改。账户余额改为「期初余额 + 流水」推导，余额本身不同步。

分三个阶段：
1. 本地改造：不依赖服务端，做完后单机行为不变。
2. 服务端接口。
3. 客户端同步和界面。

App 还没有上线，schema 直接升到 V7，不做数据迁移。

---

## Key Technical Decisions

- **KTD1. 同步元数据放在独立的台账表里，不加到业务模型上。**
  - 新增本地模型 `SyncLedgerEntry`，字段：
    - `key`：`<entityType>:<uuid>`，唯一
    - `entityType`、`recordID`
    - `modifiedAt`：冲突裁决用的时钟
    - `payloadHash`
    - `isDeleted`
    - `revision`、`pushedRevision`：两者不相等表示还没上传
  - 这样业务模型和查询都不用改：现有约 57 处 `@Query` / `FetchDescriptor` 不需要额外过滤删除记录，本地删除仍然是硬删除，删除记录只留在台账里。这满足需求 R14、R15。
- **KTD2. 在 `saveOrRollback` 里自动登记修改。** 所有生产写入都经过这个入口（已逐一核对）。保存前遍历 context 的 `insertedModelsArray`、`changedModelsArray`、`deletedModelsArray`，处理四种同步类型：
  - 新增或修改：生成 payload 并计算哈希。**哈希没变就跳过**，这样只改了余额缓存的账户不会被当成修改。哈希变了就更新 `payloadHash`、`modifiedAt = now`，并让 `revision` 加 1。
  - 删除：标记 `isDeleted`，更新 `modifiedAt`，`revision` 加 1。如果本机还没有绑定账号，直接删掉这条台账，不需要留删除记录。
  - 应用服务器拉下来的数据时走另一个保存入口，不触发这里的登记。
- **KTD3. payload 复用备份格式的 DTO。** 直接用 `BackupAccount`、`BackupTransaction`、`BackupCategory`、`BackupBookkeepingPreference`。这些 DTO 本来就带版本号，对缺少的字段也有容错。哈希计算使用 `sortedKeys` 编码出的 JSON。
- **KTD4. 余额由流水推导。**
  - `Account` 新增 `openingBalance`（建账时的余额，之后不再修改）。payload 里只带期初余额，不带 `balance`。
  - `Account.balance` 保留，作为本地缓存。各仓库现有的增量更新逻辑不变。
  - 新增 `AccountBalanceRebuilder`：余额 = 期初余额 + 各笔流水的影响。其中支出为负、收入为正，转出为负、转入为正，余额调整按 `balanceDelta` 计算。拉取完成后对受影响的账户重算一次。
  - 余额调整的 `balanceBefore` / `balanceAfter` 保留为创建时的快照，账户详情照旧显示，不改为滚动余额。现有规则本来就是「业务日不承担余额重放」，单机时也只按差额累加，同步后语义不变。
- **KTD5. 没改过的预设记录不能覆盖别的设备。** `ensurePresets` 插入的预设分类行，以及默认创建的偏好单例，在台账里的 `modifiedAt` 记为 `distantPast`。否则新设备首次合并时，因为它的安装时间更晚，会把老设备上的排序、删除等修改覆盖掉。判断时同时看来源和内容：只有创建路径标了 `isAutoCreated`（不持久化）且内容仍是默认值才算；导入或用户写入的同样内容按当前时间登记。
- **KTD6. 冲突裁决：按整条记录取最后修改（LWW），并做时钟钳制。**
  - 服务端只接受 `modifiedAt` 严格更新的写入，时间相同时保留服务端已有的版本。
  - 写入时把 `modifiedAt` 钳制为 `min(客户端时间, 服务端当前时间)`，防止设备时钟偏快时永远获胜。
  - 被拒绝的写入在响应里带回服务端当前版本，客户端直接覆盖本地。
- **KTD7. 序号按用户串行分配。** `sync_users.last_version` 是每个用户自己的计数器，推送时在事务里 `SELECT … FOR UPDATE` 锁住这一行再递增。这样可以避免使用全局序列时，两个并发事务的提交顺序和序号顺序不一致，导致拉取方跳过某条记录。
- **KTD8. 用数据代次（epoch）处理删除云端数据。** `sync_users.epoch` 在「删除云端数据」时加 1。客户端每次请求都带上自己记录的 epoch，不一致时服务端返回 `epochMismatch`，客户端暂停同步并提示用户。
- **KTD9. 删除记录的清理。**
  - 服务端：`sync_devices` 记录每台设备拉取到的序号。每天执行一次清理，删除序号低于「90 天内活跃设备中最小的拉取序号」、或者服务端写入超过 90 天的删除记录（按服务端时间，不按客户端给的删除时间），并把清理边界记入 `sync_users.purged_through`。设备的 `since` 早于这个边界时，拉取和推送都返回 `resetRequired`，推送整批不写入，防止落后设备把已清理的删除写回。
  - 客户端：删除记录上传成功后，就可以从台账中移除。
- **KTD10. 全量重新同步。**
  - 流程：先从序号 0 全量拉取，**翻完所有页**（直到 `hasMore = false`）并按序号合并整轮结果，再一次性应用；整轮完成前不推送。完成后保存最后一页的 `nextSince`，用它推送本地还没上传的修改（推送带 `since`，全量拉取前推送会被 `resetRequired` 拒绝）。单页不是完整状态，整轮结果为空表示云端没有记录。整轮拉取结束后，本地那些已经同步过（`pushedRevision > 0`）、但不在全量结果里的记录在本地删除，即使本地还有待上传的修改也删除，并丢弃它们的待上传状态：它们在云端已被删除，只是墓碑已清理。从未上传过的记录保留并推送。全量结果是完整的当前状态，只能替换，不能和本地合并。
  - 触发场景：`resetRequired`、首次绑定账号，以及客户端的同步格式版本升级（本地存的 `syncSchemaVersion` 低于当前值时，把 `since` 重置为 0）。最后一种是给以后新增实体类型（比如 yadoI 的数据）预留的：旧版本客户端会忽略不认识的实体类型，升级后通过全量同步补回来。
- **KTD11. 拉取时的特殊情况。**
  - 本地台账是待上传状态，而且 `modifiedAt` 比远端更新：保留本地版本，下一轮再推送。
  - 远端某个账户被删了，但本地还有流水引用它：忽略这次删除，给这个账户重新登记 `modifiedAt = now` 并推送。
  - 远端某个分类已删除且带 `replacementKey`：在本地把引用它的流水迁移到替换分类。这一步按普通修改来登记。
  - payload 校验失败：跳过这条记录并记日志，不中断整体同步。
- **KTD12. 服务端存储不解析 payload。** 表 `sync_records` 用 `jsonb` 存 payload，服务端只读取 `id`、`modifiedAt` 和删除标记。以后要做端到端加密，只需要把 payload 换成密文字符串。第一版只做传输加密和服务器侧存储加密（需求文档里的待确认项，这里先按这个方案做）。这和 `yadoA_be` 现有的「金额用 numeric」约定不一样，需要在后端 AGENTS.md 里记录这是同步存储的例外，同时补上「列表与同步策略」那一条。
- **KTD13. 账号绑定状态。** 用本地的 `SyncState` 记录这些字段：`boundUserID`、`isEnabled`、`since`、`epoch`、`deviceID`、`syncSchemaVersion`、`lastSyncedAt`、`lastError`。
  - 存在 UserDefaults 里，不进 SwiftData，因为重置数据时需要单独控制它。
  - `boundUserID` 不为空，就表示需要保留删除记录。
- **KTD14. yadoI 联动的预留。**
  - 服务端的数据本来就按产品分开存放（各自独占自己的 schema）。以后 yadoI_be 暴露一个只读视图，由 yadoA_be 提供接口读取。
  - 客户端这期只做 KTD10 的同步格式版本升级机制。总资产已经集中在 `AccountSummaryPresentation.summary(for:)` 一个函数里，以后在这里接入虚拟账户即可，不再另抽。
  - 账户的来源字段这期不加。以后再加时，作为 DTO 的可选字段，旧数据也能正常解析。
- **KTD15. 网络层。** 和语音记账一样，手写 Codable 模型，以 `yadoA_be` 的 `openapi.json` 为准。Logto 新增 resource `https://api.yado1225.top/yadoa`，开发机需要重新登录一次。

---

## Implementation Units

### 阶段一：本地改造（不依赖服务端）

#### U1. 期初余额与余额推导

- **修改：**
  - `Account`：新增 `openingBalance`，`validating(draft:)` 时赋值。
  - `BackupAccount`：增加 `openingBalance`，导入时据此重算余额，不再信任文件里的 `balance`。
  - schema 升到 7.0.0。
- **新增：** `yadoA/Persistence/AccountBalanceRebuilder.swift`，提供 `rebuild(accountIDs:in:)`。
- **测试：**
  - 每个仓库操作（记账、修改、删除、转账、余额调整）执行后，余额缓存都等于 rebuild 的结果；
  - 导入备份后余额正确，旧备份缺少期初余额时可以倒推。

#### U2. 同步台账与自动登记

- **新增：**
  - `yadoA/Persistence/Sync/SyncLedgerEntry.swift`
  - `SyncEntityType`（`account`、`transaction`、`category`、`preference`）
  - `SyncPayloadCoder`：模型和 DTO 互转，并计算哈希
  - `SyncState`：KTD13 中的状态
- **修改：**
  - `ModelContext.saveOrRollback`：实现 KTD2 的登记逻辑，并新增 `saveApplyingRemote()` 入口。
  - `LocalCategoryRepository.insertMissingPresets` 和偏好单例的创建：按 KTD5 处理。
  - `LocalDataResetService`：通过参数决定是否同时清空台账。
- **测试：**
  - 新增、修改、删除都会生成对应的台账；
  - 只改了余额缓存时不会登记；
  - 改了又改回原样（哈希相同）时不会登记；
  - 未绑定账号时删除不保留删除记录，绑定后会保留；
  - 预设行的 `modifiedAt` 为 `distantPast`；
  - 撤销和导入恢复会正常登记修改；
  - 走 `saveApplyingRemote` 时不登记。

### 阶段二：服务端（`yadoA_be`）

#### U3. 同步接口

- **表结构**（`src/db/schema.ts`）：
  - `sync_records`：主键 `(user_id, entity_type, record_id)`，字段 `payload jsonb`、`modified_at`、`deleted_at`、`server_version bigint`、`device_id`，索引 `(user_id, server_version)`；
  - `sync_users`：`user_id`、`last_version`、`epoch`、`purged_through`；
  - `sync_devices`：`user_id`、`device_id`、`last_pulled_version`、`last_seen_at`。
- **接口**（`src/modules/sync/`）：
  - `POST /v1/sync/push`：请求体 `{ deviceId, epoch, since, changes[] }`。在一个事务里锁住用户行，逐条按 LWW 写入。返回 `{ results[], resetRequired }`，每条结果为 `applied`（带 `serverVersion` 和钳制后的 `modifiedAt`）或 `stale`（带服务端当前版本）。单次最多 250 条，单条 payload 不超过 16 KB（UTF-8），整批约 4.2 MB，低于 nginx 的 8m。
  - `GET /v1/sync/pull?since&limit&deviceId&epoch`：返回 `{ changes[], nextSince, hasMore, resetRequired }`，同时更新这台设备的 `last_pulled_version`。
  - `DELETE /v1/sync/data?epoch`：删除该用户的全部同步记录，epoch 加 1；epoch 不一致时拒绝，防止旧设备删掉重置后的新数据。
  - `GET /v1/sync/state`：返回当前 epoch，首次开启同步时用它初始化本地 epoch（实现时补充）。
- **实现时补充的约定**（客户端 U4–U6 需遵守）：
  - `modifiedAt` 早于 1970-01-01 时按 1970-01-01 记录：postgres 驱动会把公元 1 年读成 2001 年，让没改过的预设记录反而胜出。客户端的 `distantPast` 推送后会收到 1970，按 `applied` 结果写回台账即可，仍早于任何真实修改。
  - epoch 不一致返回 409，`code` 为 `EPOCH_MISMATCH`，`details.epoch` 是当前代次。
  - 删除云端数据会额外占用一个序号作为清理边界，删除前的任何 `since` 拉取都会得到 `resetRequired`；客户端接受新 epoch 后应把 `since` 归零。
  - 设备进度记为拉取请求带上的 `since`，只增不减；拉取结果包含墓碑，`since=0` 时也包含。
  - 最后一页的 `nextSince` 是服务端当前序号（不一定等于最后一条的序号），客户端直接保存。
  - 单条 payload 超过 16 KB 会让整批返回 400；客户端分批前先剔除超限记录并记日志（备注目前不限长度）。
- **清理任务：** 进程内每天执行一次，规则见 KTD9。
- **文档：** 更新 AGENTS.md 里的「列表与同步策略」和 KTD12 中的例外说明；`openapi.json` 由服务运行时在 `/openapi.json` 生成，不入库。
- **测试：**
  - LWW 判断：更新的才写入，时间相同保留服务端版本，未来时间会被钳制；
  - 并发推送时序号连续，拉取不会漏掉记录；
  - 分页拉取正确；
  - `since` 早于清理边界时返回 `resetRequired`；
  - epoch 不一致时拒绝请求；
  - 用户之间的数据相互隔离。

### 阶段三：客户端同步

#### U4. 网络层与鉴权

- **新增：**
  - `yadoA/Features/Sync/SyncAPI.swift`：`SyncServing` 协议（state、push、pull、删除云端数据，U5 用 mock 替换）和 `SyncAPI` 实现；`SyncAPIError` 带 `isRetryable`，409 `EPOCH_MISMATCH` 映射为 `.epochMismatch(currentEpoch:)`；
  - `yadoA/Features/Sync/SyncContract.swift`：与后端 schemas 一一对应的 DTO。payload 用 `SyncJSONValue` 原样收发；记录类型保留原始字符串，旧客户端遇到新类型只跳过这一条；早于 1970 的裁决时钟按 1970 发送；
  - 类型都是 `nonisolated`，U5 在后台 actor 中编解码。
- **修改：**
  - `AuthConfig` 新增 `syncServiceResource`（`https://api.yado1225.top/yadoa`）和 `syncServiceEndpoint`；
  - `AuthStore` 的 resources 列表加上它，新增 `accessTokenForSyncService()`；`AIServiceAuthError` 改名为两个服务共用的 `ServiceAuthError`。

#### U5. 同步引擎

- **新增：**
  - `yadoA/Features/Sync/SyncEngine.swift`：`@MainActor` 的调度器，保证同一时间只有一次同步在进行；状态（同步中、失败原因、代次不一致）放在内存里，供 U7 展示；写回 `SyncState` 时只改进度字段，期间绑定或代次被 U6 改过就丢弃本轮进度；
  - `SyncStore`：在主线程用独立的 manual-save context 读取台账、应用远端变更。原计划用 `@ModelActor` 放到后台，但工程默认隔离是 MainActor，全部 `@Model` 和仓库都在主线程，改后台需要整套模型层改为 nonisolated，代价过大；网络和 JSON 编解码已在 `SyncAPI` 的 `@concurrent` 方法中放到后台；
  - `SyncRecordApplier`：按 KTD11 把服务端记录写入模型，复用备份 DTO 的解码与校验；
  - `SyncEngineHost`：挂在 `ContentView` 上，创建引擎并注入环境。
- **分类迁移的补充规则：** 远端分类删除时若选择了「随分类删除流水」（`replacementKey` 为空），或迁移目标在本机不可用，本机独有的流水迁到「其他」，不删除用户数据。
- **流程：**
  - 推送：按 250 条一批上传待上传的台账，确认成功后写入 `pushedRevision`，并清理已上传的删除记录；
  - 拉取：分页拉取，应用规则见 KTD11，应用完重算受影响账户的余额；
  - 全量同步：见 KTD10；
  - epoch 不一致时暂停同步并报告。
- **触发：** 启动、`scenePhase` 变为 `.active`、本地保存后 2 秒防抖（台账登记后发出通知）、手动触发。失败时按指数退避重试，最长间隔 5 分钟。
- **测试**（mock API）：
  - 推送和拉取往返；
  - 返回 `stale` 时用服务端版本覆盖本地；
  - 推送进行中本地又被修改时，不会清除这条的待上传状态；
  - 本地待上传且更新的版本不会被拉取覆盖；
  - 账户删除和流水引用冲突时的处理；
  - 分类替换迁移；
  - 全量同步后会删除服务端已经没有的本地记录；
  - 升级同步格式版本会触发全量同步。

#### U6. 账号绑定生命周期

- **开启同步：**
  - 本机未绑定时，把现有记录都登记为待上传（为没有台账的记录补登记），然后执行一次全量同步；
  - 本机已经绑定了其他账号时，拒绝开启，并提示先清空本机数据（需求 R5）。
- **关闭同步：** `isEnabled = false`，台账继续记录本地修改，下次开启时再上传。
- **退出登录：** 弹出选择：
  - 保留在本机：解除绑定，清空台账，`since` 归零；
  - 从本机清除：执行 `eraseAll`，同时清空台账。
- **清空数据（已开启同步时）：**
  - 仅本机：先关闭同步并解除绑定，再清空；
  - 本机和云端：先调用 `DELETE /v1/sync/data`，再清空本地数据，然后保持同步开启，从新的 epoch 开始。
- **注销账号：** 在注销流程中先删除云端数据（注销功能本身见登录待办文档）。
- **测试：** 覆盖上面每条路径对应的 `SyncState` 和台账状态。

#### U7. 界面、本地化与收尾

- **新增：** `yadoA/Features/Sync/SyncSettingsView.swift`，从「我的」页进入。页面包含：同步开关、最近一次同步时间或失败原因、「立即同步」和「删除云端数据」（需要二次确认）。
- **修改：**
  - 登录成功后提示一次是否开启同步；
  - `ProfileView` 退出登录时弹出选择；
  - 清空数据的入口在开启同步时增加二选一。
- 在 `Localizable.xcstrings` 中补充中英文文案，界面使用系统语义色。iOS 26 及以上可以给同步状态卡片加 `glassEffect`，iOS 18 降级为 `.regularMaterial`。
- 更新 `HomeUITestFixture` 和 `HomeDesignPreview`，使它们适配 `openingBalance`。

---

## Scope Boundaries

- 不做 iCloud，不做后台定时同步（`BGAppRefreshTask`），不做字段级合并，也不提供冲突的手动选择。
- 不做端到端加密，只保证 payload 对服务端不透明，以后可以平滑升级。
- 不做 yadoI 联动，只做 KTD14 中的预留。

---

## Risks

- **漏走统一保存入口：** 以后如果新增的写入路径直接调用 `context.save()`，修改就不会被登记，也就不会同步。缓解：给 `saveOrRollback` 加注释说明；U2 增加一个测试，扫描 `yadoA/` 下除测试夹具外的 `.save()` 调用。
- **设备时钟不准：** 服务端钳制只能挡住时钟偏快的设备。时钟偏慢的设备上做的修改可能会输给更早的修改，这在记账场景下概率很低，可以接受。
- **停用账户余额不为零：** 一台设备停用了账户，另一台设备同时往这个账户里记了一笔，同步后会出现余额不为零的停用账户。这期只保证不崩溃、余额正确，后续再看是否需要提示。
- **全量同步的性能：** 7 万条记录量级时，应用远端数据要放在后台 context 中，每 500 条保存一次，同时显示进度。

---

## Verification Focus（交付时请开发者重点验证）

1. 两台设备登录同一账号，交替离线记账、修改、删除，恢复网络后两边的流水和余额一致。
2. 新设备首次开启同步时，老设备上的分类排序和删除不会被覆盖。
3. 分别选择退出登录、切换账号、清空数据（仅本机、本机和云端）后，状态符合 U6 的描述。
4. 服务端：并发推送后，拉取结果没有遗漏；清理任务执行后，长期离线的设备会走全量同步。
5. 在 iOS 18 设备上，同步设置页显示正常。
