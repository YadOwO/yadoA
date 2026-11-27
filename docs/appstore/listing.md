# 芽豆资产 App Store 上架资料

整理日期：2026-11-26。

依据：yadoA `dev` 上的代码、yado_run `dev` 上的法律文档（`src/content/legal/yadoa/` 下的用户协议、隐私政策、第三方信息共享清单）、yado_ai `dev` 上的点数和内购配置。

开发者账号下来后，照着这份文档往 App Store Connect 里复制粘贴就行；拿不准的地方都标了「需要维护者决定」。

## 〇、怎么用

- 每个字段（名称、副标题、宣传文本、描述、关键词）都单独放在一个代码块里，整块复制粘贴，不要连标题和「字数」那一行一起选。
- 每个代码块上一行有一条看不见的注释，写着语言和字段名，第八节的脚本靠它找到文案，不要删。
- 改了文案，要重跑第八节的脚本，再把下面的总表、各字段后面的「字数」和第八节贴出来的输出一起改成新数字。
- 字数按苹果的算法：用 Python 的 `len()` 数字符，一个汉字算 1，空格、标点、换行都算。
- 这次只写简体中文（zh-Hans）和英文（en-US）两套。没有繁体中文（zh-Hant）页面时，App Store 会显示主要语言那一套。
- 截图、App 审核说明、App 隐私问卷（已在 [app-store-privacy-labels.md](../rules/app-store-privacy-labels.md) 第二节）、App 内购买商品的上架资料都不在这份文档里。

### 总表

| 字段 | 苹果上限 | zh-Hans 字数 | en-US 字数 |
| --- | --- | --- | --- |
| 名称 | 30 | 4 | 10 |
| 副标题 | 30 | 10 | 25 |
| 宣传文本 | 170 | 64 | 169 |
| 描述 | 4000 | 898 | 2555 |
| 关键词 | 100 | 67 | 99 |

这些数字和第八节脚本的输出一致，都没有超限。

### 需要维护者决定的事

| 事项 | 在哪一节 |
| --- | --- |
| 英文名仍写着 yado Assets 的地方改不改；App Store 上「Yado Asset」被占用时用哪个备选名 | 一、1 |
| 主要语言、次分类 | 四 |
| 版权里的运营者名称 | 四 |
| 官网片尾和隐私政策里的联系邮箱不是同一个，统一成哪个 | 四 |
| 官网产品页上架后的状态和 TestFlight 链接 | 四 |
| 年龄分级是否要比问卷算出来的 4+ 调得更高 | 五 |
| 首发是否包含中国大陆（看 ICP 进度） | 六 |
| 提审前发布 yado_run，让线上的隐私政策和共享清单追上 dev | 七、2 |

## 一、统一口径

### 1. 名称

- 中文：「芽豆资产」。
- 英文：「Yado Asset」。
- 理由：手机桌面显示的名字就是这个（`yadoA/InfoPlist.xcstrings` 的 `CFBundleDisplayName`：en 是 Yado Asset，zh-Hans 是芽豆资产，zh-Hant 是芽豆資產）；yado_run 的隐私政策和用户协议在 `dbd797d` 已经统一成 Yado Asset；截图页 `screenshots.html` 的 brand 也是 Yado Asset。

**仍写着 yado Assets（带 s）的地方，这次不改，维护者决定改不改：**

| 位置 | 内容 | 谁能看到 |
| --- | --- | --- |
| yado_run `src/data/products.ts` 第 137 行 | yadoa 的 `name.en`，是官网产品页的英文标题 | 官网访客 |
| yado_run `src/content/legal/yadoa/en/sharing.md` 共 5 处 | 第 63 行 1 处、第 67 行 2 处、第 69 行 2 处 | 英文版第三方信息共享清单的读者 |
| yadoA `yadoA/Localizable.xcstrings` 的英文：`privacy.agreement.title`、`privacy.agreement.decline.alert.message` | 「Before you use Yado Assets」等 | 系统地区是中国大陆、首次启动的同意卡，线上包能看到 |
| yadoA `yadoA/Localizable.xcstrings` 的英文：`dataLink.intro`、`dataLink.consent.intro`、`dataLink.revoke.confirm.message` | 数据联动页的说明 | 线上暂时看不到（数据联动在线上藏着） |
| yadoA `yadoATests/SeriesCatalogTests.swift` 第 17、149 行 | 测试用的假数据，不是对外文案 | 只有开发者；可以不改 |

**如果 App Store 上「Yado Asset」已被占用**，给两个备选，都是在名称后面接一个短描述（备选名带了 voice，用的话关键词里的 voice、语音记账要拿掉，免得重复）：

<!-- field: zh-Hans name-alt1 -->
```
芽豆资产：语音记账
```
字数：9 / 30

<!-- field: zh-Hans name-alt2 -->
```
芽豆资产 - 说一句话记账
```
字数：13 / 30

<!-- field: en-US name-alt1 -->
```
Yado Asset: Voice Ledger
```
字数：24 / 30

<!-- field: en-US name-alt2 -->
```
Yado Asset - Voice Bookkeeping
```
字数：30 / 30

### 2. 口号、截图标题和功能名

- 口号（出自 yado_run `src/data/products.ts` 里 yadoa 的 `logline`）：
  - 中文：会听话的账本。说一句话，账就记好了。
  - 英文：A ledger that listens. Say it once, and it's written down.
- 截图大标题（`screenshots.html` 里 `COPY` 的 `h`）可以借用：「说一句，记好几笔」（Say it once. Log it all）、「想到什么，就说什么」（Just say what you need）、「净资产，一直心里有数」（Your net worth, always in view）、「拍张小票，也能记账」（Snap a receipt. It's recorded）、「小事，也替你想好了」（The little things, taken care of）。
- 功能名用 App 里的叫法（`Localizable.xcstrings`）：

| 功能 | 中文 | English |
| --- | --- | --- |
| 语音记账 | 语音记账 | Voice Entry |
| 对话记账 | 芽豆助手 | Yado Assistant |
| 麦克风旁的打字入口 | 键盘图标（界面上没有文字，「打字记账」只是无障碍标签） | keyboard icon (no visible text; "Type instead" is only the accessibility label) |
| 周期记账 | 周期记账 | Recurring |
| 提醒 | 每日记账提醒 | Daily Reminder |
| 签到 | 每日签到 | Daily Check-in |
| 点数 | AI 点数 | AI Points |
| 充值 | 充值点数 | Buy Points |
| 同步 | 云端同步 | Cloud sync |
| 搜索 | 搜索记账 | Search |
| 分类 | 分类管理 | Categories |
| 备份 | 导出全部数据 | Export all data |
| 恢复 | 从备份恢复 | Restore from backup |
| 应用锁 | 面容 ID / 密码锁 | Face ID / Passcode Lock |
| 深色模式 | 亮暗色（设置里选浅色、深色或跟随系统） | Appearance |
| 底部导航 | 记账、图表、账户、我的 | Ledger、Charts、Accounts、Profile |
| 反馈 | 意见反馈 | Feedback |

### 3. 文案里不能写的话

适用于名称、副标题、宣传文本、描述、关键词。第八节的脚本会扫一遍这些词，但脚本只是兜底，改文案时自己也要过一遍。

| 不能写 | 原因 |
| --- | --- |
| 「不投广告」「没有广告」「无广告」这类保证 | 已从引导页和隐私政策删掉（yado_run `85c9824`、yadoA `8e3835c`，后者是 2026-11-17 的提交），维护者要求相关的全部下掉。隐私政策现在写的是「以后如果加入广告，会先更新本政策」。上架页文字里一个字都不提广告 |
| 「端到端加密」 | 云同步是明文 JSON，传输中走 HTTPS 加密，服务器上没有端到端加密（[app-store-privacy-labels.md](../rules/app-store-privacy-labels.md) 第一节） |
| iPad、横屏 | 1.0 只支持 iPhone 竖屏（仓库根目录 `AGENTS.md`） |
| 「最」「第一」「唯一」「首个」「国家级」「顶级」「100%」这类绝对化用语 | 中国《广告法》禁止；中文文案里连「最近」这样带「最」字的词也不用，省得被机器筛到 |
| 单独写「免费」 | App 有内购。要说基础功能时写「基础记账不登录也能用」。「免费」只用在点数上（「签到免费领点数」），不能用来形容 App |
| 线上包里藏起来的功能：截图记账、重看引导、帮助改进 AI | `AuthConfig.swift` 里 prod 的 `isScreenshotShortcutAvailable`、`isOnboardingReplayAvailable`、`isAITraceConsentAvailable` 都是 false，对应这三个功能，线上看不到入口 |
| 线上暂时不可用的功能：数据联动、更多芽豆产品、上传头像 | 数据联动（芽豆有物估值联动）要等芽豆有物上架，由 `DataLinkStore.isItemValueLinkAvailable` 控制；更多芽豆产品在目录里只有自己时不显示（`SeriesCatalogStore`）；上传头像只有 Debug 包能用 |
| 「录音不上传」「数据不离开手机」这类绝对说法 | 没有离线识别的设备，iOS 会把音频交给 Apple；打开同步后账本会上传。只能写「录音不会发送到芽豆的服务器」「默认只存在本机，同步由你打开」 |
| AI 服务商的名字、具体点数数量、价格 | yado_ai 上架前会换服务商；点数和价格以 App 内显示为准，调整时不用回头改上架页。说 AI 时只用「AI 记账」「芽豆助手」 |

### 4. 文案里必须写的话

AI 记账（语音、打字、拍小票）要登录、联网，会消耗 AI 点数；新账号赠送点数，每日签到也能免费领，也可以在 App 内购买；在 App 内购买的点数永不过期。

出处：yado_run `dev` 的用户协议第五节「AI 点数」第 1、2 条（英文版 5.1、5.2），隐私政策第一节「AI 点数与每日签到」。描述的最后一段「AI 点数」把这些都写全了。

## 二、简体中文（zh-Hans）

### 名称

<!-- field: zh-Hans name -->
```
芽豆资产
```
字数：4 / 30

### 副标题

<!-- field: zh-Hans subtitle -->
```
说一句话，账就记好了
```
字数：10 / 30

### 宣传文本

<!-- field: zh-Hans promo -->
```
会听话的账本。说一句话，账就记好了：语音、打字、拍小票都能记。AI 记账需登录并联网，会消耗 AI 点数；基础记账不登录也能用。
```
字数：64 / 170

### 描述

<!-- field: zh-Hans description -->
```
会听话的账本。说一句话，账就记好了。

芽豆资产是一本放在手机里的账本：想到什么，就说什么。账户、净资产和图表放在一处，钱去了哪、还剩多少，心里有数。

【语音记账与芽豆助手】
· 按住屏幕底部的麦克风，说「午饭 32，打车 28」，一句话记成两笔，自动分好类、选好账户。
· 记、改、删、查都可以说：「刚才打车那笔改成 40」「早上那杯咖啡删掉」「这个月吃饭花了多少」。
· 不方便说话，就点麦克风右边的键盘图标，在芽豆助手里打字；拍张小票或从相册选一张图，也能记账。

【账户与净资产】
· 现金、储蓄卡、信用卡、虚拟账户、投资、负债、债权，都可以建成账户，放在一处看。
· 账户页汇总净资产，资产分析按净资产、资产、负债看走势和构成。

【图表】
· 按周、月、年看收入和支出，再按分类看钱花在了哪里、怎么变化。

【周期记账、每日提醒、搜索和分类】
· 周期记账：房租、会员这类固定收支，到日子自动记上。
· 每日记账提醒：按你设的时间轻轻提醒一下，不再忘记。
· 搜索记账：按关键词和日期找回任何一笔。
· 分类管理：按自己的习惯增减、调整分类。

【隐私与掌控】
· 基础记账不登录也能用，账本默认只存在这台手机上。
· 云端同步默认关闭，要不要同步由你打开，随时能关；登录本身不会上传账本。
· 语音由 iOS 系统转成文字，录音不会发送到芽豆的服务器。
· 面容 ID / 密码锁：打开 App 先验证，防止他人查看你的账本。
· 随时「导出全部数据」做备份，换手机时用「从备份恢复」找回。
· 深色模式：夜里也不刺眼。

【AI 点数】
· AI 记账（语音、打字、拍小票）需要登录并联网，使用时会消耗 AI 点数。
· 新账号会赠送点数，每日签到也能免费领取，也可以在 App 内购买。
· 在 App 内购买的点数永不过期；签到等免费获得的点数有有效期，以 App 内显示为准。
· 点数用于 App 内的 AI 功能，不能提现，也不能转让。具体数量和价格以 App 内显示为准。
· AI 的结果可能有误，请核对后再保存；统计和图表只是对你所记数据的整理，不构成理财建议。
```
字数：898 / 4000

### 关键词

<!-- field: zh-Hans keywords -->
```
记账,账本,语音记账,收支,账单,流水,银行卡,信用卡,周期记账,每日提醒,小票,面容ID,备份,个人财务,AI记账,图表,分类,支出
```
字数：67 / 100

选词的原则：英文逗号分隔，逗号后不加空格；不重复名称里的「芽豆」「资产」（所以也没有「净资产」）；只写 App 里真有的功能；不写别家的商标（微信、支付宝这类名字不放进关键词）；没有「预算」，因为 App 没有预算功能。

## 三、英文（en-US）

英文是按英文读者的习惯写的，不是逐字翻译。

### 名称

<!-- field: en-US name -->
```
Yado Asset
```
字数：10 / 30

### 副标题

<!-- field: en-US subtitle -->
```
Say it once. It's logged.
```
字数：25 / 30

### 宣传文本

<!-- field: en-US promo -->
```
A ledger that listens. Say it once, and it's written down. Speak, type or snap a receipt. AI bookkeeping needs sign-in and uses AI points; basic entries need no account.
```
字数：169 / 170

### 描述

<!-- field: en-US description -->
```
A ledger that listens. Say it once, and it's written down.

Yado Asset is a ledger that lives on your phone. Say what you spent and it's recorded. Accounts, net worth and charts sit in one place, so you can see where your money went and what's left.

VOICE ENTRY AND YADO ASSISTANT
• Hold the mic at the bottom of the screen and say "Lunch 32, taxi 28." One sentence becomes two entries, sorted into categories and matched to your accounts.
• Add, edit, delete and look things up by voice: "Change that taxi to 40." "Delete this morning's coffee." "How much did I spend on food this month?"
• Can't talk? Tap the keyboard icon beside the mic to open Yado Assistant and type. Take a photo of a receipt or pick a picture, and it can be recorded too.

ACCOUNTS AND NET WORTH
• Cash, debit cards, credit cards, virtual accounts, investments, debts and receivables, all in one view.
• The Accounts tab sums up your net worth, and asset analysis shows trends and breakdowns for net worth, assets and liabilities.

CHARTS
• See income and expenses by week, month or year, then break spending down by category.

RECURRING, REMINDERS, SEARCH AND CATEGORIES
• Recurring: rent, memberships and other regular items are logged when they're due.
• Daily Reminder: a gentle nudge at the time you choose.
• Search: find any entry by keyword or date range.
• Categories: add, edit and arrange categories your way.

PRIVATE BY DEFAULT, YOURS TO CONTROL
• Core bookkeeping works without an account, and your ledger stays on this phone by default.
• Cloud sync is off until you turn it on, and you can turn it off anytime. Signing in does not upload your ledger.
• Speech is turned into text by iOS, and recordings are not sent to Yado's servers.
• Face ID / Passcode Lock asks for verification when the app opens, so others can't look through your ledger.
• Use Export all data to back up, and Restore from backup to bring everything to a new phone.
• Dark mode keeps it easy on the eyes at night.

AI POINTS
• AI bookkeeping (voice, typing and receipt photos) requires signing in and a network connection, and uses AI points.
• New accounts get points, Daily Check-in gives free points, and you can also buy points in the app.
• Points you buy in the app never expire. Free points expire as shown in the app.
• Points work for AI features inside the app and can't be cashed out or transferred. Amounts and prices are shown in the app.
• AI results can be wrong, so check entries before you save them. Charts and stats summarize what you record and are not financial advice.
```
字数：2555 / 4000

### 关键词

<!-- field: en-US keywords -->
```
bookkeeping,voice,expense,tracker,income,ledger,money,accounts,net worth,receipt,reminder,backup,AI
```
字数：99 / 100

选词的原则同中文：英文逗号分隔，逗号后不加空格；不重复名称里的 Yado、Asset；不写别家的商标；没有 budget，因为 App 没有预算功能。「net worth」中间的空格是词内的空格，不是逗号后的空格。

## 四、App 信息

| 项目 | 填写 | 说明 |
| --- | --- | --- |
| 主要语言 | 简体中文 | 建议。由维护者定 |
| 主分类 | 财务（Finance） | |
| 次分类 | 效率（Productivity） | 建议。最终由维护者定 |
| 内容版权（是否包含第三方内容） | 否 | App 里显示的都是用户自己记的账和自己的 AI 对话；界面、图标和文字是自己做的，系统图标来自 Apple 的 SF Symbols；三个开源组件（Logto Swift SDK、JOSESwift、KeychainAccess）只管登录和保存凭证，不展示内容；AI 的回复是按用户自己的账本现场生成的，不是别人的版权内容 |
| 版权 | `2026 <运营者名称>` | 名称留占位，由维护者填；填的名称要和开发者账号的主体、隐私政策里写的运营者一致 |
| 技术支持网址 | zh-Hans：`https://my.yado1225.top/zh/works/yadoa/`<br>en-US：`https://my.yado1225.top/works/yadoa/` | 官网的芽豆资产产品页 |
| 营销网址 | 同上两个地址 | |
| 隐私政策网址 | 见 [app-store-privacy-labels.md](../rules/app-store-privacy-labels.md) 第二节 | 那里按语言分别写了地址，这里不重复抄 |

**联系方式在哪里找到：** 产品页（yado_run `src/views/ProductView.astro`）最下面是片尾（Credits），写着「联系」邮箱和 GitHub；App 里「我的 › 意见反馈」也能联系到我们（要登录）。这够苹果对支持网址「打开后能找到联系方式」的要求，所以不用另做支持页，也不用改 yado_run。

### 需要维护者决定

1. **联系邮箱不是同一个。** 官网片尾用 yado_run `src/i18n/index.ts` 里 `contact.email`（yado.async@gmail.com）；隐私政策和用户协议「联系我们」写的是 yado.dev@proton.me。用户从上架页点进官网看到的邮箱，和隐私政策里写的邮箱对不上。建议统一成一个，改哪边由维护者决定，这次都不改。
2. **官网产品页现在是「即将上映」，还带着 TestFlight 入口。** `products.ts` 里 `testFlight` 的注释写着「上架后删掉」。上架后要在 yado_run 改产品状态、去掉 TestFlight 链接，这样用户从 App Store 点进来看到的才是对的。这次不改。
3. 主要语言、次分类、版权里的运营者名称，见上表。

## 五、年龄分级问卷

对照的是苹果 Age ratings reference（https://developer.apple.com/help/app-store-connect/reference/age-ratings）2026-11-26 打开时的题目分类。这页只列题目分类和频率，没有给出每题的原文和选项文字，所以下面用「中文叫法 / 苹果的英文名」对应，**以 App Store Connect 里实际的题目和选项为准**。表里的「无」「否」就是选「没有 / 否」。

| 题目 | 答案 | 一句理由 |
| --- | --- | --- |
| 家长控制 / Parental Controls | 否 | App 里没有家长控制或监护人设置 |
| 年龄验证 / Age Assurance | 否 | 不做年龄验证，也没有用苹果的年龄范围接口 |
| 不受限制的网页访问 / Unrestricted Web Access | 否 | App 只用 Safari 视图打开自己官网的法律页面（`Features/Legal/LegalDocument.swift` 的 `baseURL` 是 `https://my.yado1225.top`），登录页是自家 Logto 的登录页，没有给用户开放浏览别的网站的入口 |
| 用户生成内容 / User-Generated Content | 否 | 账本只有自己看；AI 对话也不会给别人看 |
| 社交媒体 / Social Media | 否 | 没有信息流、关注、点赞这类功能 |
| 消息与聊天 / Messaging and Chat | 否 | AI 对话是人和 AI 之间的，不是用户之间的交流；意见反馈是用户和开发者一对一，用户之间看不到彼此 |
| 共享位置 / Shared Location | 否 | 不读定位，也不分享位置 |
| 广告 / Advertising | 否 | 按现状申报，**不写进文案，也不是对用户的承诺**；以后如果加广告，要把这一题改成「是」，同时先更新隐私政策和第三方信息共享清单 |
| 低俗语言或粗俗幽默 / Profanity or Crude Humor | 无 | 没有这类内容 |
| 恐怖或惊吓主题 / Horror/Fear Themes | 无 | 没有这类内容 |
| 酒精、烟草或毒品使用或提及 / Alcohol, Tobacco, or Drug Use or References | 无 | 没有这类内容 |
| 约会与恋爱 / Dating and Relationships | 无 | 没有这类内容 |
| 医疗或治疗信息 / Medical or Treatment Information | 无 | 预设分类里的「医疗」只是一个花销分类名，App 不提供医疗信息 |
| 健康或养生话题 / Health or Wellness Topics | 无 | 预设分类里的「健康」同样只是花销分类名 |
| 成人或暗示性主题 / Mature or Suggestive Themes | 无 | 没有这类内容 |
| 性内容或裸露 / Sexual Content or Nudity | 无 | 没有这类内容 |
| 露骨的性内容和裸露 / Graphic Sexual Content and Nudity | 无 | 没有这类内容 |
| 卡通或幻想暴力 / Cartoon or Fantasy Violence | 无 | 没有这类内容 |
| 写实暴力 / Realistic Violence | 无 | 没有这类内容 |
| 长时间的露骨或虐待性写实暴力 / Prolonged Graphic or Sadistic Realistic Violence | 无 | 没有这类内容 |
| 枪支或其他武器 / Guns or Other Weapons | 无 | 没有这类内容 |
| 赌博 / Gambling | 无 | 没有任何用真钱下注的玩法 |
| 模拟赌博 / Simulated Gambling | 无 | 每日签到和连签礼包给的是免费的随机点数，礼包不能花钱买；能花钱买的只有固定数量的点数包（yado_ai `src/config/store.ts`：60、180、450 点）。按审核指南 3.1.1，只有付费的随机物品才必须公开概率 |
| 开箱盒 / Loot Boxes | 无 | 苹果问的是花钱买到的随机物品；这里的随机礼包不卖，买到的点数数量固定，和模拟赌博同一个理由 |
| 竞赛 / Contests | 无 | 没有排名、对战或比赛；连续签到只是自己的签到记录 |

**预计结果：4+。**

**签到礼包为什么不算模拟赌博：** 礼包是签到送的，免费，不能花钱买；用户花钱买的点数，每一档的数量都是固定的，买之前就知道得到多少。随机的只有免费礼包里的点数。

**以后如果要开卖随机礼包：** 必须改「模拟赌博」「开箱盒」两题的答案，并在 App 内、购买前显示各档概率（审核指南 3.1.1）。

**需要维护者决定：** 隐私政策和用户协议写了「本 App 不面向不满 14 周岁的未成年人」，而问卷按内容算出来是 4+。这两件事不矛盾（一个看内容，一个是个人信息合规），但如果希望分级也体现这一点，要看 App Store Connect 有没有手动调高分级的选项，调不调由维护者定。另外不要选「儿童」类别。

## 六、App 与合规信息（中国大陆）

对照的是苹果的两页说明：[App 与合规信息](https://developer.apple.com/help/app-store-connect/reference/app-information/app-and-compliance-information)、[国务院令第 810 号](https://developer.apple.com/cn/help/app-store-connect/manage-compliance-information/manage-information-for-state-council-decree-no-810)。下面只写三件事的现状和后果，不写办理步骤。

### 1. ICP 备案号

- **现状：** 中国大陆区上架需要已核验的 ICP 备案号；现在没有。苹果的说明是：App 信息页里填的备案号和元数据要和工信部（MIIT）备案的一致，核验通过后会显示在中国大陆区的产品页上。
- **后果：** 没有已核验的备案号，就不能在中国大陆区上架。
- **首发范围：** 是否包含中国大陆，看维护者的 ICP 进度，这份文档不替维护者定。没办好时，在「价格与销售范围」里先不勾中国大陆，备案好了再加上。

### 2. 生成式 AI 和算法备案的申报项

- **现状：** App Store Connect 的合规信息里有生成式 AI 和算法备案相关的申报项。芽豆资产有 AI 记账（芽豆助手、语音记账），属于会被问到的那类。苹果的说明是：提供 AI 聊天机器人、图像或视频生成等服务的，要声明是否提供，并填已通过的大模型或算法备案信息；AI 能力用的是别人的技术时，还要提供授权或使用协议。
- 同一页还有「安全评估」一项：功能里分发 AI 生成内容的，要交安全评估的证明和报告。芽豆资产的 AI 回复算不算这一类，要看后台实际问到什么。
- **后果：** 上中国大陆区时，这些项要如实填写。苹果的页面没有写这些项没填或填不了会怎样，以 App Store Connect 里的提示为准。

### 3. 《国务院令第 810 号》报送

- **现状：** 按苹果的说明，自 2025 年 7 月起，中国大陆开发者通过 App Store 分发 App，苹果要把开发者的信息按季度报给国家税务总局。个人开发者要提供姓名、居民身份证号、联系电话等综合信息，苹果自己带上交易次数、总收入、退款金额。入口在 App Store Connect 的「商务」页「合规」部分。
- **后果：** 苹果的页面没有写不报送会怎样，只提醒这不影响开发者自己的纳税义务；后果不明，以 App Store Connect 里出现的提示为准。
- 苹果这一页看的是开发者所在地，不是上架哪些国家和地区，所以它和首发是否含中国大陆没有直接关系。

## 七、核对表

### 1. 功能表

描述里提到的每个功能占一行。「入口」是照着代码写的：Tab 在 `Features/App/AppTabView.swift`，「我的」页在 `Features/Profile/ProfileView.swift`，「设置」在 `Features/Profile/SettingsView.swift`。每一行都确认过在线上包（prod）里没有被 `AuthConfig` 的开关、`DataLinkStore.isItemValueLinkAvailable` 或 `SeriesCatalogStore` 藏起来。勾选框留给维护者，在 DebugProd 包（连线上）里逐条点一遍。

| 功能 | 描述里的说法 | App 里的入口 | 要登录吗 | DebugProd 包点过了吗 |
| --- | --- | --- | --- | --- |
| 语音记账 | 按住屏幕底部的麦克风说话，一句话记成几笔 | 记账、图表、账户、我的四个 Tab 的一级页面底部的麦克风（Tab Bar 附属栏），按住说话；进入二级页面时收起 | 要，也要联网；未登录时会问是否去登录，首次使用前有 AI 处理同意 | - [ ] |
| 说着改、删、查 | 「改成 40」「删掉」「这个月花了多少」 | 同上，语音或芽豆助手里打字都行 | 要 | - [ ] |
| 芽豆助手 | 点麦克风右边的键盘图标，在芽豆助手里打字 | 麦克风右边的键盘图标（无障碍标签叫「打字记账」），打开芽豆助手对话页 | 要；首次使用前有 AI 处理同意 | - [ ] |
| 拍小票记账 | 拍张小票或从相册选一张图 | 芽豆助手输入框的「添加图片」，选「拍照」「从相册选择」或「粘贴图片」 | 要；拍照要真机 | - [ ] |
| 手动记账 | 基础记账不登录也能用 | 记账 Tab 右上角的「记一笔」 | 不要 | - [ ] |
| 账户 | 现金、储蓄卡、信用卡、虚拟账户、投资、负债、债权 | 账户 Tab | 不要 | - [ ] |
| 净资产与资产分析 | 账户页汇总净资产，资产分析看走势和构成 | 账户 Tab 顶部的汇总卡片，点进资产分析 | 不要 | - [ ] |
| 图表 | 按周、月、年看收入和支出，再按分类看 | 图表 Tab，点分类进入分类统计 | 不要 | - [ ] |
| 周期记账 | 房租、会员这类固定收支到日子自动记 | 我的 › 周期记账 | 不要 | - [ ] |
| 每日记账提醒 | 按设的时间提醒 | 我的 › 设置 › 记账 › 每日记账提醒（开关加提醒时间） | 不要；要允许通知 | - [ ] |
| 搜索记账 | 按关键词和日期找回任何一笔 | 记账 Tab 右上角的放大镜「搜索记账」；账本里至少有一笔流水才会出现 | 不要 | - [ ] |
| 分类管理 | 增减、调整分类 | 我的 › 分类管理 | 不要 | - [ ] |
| 云端同步 | 默认关闭，要不要同步由你打开 | 我的 › 云端同步 | 要；默认是关的 | - [ ] |
| 面容 ID / 密码锁 | 打开 App 先验证 | 我的 › 设置 › 隐私与安全 › 面容 ID / 密码锁；设备要先设了密码 | 不要 | - [ ] |
| 导出全部数据 | 随时备份 | 我的 › 设置 › 数据 › 导出全部数据 | 不要 | - [ ] |
| 从备份恢复 | 换手机时找回 | 我的 › 设置 › 数据 › 从备份恢复 | 不要 | - [ ] |
| 深色模式 | 夜里也不刺眼 | 我的 › 设置 › 通用 › 亮暗色 | 不要 | - [ ] |
| AI 点数 | 使用 AI 记账会消耗 AI 点数 | 我的 › AI 点数 | 要（未登录时行尾提示登录后可用） | - [ ] |
| 每日签到 | 每日签到也能免费领取点数 | 我的 › 每日签到（在 AI 点数下面） | 要（未登录点它会先问是否去登录） | - [ ] |
| 充值点数 | 也可以在 App 内购买 | 我的 › AI 点数 › 充值点数 | 要；App Store Connect 里的内购商品上架、StoreKit 查得到才会出现，没有商品时这一块整个不显示 | - [ ] |
| 意见反馈 | （描述里没有单独写，支持网址里提到） | 我的 › 意见反馈 | 要 | - [ ] |

两个要特意试的场景：

- **离线模式：** 系统地区是中国大陆、首次启动没同意隐私政策时是离线模式，麦克风、AI 点数、每日签到、云端同步、意见反馈、充值入口都会藏起来（描述里这些功能的说法在这个模式下对不上，属正常，同意之后就有了）。
- **没有内购商品时：** 「充值点数」不出现。提审前要确认内购商品已经在 App Store Connect 建好、状态正确，否则审核员看不到描述里说的「可以在 App 内购买」。

### 2. 承诺表

文案里的每条承诺，对应隐私政策或用户协议的哪一节。出处是 yado_run `src/content/legal/yadoa/{zh,en}/{privacy,terms}.md`，按 `dev` 的内容（隐私政策更新于 2026-11-25，用户协议更新于 2026-11-22）。中文版标题用顿号编号（一、二），英文版用数字编号（1、2）。

| 文案里的承诺 | 隐私政策 | 用户协议 |
| --- | --- | --- |
| 基础记账不登录也能用，账本默认只存在手机上 | 「一句话概括」第 1 条；第一节开头「本 App 的功能分为基本功能和可选功能」（英文：The short version；1. What we collect and why 开头） | 一、服务内容「基本功能」（英文 1. The service） |
| 云端同步默认关闭，由你打开，随时能关；登录本身不会上传账本 | 「一句话概括」第 2 条；第一节「2. 云同步（默认关闭）」；第二节「敏感个人信息」 | 六、数据与备份（第 3 条）；英文 6. Your data and backups |
| 录音不会发送到芽豆的服务器 | 「一句话概括」第 3 条；第一节「8. 设备权限」里的「关于语音识别」 | 八、第三方服务（语音识别由 Apple 提供） |
| AI 记账（语音、打字、拍小票）要登录 | 第一节「1. 登录账号」（登录后才能使用云同步、AI 记账、AI 点数和意见反馈）；「3. AI 记账（需要登录）」 | 一、服务内容「可选功能」 |
| AI 记账会消耗 AI 点数 | 第一节「4. AI 点数与每日签到」 | 五、第 1 条 |
| 新账号赠送点数，每日签到可免费领 | 第一节「4. AI 点数与每日签到」 | 五、第 1 条 |
| 可以在 App 内购买点数 | 第一节「4. AI 点数与每日签到」第二段；第三节「App 内购买」 | 五、第 1、4 条 |
| 买的点数永不过期 | 第一节「4. AI 点数与每日签到」第二段 | 五、第 2 条（英文 5.2） |
| 免费获得的点数有有效期，以 App 内显示为准 | — | 五、第 2 条 |
| 点数只在 App 内用于 AI 功能，不能提现、转让 | — | 五、第 1、3 条 |
| 具体点数数量和价格以 App 内显示为准 | — | 五、第 4 条（价格以购买前 App 内显示的为准） |
| AI 的结果可能有误，请核对后再保存 | — | 四、第 1 条 |
| 统计和图表不构成理财建议 | — | 四、第 2 条 |
| 随时导出全部数据，换手机时从备份恢复 | 第六节「你的权利」的「查阅和复制」 | 六、第 1 条（建议定期导出）；第 2 条（导出文件没有加密，所以文案里不写备份加密） |
| 面容 ID / 密码锁在手机上验证 | 隐私政策里没有单独写，因为不涉及收集数据；本机验证的依据见 [app-store-privacy-labels.md](../rules/app-store-privacy-labels.md) 第一节「不上传的」 | — |

**点数说法以 yado_run `dev` 为准。** 需求里说线上（main）的用户协议还写着「不支持购买」，但这次在本机看到的 yado_run `origin/main`（2026-11-22 的提交 `2682026`）上，用户协议已经是「可以购买、买的点数永不过期」的写法，内容和 `dev` 一致。本机的远端引用可能不是最新，提审前请直接打开线上的页面核对一次（`https://my.yado1225.top/zh/legal/yadoa/terms/` 和英文版 `/legal/yadoa/terms/`）。

隐私政策和第三方信息共享清单，本机的 `origin/main` 是 2026-11-22 的版本，`dev` 是 2026-11-25，多了芽豆有物估值联动的内容。**提审前先发布 yado_run，让线上的法律文档追上 `dev`**，再提交审核。

### 3. 已知不一致

只记录，这次不改。

- `docs/appstore/screenshots.html` 的第 7 张图（f7）里有一个小方块写着「轻点背面 / 截图记账」（英文 Back Tap / Log a screenshot），可线上包里这个入口是藏着的。交给截图那条想法处理；描述和核对表里都没有写截图记账。
- 同一个文件第 6 张图（f6）的标题是「你的账本，只存在这台手机上」（英文 Your ledger lives on this phone），而云端同步是可选的、打开后账本会上传。要再看一下口径，和描述里的「默认只存在这台手机上」对齐。

## 八、字数统计

在仓库根目录（yadoA）下运行。脚本读 `docs/appstore/listing.md`，按每个代码块上一行的字段注释取出内容，去掉首尾换行后用 `len()` 计数，打印字段、语言、字数、上限和是否超限；顺带检查关键词的格式、关键词有没有重复名称里的词、文案里有没有第一节第 3 条的禁用词，以及「免费」「free」出现在哪里（要人工看是不是只指点数）。有问题时退出码为 1。

```bash
python3 -I - <<'EOF'
import re
import sys
from pathlib import Path

# 苹果规定的字符数上限
LIMITS = {"name": 30, "subtitle": 30, "promo": 170, "description": 4000, "keywords": 100}
LABELS = {"name": "名称", "subtitle": "副标题", "promo": "宣传文本", "description": "描述", "keywords": "关键词"}
# 关键词里不能重复名称里的词（按小写比较）
NAME_WORDS = {"zh-Hans": ["芽豆", "资产"], "en-US": ["yado", "asset"]}
# 文案里不能出现的写法（第一节第 3 条），按正则匹配、不分大小写
BANNED = [
    r"广告", r"\bads?\b", r"advertis", r"端到端", r"end-to-end", r"ipad", r"横屏", r"landscape",
    r"最", r"第一", r"唯一", r"首个", r"国家级", r"顶级", r"100%", r"\b(best|first|only|most|top)\b", r"#1",
    r"截图", r"screenshot", r"重看引导", r"replay", r"帮助改进", r"help improve",
    r"数据联动", r"data link", r"更多芽豆", r"more from yado", r"头像", r"avatar",
    r"录音不上传", r"不离开手机",
]
# 要人工确认只指点数的词
REVIEW = [r"免费", r"\bfree\b"]

path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("docs/appstore/listing.md")
text = path.read_text(encoding="utf-8")
fence = chr(96) * 3
marker = re.escape("<!" + "-- field: ")
pattern = re.compile(marker + r"(\S+) (\S+) -->\n" + fence + r"\n(.*?)\n" + fence, re.S)
fields = [(lang, name, body.strip("\n")) for lang, name, body in pattern.findall(text)]

problems = 0
print("字段 | 语言 | 字数 | 上限 | 是否超限")
for lang, name, body in fields:
    base = name.split("-alt")[0]
    limit = LIMITS[base]
    count = len(body)
    problems += count > limit
    label = LABELS[base] + ("（备选）" if "-alt" in name else "")
    print(f"{label} | {lang} | {count} | {limit} | {'超限' if count > limit else '未超限'}")

for lang in NAME_WORDS:
    for base in LIMITS:
        if not any(f[0] == lang and f[1] == base for f in fields):
            problems += 1
            print(f"缺少字段：{lang} {base}")

for lang, name, body in fields:
    if name == "keywords":
        bad = []
        if ", " in body or "，" in body or "\n" in body:
            bad.append("逗号后有空格、用了中文逗号或换行了")
        bad += [f"重复了名称里的「{w}」" for w in NAME_WORDS[lang] if w in body.lower()]
        problems += len(bad)
        print(f"关键词检查 {lang}：{'；'.join(bad) if bad else '通过'}")

hits = [(lang, name, p) for lang, name, body in fields for p in BANNED if re.search(p, body, re.I)]
problems += len(hits)
print("禁用词检查：" + ("未发现" if not hits else "；".join(f"{lang} {name} 命中 {p}" for lang, name, p in hits)))

for lang, name, body in fields:
    for p in REVIEW:
        for m in re.finditer(p, body, re.I):
            print(f"人工确认 {lang} {name}：…{body[max(0, m.start() - 8):m.end() + 8]}…".replace("\n", " "))

print(f"共 {len(fields)} 个字段，{problems} 处问题")
sys.exit(1 if problems else 0)
EOF
```

实际输出（2026-11-26 运行，退出码 0）：

```text
字段 | 语言 | 字数 | 上限 | 是否超限
名称（备选） | zh-Hans | 9 | 30 | 未超限
名称（备选） | zh-Hans | 13 | 30 | 未超限
名称（备选） | en-US | 24 | 30 | 未超限
名称（备选） | en-US | 30 | 30 | 未超限
名称 | zh-Hans | 4 | 30 | 未超限
副标题 | zh-Hans | 10 | 30 | 未超限
宣传文本 | zh-Hans | 64 | 170 | 未超限
描述 | zh-Hans | 898 | 4000 | 未超限
关键词 | zh-Hans | 67 | 100 | 未超限
名称 | en-US | 10 | 30 | 未超限
副标题 | en-US | 25 | 30 | 未超限
宣传文本 | en-US | 169 | 170 | 未超限
描述 | en-US | 2555 | 4000 | 未超限
关键词 | en-US | 99 | 100 | 未超限
关键词检查 zh-Hans：通过
关键词检查 en-US：通过
禁用词检查：未发现
人工确认 zh-Hans description：…数，每日签到也能免费领取，也可以在 …
人工确认 zh-Hans description：…永不过期；签到等免费获得的点数有有效…
人工确认 en-US description：…n gives free points,…
人工确认 en-US description：…expire. Free points …
共 14 个字段，0 处问题
```
