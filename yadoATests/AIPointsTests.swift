import Foundation
import Testing
@testable import yadoA

/// 验证 AI 点数：契约解码、明细展示映射、查询请求构造、余额状态与流水分页。
@Suite("AI 点数")
@MainActor
struct AIPointsTests {
    // MARK: - 契约

    @Test("余额、流水与档位列表解码：时间带毫秒，过期流水可识别，未知流水类型兜底，不认识或不可用的档位不让选")
    func decodesBillingContract() throws {
        let walletJSON = """
        {"mode":"enforce","balance":98,"lots":[
          {"points":90,"expiresAt":"2027-01-26T02:32:00.000Z"},{"points":8,"expiresAt":"2027-02-01T00:00:00Z"}
        ],"ruleVersion":"2026-10-28.3"}
        """
        let wallet = try JSONDecoder().decode(AIWallet.self, from: Data(walletJSON.utf8))
        #expect(wallet.balance == 98)
        #expect(wallet.lots.map(\.points) == [90, 8])
        #expect(wallet.lots[0].expiresAt == Date(timeIntervalSince1970: 1_800_930_720))

        let walletWithoutLots = try JSONDecoder().decode(
            AIWallet.self,
            from: Data(#"{"mode":"enforce","balance":98,"ruleVersion":"2026-10-28.2"}"#.utf8)
        )
        #expect(walletWithoutLots.lots.isEmpty)

        let pageJSON = """
        {"entries":[
          {"id":"12","kind":"charge","points":-2,"balanceAfter":98,"feature":"yadoa.voice_session",
           "model":"qwen3.8-27b","reason":null,"createdAt":"2026-10-28T02:32:00.000Z"},
          {"id":"3","kind":"grant","points":100,"balanceAfter":100,"feature":null,"model":null,
           "reason":"initial_grant","product":"yadoa","createdAt":"2026-10-27T09:10:00Z"},
          {"id":"2","kind":"bonus_v2","points":5,"balanceAfter":0,"feature":null,"model":null,
           "reason":null,"createdAt":"2026-10-27T09:00:00.000Z"},
          {"id":"1","kind":"expire","points":-5,"balanceAfter":0,"feature":null,"model":null,
           "reason":"expired","createdAt":"2026-10-27T08:00:00.000Z"}
        ],"nextCursor":"1"}
        """
        let page = try JSONDecoder().decode(AICreditEntryPage.self, from: Data(pageJSON.utf8))
        #expect(page.nextCursor == "1")
        #expect(page.entries.map(\.kind) == [.charge, .grant, .unknown, .expire])
        #expect(page.entries[0].feature == AICreditEntry.voiceSessionFeature)
        #expect(page.entries[0].createdAt == Date(timeIntervalSince1970: 1_793_154_720))
        #expect(page.entries[1].reason == AICreditEntry.initialGrantReason)
        #expect(page.entries[1].product == "yadoa")
        #expect(page.entries[0].product == nil)
        #expect(page.entries[1].createdAt == Date(timeIntervalSince1970: 1_793_092_200))

        let lastPage = try JSONDecoder().decode(
            AICreditEntryPage.self,
            from: Data(#"{"entries":[],"nextCursor":null}"#.utf8)
        )
        #expect(lastPage.entries.isEmpty)
        #expect(lastPage.nextCursor == nil)

        let tiersJSON = """
        {"defaultTier":"standard","tiers":[
          {"id":"standard","isAvailable":true,"pointsPerTurn":1},
          {"id":"precise","isAvailable":true,"pointsPerTurn":2},
          {"id":"turbo","isAvailable":true,"pointsPerTurn":5}
        ]}
        """
        let tierList = try JSONDecoder().decode(AIModelTierList.self, from: Data(tiersJSON.utf8))
        #expect(tierList.defaultTier == "standard")
        #expect(tierList.selectableTiers == [.standard, .precise])
        #expect(tierList.pointsPerTurn(for: "precise") == 2)
        #expect(tierList.pointsPerTurn(for: "gone") == nil)

        let preciseUnavailable = AIModelTierList(defaultTier: "standard", tiers: [
            .init(id: "standard", pointsPerTurn: 1, isAvailable: true),
            .init(id: "precise", pointsPerTurn: 2, isAvailable: false),
        ])
        #expect(preciseUnavailable.selectableTiers == [.standard])
    }

    @Test("流水时间不是 ISO 8601 时整页解码失败")
    func rejectsMalformedTimestamp() {
        let json = #"{"entries":[{"id":"1","kind":"grant","points":1,"balanceAfter":1,"createdAt":"yesterday"}],"nextCursor":null}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AICreditEntryPage.self, from: Data(json.utf8))
        }
    }

    @Test("明细标题与图标：扣点按能力、赠送按原因区分，新用户赠送带来源产品名，不认识的用类型兜底")
    func mapsEntryPresentation() {
        let voice = Self.entry(kind: .charge, points: -2, feature: AICreditEntry.voiceSessionFeature)
        let otherCharge = Self.entry(kind: .charge, points: -1, feature: "yadoi.item_extract")
        let welcome = Self.entry(kind: .grant, points: 100, reason: AICreditEntry.initialGrantReason, product: "yadoa")
        let welcomeWithoutProduct = Self.entry(kind: .grant, points: 100, reason: AICreditEntry.initialGrantReason)
        let welcomeFromUnknownProduct = Self.entry(
            kind: .grant,
            points: 100,
            reason: AICreditEntry.initialGrantReason,
            product: "yadox"
        )
        let compensation = Self.entry(kind: .grant, points: 50, reason: "compensation", product: "yadoa")

        #expect(voice.titleKey == "ai.entry.voiceSession")
        #expect(voice.symbol == "mic")
        #expect(otherCharge.titleKey == "ai.entry.charge")
        #expect(otherCharge.symbol == "sparkles")
        #expect(welcome.titleKey == "ai.entry.grant.initial.product")
        #expect(welcomeWithoutProduct.titleKey == "ai.entry.grant.initial")
        #expect(welcomeFromUnknownProduct.titleKey == "ai.entry.grant.initial")
        #expect(compensation.titleKey == "ai.entry.grant")
        #expect(Self.entry(kind: .refund, points: 2).titleKey == "ai.entry.refund")
        #expect(Self.entry(kind: .adjust, points: -20).titleKey == "ai.entry.adjust")
        #expect(Self.entry(kind: .expire, points: -5, reason: "expired").titleKey == "ai.entry.expire")
        #expect(Self.entry(kind: .expire, points: -5).symbol == "hourglass")
        #expect(Self.entry(kind: .unknown, points: 1).titleKey == "ai.entry.other")

        let simplifiedChinese = Locale(identifier: "zh-Hans")
        #expect(welcome.title(locale: simplifiedChinese) == "芽豆资产新用户赠送")
        #expect(welcome.title(locale: Locale(identifier: "en")) == "Yado Asset welcome bonus")
        #expect(welcomeWithoutProduct.title(locale: simplifiedChinese) == "新用户赠送")
        #expect(welcomeFromUnknownProduct.title(locale: simplifiedChinese) == "新用户赠送")
        #expect(voice.title(locale: simplifiedChinese) == "语音记账")

        let english = Locale(identifier: "en_US")
        #expect(welcome.signedPoints(locale: english) == "+100")
        #expect(voice.signedPoints(locale: english) == "-2")
    }

    @Test("批次解码：带来源、入账点数与获得时间；存量批次没有来源；服务端没返回这些字段时为空")
    func decodesCreditLots() throws {
        let walletJSON = """
        {"mode":"enforce","balance":101,"lots":[
          {"points":92,"originalPoints":100,"kind":"grant","reason":"initial_grant","product":"yadoa",
           "createdAt":"2026-10-28T02:32:00.000Z","expiresAt":"2027-01-26T02:32:00.000Z"},
          {"points":4,"originalPoints":4,"kind":null,"reason":null,"product":null,
           "createdAt":"2026-10-27T09:10:00Z","expiresAt":"2027-01-27T00:00:00Z"},
          {"points":5,"expiresAt":"2027-02-01T00:00:00Z"}
        ],"ruleVersion":"2026-10-29.1"}
        """
        let lots = try JSONDecoder().decode(AIWallet.self, from: Data(walletJSON.utf8)).lots
        #expect(lots.count == 3)
        #expect(lots[0].originalPoints == 100)
        #expect(lots[0].kind == .grant)
        #expect(lots[0].reason == AICreditEntry.initialGrantReason)
        #expect(lots[0].product == "yadoa")
        #expect(lots[0].createdAt == Date(timeIntervalSince1970: 1_793_154_720))
        #expect(lots[0].expiresAt == Date(timeIntervalSince1970: 1_800_930_720))
        #expect(lots[1].kind == nil)
        #expect(lots[1].createdAt == Date(timeIntervalSince1970: 1_793_092_200))
        #expect(lots[2] == AICreditLot(points: 5, expiresAt: Date(timeIntervalSince1970: 1_801_440_000)))

        let badTime = #"{"balance":1,"lots":[{"points":1,"createdAt":"昨天","expiresAt":"2027-02-01T00:00:00Z"}]}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AIWallet.self, from: Data(badTime.utf8))
        }
    }

    @Test("签到状态与结果解码：状态分已签和未签，结果时间带毫秒，时间格式错误时解码失败")
    func decodesCheckInContract() throws {
        let pending = try JSONDecoder().decode(
            AICheckInStatus.self,
            from: Data(#"{"date":"2026-11-05","checkedIn":false,"checkIn":null,"minPoints":10,"maxPoints":50}"#.utf8)
        )
        #expect(pending.date == "2026-11-05")
        #expect(!pending.checkedIn)
        #expect(pending.checkIn == nil)
        #expect(pending.minPoints == 10)
        #expect(pending.maxPoints == 50)
        // 旧服务端不返回连签与礼包字段：取空值，不让解码失败
        #expect(pending.streak == 0)
        #expect(pending.validHours == nil)
        #expect(pending.firstCheckInDate == nil)
        #expect(pending.gifts.isEmpty)
        #expect(pending.giftTiers.isEmpty)
        // 旧服务端不返回补签卡：不弹窗，也不显示补签卡
        #expect(pending.protection == nil)
        #expect(pending.protectionOffer == nil)

        let doneJSON = """
        {"date":"2026-11-05","checkedIn":true,
         "checkIn":{"points":42,"createdAt":"2026-10-28T02:32:00.000Z","expiresAt":"2026-10-29T02:32:00.000Z"},
         "minPoints":10,"maxPoints":50}
        """
        let done = try JSONDecoder().decode(AICheckInStatus.self, from: Data(doneJSON.utf8))
        #expect(done.checkedIn)
        #expect(done.checkIn?.points == 42)
        #expect(done.checkIn?.createdAt == Date(timeIntervalSince1970: 1_793_154_720))

        let resultJSON = """
        {"date":"2026-11-05","points":42,"isBonus":true,"isDuplicate":false,"balance":142,
         "createdAt":"2026-10-28T02:32:00.000Z","expiresAt":"2026-10-29T02:32:00.000Z"}
        """
        let result = try JSONDecoder().decode(AICheckInResult.self, from: Data(resultJSON.utf8))
        #expect(result.points == 42)
        #expect(result.isBonus)
        #expect(!result.isDuplicate)
        #expect(result.balance == 142)
        #expect(result.createdAt == Date(timeIntervalSince1970: 1_793_154_720))
        #expect(result.expiresAt == Date(timeIntervalSince1970: 1_793_241_120))
        #expect(result.streak == 0)
        #expect(result.gifts.isEmpty)
        #expect(result.protectedDate == nil)
        #expect(result.cardsLeft == nil)
        #expect(result.keptStreak == nil)

        let badTime = """
        {"date":"2026-11-05","points":42,"isBonus":false,"isDuplicate":false,"balance":142,
         "createdAt":"yesterday","expiresAt":"2026-10-29T02:32:00.000Z"}
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AICheckInResult.self, from: Data(badTime.utf8))
        }
    }

    @Test("连签与礼包契约：解码连签天数、待开礼包、礼包规则、开礼包结果与签到日历；不认识的礼包档位兜底")
    func decodesCheckInStreakAndGiftContract() throws {
        let statusJSON = """
        {"date":"2026-11-18","checkedIn":true,
         "checkIn":{"points":12,"streak":7,"createdAt":"2026-11-18T02:32:00.000Z","expiresAt":"2026-11-19T02:32:00.000Z"},
         "minPoints":1,"maxPoints":20,"validHours":24,"streak":7,"firstCheckInDate":"2026-10-03",
         "gifts":[
           {"id":"12","tier":"weekly","streak":7,"checkInDate":"2026-11-18","totalOpens":1,"openedCount":0,
            "createdAt":"2026-11-18T02:32:00.000Z"},
           {"id":"13","tier":"decade","streak":3650,"checkInDate":"2026-11-18","totalOpens":1,"openedCount":0,
            "createdAt":"2026-11-18T02:32:00Z"}
         ],
         "giftTiers":[
           {"tier":"weekly","everyDays":7,"openings":[{"minPoints":21,"maxPoints":50}],"validDays":7},
           {"tier":"yearly","everyDays":365,
            "openings":[{"minPoints":365,"maxPoints":365},{"minPoints":100,"maxPoints":365}],"validDays":365}
         ]}
        """
        let status = try JSONDecoder().decode(AICheckInStatus.self, from: Data(statusJSON.utf8))
        #expect(status.streak == 7)
        #expect(status.checkIn?.streak == 7)
        #expect(status.validHours == 24)
        #expect(status.firstCheckInDate == "2026-10-03")
        #expect(status.gifts.map(\.tier) == [.weekly, .unknown])
        #expect(status.gifts[0].nextSeq == 1)
        #expect(!status.gifts[0].isFinished)
        #expect(status.rule(for: .yearly)?.openings.count == 2)
        #expect(status.rule(for: .monthly) == nil)

        let resultJSON = """
        {"date":"2026-11-18","points":12,"isBonus":false,"isDuplicate":false,"balance":142,"streak":7,
         "gifts":[{"id":"12","tier":"weekly","streak":7,"checkInDate":"2026-11-18","totalOpens":1,"openedCount":0,
                   "createdAt":"2026-11-18T02:32:00.000Z"}],
         "createdAt":"2026-11-18T02:32:00.000Z","expiresAt":"2026-11-19T02:32:00.000Z"}
        """
        let result = try JSONDecoder().decode(AICheckInResult.self, from: Data(resultJSON.utf8))
        #expect(result.streak == 7)
        #expect(result.newGifts.map(\.id) == ["12"])
        // 当天重复签到带回的礼包不算新得到的，免得再弹一次开礼包
        let duplicate = Self.checkInResult(points: 12, balance: 142, isDuplicate: true, streak: 7, gifts: result.gifts)
        #expect(duplicate.newGifts.isEmpty)

        let openJSON = """
        {"gift":{"id":"20","tier":"yearly","streak":365,"checkInDate":"2026-11-18","totalOpens":2,"openedCount":1,
                 "createdAt":"2026-11-18T02:32:00.000Z"},
         "seq":1,"points":365,"isDuplicate":false,"balance":465,
         "createdAt":"2026-11-18T02:40:00.000Z","expiresAt":"2027-11-18T02:40:00.000Z"}
        """
        let opened = try JSONDecoder().decode(AICheckInGiftOpenResult.self, from: Data(openJSON.utf8))
        #expect(opened.points == 365)
        #expect(opened.gift.remainingOpens == 1)
        #expect(opened.gift.nextSeq == 2)
        #expect(opened.expiresAt == Date(timeIntervalSince1970: 1_826_505_600))

        let monthJSON = """
        {"month":"2026-11","today":"2026-11-18","firstCheckInDate":"2026-10-03",
         "days":[{"date":"2026-11-01","points":5,"streak":1,"giftTiers":[]},
                 {"date":"2026-11-07","points":9,"streak":7,"giftTiers":["weekly"]}]}
        """
        let month = try JSONDecoder().decode(AICheckInMonth.self, from: Data(monthJSON.utf8))
        #expect(month.today == "2026-11-18")
        #expect(month.days.map(\.streak) == [1, 7])
        #expect(month.days[1].giftTiers == [.weekly])
        // 旧服务端不返回被补签卡保住的日子
        #expect(month.protectedDates.isEmpty)
    }

    @Test("补签卡契约：解码状态里的补签卡、签到结果的保住日子和剩余张数、日历里被保住的日子；今天能不能用卡")
    func decodesCheckInProtectionContract() throws {
        let statusJSON = """
        {"date":"2026-11-19","checkedIn":false,"checkIn":null,"minPoints":1,"maxPoints":20,"streak":23,
         "protection":{"cardsPerMonth":1,"cardsLeft":1,"pendingDate":"2026-11-18"}}
        """
        let status = try JSONDecoder().decode(AICheckInStatus.self, from: Data(statusJSON.utf8))
        #expect(status.protection == AICheckInProtection(cardsPerMonth: 1, cardsLeft: 1, pendingDate: "2026-11-18"))
        let offer = try #require(status.protectionOffer)
        #expect(offer == AICheckInProtectionOffer(missedDate: "2026-11-18", keptStreak: 23, cardsLeft: 1))
        #expect(offer.nextStreak == 24)
        // 换礼包列表时补签卡跟着保留
        #expect(status.replacingGifts([]).protection == status.protection)

        let noPending = #"{"date":"2026-11-19","checkedIn":false,"checkIn":null,"minPoints":1,"maxPoints":20,"protection":{"cardsPerMonth":1,"cardsLeft":0,"pendingDate":null}}"#
        let usedUp = try JSONDecoder().decode(AICheckInStatus.self, from: Data(noPending.utf8))
        #expect(usedUp.protection?.pendingDate == nil)
        #expect(usedUp.protection?.isEnabled == true)
        #expect(usedUp.protectionOffer == nil)

        // 服务端给了日子但卡已用完、关了补签卡，或今天已经签了，都不问
        let withoutCards = AICheckInStatus(
            date: "2026-11-19", checkedIn: false, checkIn: nil, minPoints: 1, maxPoints: 20, streak: 23,
            protection: AICheckInProtection(cardsPerMonth: 1, cardsLeft: 0, pendingDate: "2026-11-18")
        )
        #expect(withoutCards.protectionOffer == nil)
        let disabled = AICheckInStatus(
            date: "2026-11-19", checkedIn: false, checkIn: nil, minPoints: 1, maxPoints: 20, streak: 23,
            protection: AICheckInProtection(cardsPerMonth: 0, cardsLeft: 0, pendingDate: nil)
        )
        #expect(disabled.protection?.isEnabled == false)
        #expect(disabled.protectionOffer == nil)
        let checked = AICheckInStatus(
            date: "2026-11-19", checkedIn: true, checkIn: nil, minPoints: 1, maxPoints: 20, streak: 24,
            protection: AICheckInProtection(cardsPerMonth: 1, cardsLeft: 1, pendingDate: "2026-11-18")
        )
        #expect(checked.protectionOffer == nil)

        let resultJSON = """
        {"date":"2026-11-19","points":12,"isBonus":false,"isDuplicate":false,"balance":142,"streak":24,"gifts":[],
         "protectedDate":"2026-11-18","cardsLeft":0,
         "createdAt":"2026-11-19T02:32:00.000Z","expiresAt":"2026-11-20T02:32:00.000Z"}
        """
        let result = try JSONDecoder().decode(AICheckInResult.self, from: Data(resultJSON.utf8))
        #expect(result.protectedDate == "2026-11-18")
        #expect(result.cardsLeft == 0)
        #expect(result.keptStreak == 23)

        let notUsedJSON = """
        {"date":"2026-11-19","points":12,"isBonus":false,"isDuplicate":false,"balance":142,"streak":1,"gifts":[],
         "protectedDate":null,"cardsLeft":1,
         "createdAt":"2026-11-19T02:32:00.000Z","expiresAt":"2026-11-20T02:32:00.000Z"}
        """
        let notUsed = try JSONDecoder().decode(AICheckInResult.self, from: Data(notUsedJSON.utf8))
        #expect(notUsed.protectedDate == nil)
        #expect(notUsed.keptStreak == nil)
        #expect(notUsed.cardsLeft == 1)

        let monthJSON = """
        {"month":"2026-11","today":"2026-11-19","firstCheckInDate":"2026-11-12",
         "days":[{"date":"2026-11-17","points":5,"streak":6,"giftTiers":[]},
                 {"date":"2026-11-19","points":9,"streak":7,"giftTiers":["weekly"]}],
         "protectedDates":["2026-11-18"]}
        """
        let month = try JSONDecoder().decode(AICheckInMonth.self, from: Data(monthJSON.utf8))
        #expect(month.protectedDates == ["2026-11-18"])
        #expect(month.days.map(\.date) == ["2026-11-17", "2026-11-19"])

        // 签到后今天不能再用卡，剩余张数取签到结果；结果里没有时沿用原来的
        let protection = AICheckInProtection(cardsPerMonth: 1, cardsLeft: 1, pendingDate: "2026-11-18")
        #expect(protection.afterCheckIn(cardsLeft: 0) == AICheckInProtection(cardsPerMonth: 1, cardsLeft: 0, pendingDate: nil))
        #expect(protection.afterCheckIn(cardsLeft: nil) == AICheckInProtection(cardsPerMonth: 1, cardsLeft: 1, pendingDate: nil))
    }

    @Test("补签卡文案：弹窗、庆祝、签到页、日历朗读、错误与开发页都有中英文，弹窗说明按天数和张数格式化")
    func localizesCheckInProtection() {
        let english = Locale(identifier: "en")
        let simplifiedChinese = Locale(identifier: "zh-Hans")
        let keys = [
            "checkIn.protection.prompt.title", "checkIn.protection.prompt.message", "checkIn.protection.prompt.use",
            "checkIn.protection.prompt.skip", "checkIn.protection.used", "checkIn.protection.cardsLeft",
            "checkIn.protection.cardsUsedUp", "checkIn.today.protectable", "checkIn.rules.protection",
            "checkIn.calendar.day.protected", "profile.checkIn.failure.protection",
            "developer.checkIn.missedYesterday", "developer.checkIn.cardUsed",
        ]
        for key in keys {
            for locale in [english, simplifiedChinese] {
                // 缺文案时返回 key 本身
                #expect(AccountLocalization.string(key, locale: locale) != key, "\(key) 缺少 \(locale.identifier) 文案")
            }
        }
        let message = AccountLocalization.string("checkIn.protection.prompt.message", locale: simplifiedChinese)
        #expect(
            String(format: message, locale: simplifiedChinese, "24", "1")
                == "用 1 张补签卡，今天接着算第 24 天；不用的话从第 1 天重新算。本月还剩 1 张。"
        )
        #expect(
            AccountLocalization.formatted("checkIn.protection.used", value: "23", locale: simplifiedChinese)
                == "用掉 1 张补签卡，保住了 23 天连签"
        )
        #expect(ProfileCheckInBadge.failureKey(for: .checkInProtectionUnavailable) == "profile.checkIn.failure.protection")
    }

    @Test("签到礼包的明细标题、进度与文案：三档礼包各有标题，离下一个礼包的天数含今天，点数范围用加号连起来")
    func mapsCheckInGiftPresentation() {
        let english = Locale(identifier: "en")
        let simplifiedChinese = Locale(identifier: "zh-Hans")

        #expect(AICheckInGiftTier(entryReason: "check_in_gift_weekly") == .weekly)
        #expect(AICheckInGiftTier(entryReason: AICreditEntry.dailyCheckInReason) == nil)
        #expect(AICheckInGiftTier.yearly.entryReason == "check_in_gift_yearly")
        let entry = Self.entry(kind: .grant, points: 36, reason: "check_in_gift_monthly", product: "yadoa")
        #expect(entry.titleKey == "ai.entry.grant.monthlyGift")
        #expect(entry.symbol == "gift")
        let lot = AICreditLot(points: 365, expiresAt: .distantFuture, kind: .grant, reason: "check_in_gift_yearly", product: "yadoa")
        #expect(lot.titleKey == "ai.entry.grant.yearlyGift")
        #expect(!lot.isDailyCheckIn)

        let weekly = Self.weeklyRule
        #expect(weekly.daysUntilNext(streak: 0) == 7)
        #expect(weekly.daysUntilNext(streak: 6) == 1)
        // 今天刚拿到周礼包：下一个要再签满 7 天
        #expect(weekly.daysUntilNext(streak: 7) == 7)
        #expect(weekly.daysUntilNext(streak: 10) == 4)
        #expect(weekly.progress(streak: 7) == 0)
        #expect(abs(weekly.progress(streak: 3) - 3.0 / 7.0) < 0.0001)

        #expect(AccountLocalization.string("ai.entry.grant.weeklyGift", locale: simplifiedChinese) == "签到周礼包")
        #expect(AccountLocalization.string("checkIn.gift.yearly", locale: simplifiedChinese) == "年度礼包")
        #expect(AccountLocalization.formatted("checkIn.gift.earned", value: "7", locale: simplifiedChinese) == "连签 7 天获得")
        // 签到和礼包都不写具体能领多少点，只说是随机点数
        let rule = AccountLocalization.string("checkIn.milestone.rule", locale: simplifiedChinese)
        #expect(String(format: rule, locale: simplifiedChinese, "7", "7") == "每连签 7 天 · 随机点数 · 7 天有效")
        #expect(
            AccountLocalization.formatted("checkIn.guide.message", value: "24", locale: simplifiedChinese)
                == "每天点一下芽豆，领取随机 AI 点数，24 小时内有效。"
        )
        #expect(
            AccountLocalization.formatted("checkIn.rules.daily", value: "24", locale: simplifiedChinese)
                == "每天签到一次，领取随机 AI 点数，24 小时内有效。"
        )
        #expect(
            AccountLocalization.formatted("checkIn.rules.daily", value: "24", locale: english)
                == "Check in once a day for random AI points, valid for 24 hours."
        )
        let keys = [
            "checkIn.title", "checkIn.row.streak", "checkIn.row.gifts", "checkIn.streak.caption", "checkIn.today.done",
            "checkIn.today.start", "checkIn.today.continue", "checkIn.gifts.section", "checkIn.gift.weekly",
            "checkIn.gift.monthly", "checkIn.gift.yearly", "checkIn.gift.other", "checkIn.gift.open",
            "checkIn.gift.opensLeft", "checkIn.milestones.section", "checkIn.milestone.rule", "checkIn.milestone.daysLeft",
            "checkIn.milestone.today", "checkIn.milestone.tomorrow", "checkIn.calendar.section",
            "checkIn.calendar.summary", "checkIn.calendar.empty", "checkIn.calendar.failed", "checkIn.rules.daily",
            "checkIn.opening.open", "checkIn.opening.openAgain", "checkIn.opening.collect", "checkIn.opening.validUntil",
            "checkIn.opening.announcement", "checkIn.guide.title", "checkIn.guide.message", "checkIn.guide.gifts",
            "checkIn.guide.dismiss", "ai.entry.grant.monthlyGift", "ai.entry.grant.yearlyGift",
        ]
        for key in keys {
            for locale in [english, simplifiedChinese] {
                #expect(AccountLocalization.string(key, locale: locale) != key, "\(key) 缺少 \(locale.identifier) 文案")
            }
        }
    }

    @Test("每日签到的明细与批次：标题、图标、中文标题，签到批次的到期时间显示到时分")
    func mapsDailyCheckInPresentation() {
        let entry = Self.entry(kind: .grant, points: 30, reason: AICreditEntry.dailyCheckInReason, product: "yadoa")
        #expect(entry.titleKey == "ai.entry.grant.dailyCheckIn")
        #expect(entry.symbol == "calendar.badge.checkmark")
        #expect(entry.title(locale: Locale(identifier: "zh-Hans")) == "每日签到")

        let expiresAt = Date(timeIntervalSince1970: 1_793_241_120)
        let checkInLot = AICreditLot(
            points: 30,
            expiresAt: expiresAt,
            kind: .grant,
            reason: AICreditEntry.dailyCheckInReason,
            product: "yadoa"
        )
        let plainLot = AICreditLot(points: 30, expiresAt: expiresAt, kind: .grant, reason: "compensation")
        #expect(checkInLot.isDailyCheckIn)
        #expect(!plainLot.isDailyCheckIn)
        #expect(checkInLot.titleKey == "ai.entry.grant.dailyCheckIn")
        #expect(checkInLot.symbol == "calendar.badge.checkmark")
        #expect(plainLot.symbol == "gift")

        let english = Locale(identifier: "en_US")
        #expect(checkInLot.expiryText(locale: english)?.contains(":") == true)
        #expect(plainLot.expiryText(locale: english)?.contains(":") == false)
    }

    @Test("批次标题与图标和生成它的入账流水一致，存量批次显示早期点数")
    func mapsLotPresentation() {
        let expiresAt = Date(timeIntervalSince1970: 1_800_930_720)
        let welcome = AICreditLot(
            points: 92,
            expiresAt: expiresAt,
            kind: .grant,
            reason: AICreditEntry.initialGrantReason,
            product: "yadoa"
        )
        let refund = AICreditLot(points: 2, expiresAt: expiresAt, kind: .refund, reason: "compensation")
        let legacy = AICreditLot(points: 4, expiresAt: expiresAt)

        #expect(welcome.titleKey == "ai.entry.grant.initial.product")
        #expect(welcome.symbol == "gift")
        #expect(refund.titleKey == "ai.entry.refund")
        #expect(refund.symbol == "arrow.uturn.backward")
        #expect(legacy.titleKey == AICreditLot.legacyTitleKey)
        #expect(legacy.symbol == "tray")

        let simplifiedChinese = Locale(identifier: "zh-Hans")
        #expect(welcome.title(locale: simplifiedChinese) == "芽豆资产新用户赠送")
        #expect(legacy.title(locale: simplifiedChinese) == "早期点数")
        #expect(legacy.title(locale: Locale(identifier: "en")) == "Earlier points")
    }

    @Test("点数文案有中英文")
    func localizesPointsCopy() {
        let english = Locale(identifier: "en")
        let simplifiedChinese = Locale(identifier: "zh-Hans")
        #expect(AccountLocalization.string("ai.points.title", locale: english) == "AI Points")
        #expect(AccountLocalization.string("ai.points.title", locale: simplifiedChinese) == "AI 点数")
        #expect(AccountLocalization.string("ai.rules.perTurn", locale: simplifiedChinese) == "每说一句扣一次点，扣几点看这句用的模型")
        #expect(AccountLocalization.string("ai.points.exhausted", locale: simplifiedChinese) == "点数已用完，暂时无法使用 AI 记账。")
        #expect(AccountLocalization.string("ai.points.switchTier", locale: simplifiedChinese) == "余额不够当前模型每句扣的点数，切换到扣点更少的模型可继续使用。")
        let expiry = AccountLocalization.string("ai.points.expiry", locale: simplifiedChinese)
        #expect(String(format: expiry, locale: simplifiedChinese, "98", "2027年1月26日") == "98 点将于 2027年1月26日 过期")
        #expect(AccountLocalization.string("ai.entry.expire", locale: english) == "Expired")
        #expect(AccountLocalization.string("ai.lots.title", locale: simplifiedChinese) == "到期明细")
        #expect(AccountLocalization.string("ai.lots.title", locale: english) == "Expiry Details")
        #expect(AccountLocalization.formatted("ai.lots.expiresOn", value: "2027年1月26日", locale: simplifiedChinese) == "2027年1月26日 过期")
        #expect(AccountLocalization.formatted("ai.lots.receivedOn", value: "Oct 28, 2026", locale: english) == "Received Oct 28, 2026")
        #expect(AccountLocalization.formatted("ai.lots.original", value: "100", locale: simplifiedChinese) == "共 100 点")
        #expect(AccountLocalization.formatted("ai.tier.perTurn", value: "2", locale: simplifiedChinese) == "每句 2 点")
        #expect(AccountLocalization.formatted("ai.tier.perTurn", value: "2", locale: english) == "2 pts per sentence")
        #expect(AccountLocalization.formatted("ai.tier.turnsLeft", value: "49", locale: simplifiedChinese) == "余额可说 49 句")
        #expect(AccountLocalization.string("voice.turn.switchModelTier", locale: simplifiedChinese) == "换个模型")
        #expect(AccountLocalization.string("ai.tier.quickVoice.title", locale: simplifiedChinese) == "快捷语音模型")
        #expect(AccountLocalization.string("ai.tier.chat.title", locale: simplifiedChinese) == "对话模型")
        #expect(AccountLocalization.string("ai.entries.title", locale: simplifiedChinese) == "点数明细")
        #expect(AccountLocalization.string("ai.chatHistory.cleared", locale: simplifiedChinese) == "对话记录已清空")
        #expect(AccountLocalization.string("ai.entry.grant.dailyCheckIn", locale: simplifiedChinese) == "每日签到")
        #expect(AccountLocalization.string("ai.entry.grant.dailyCheckIn", locale: english) == "Daily check-in")
        #expect(AccountLocalization.string("profile.checkIn.label", locale: simplifiedChinese) == "签到")
        #expect(AccountLocalization.string("profile.checkIn.accessibilityLabel", locale: simplifiedChinese) == "每日签到，领取 AI 点数")
        let announcement = AccountLocalization.string("profile.checkIn.announcement", locale: simplifiedChinese)
        #expect(String(format: announcement, locale: simplifiedChinese, "30", "24") == "获得 30 点，24 小时内有效")
        let checkInKeys = [
            "ai.entry.grant.dailyCheckIn", "profile.checkIn.label", "profile.checkIn.accessibilityLabel",
            "profile.checkIn.gained", "profile.checkIn.announcement", "profile.checkIn.failure.network",
            "profile.checkIn.failure.unavailable", "profile.checkIn.failure.signIn", "checkIn.signIn.message",
        ]
        for key in checkInKeys {
            for locale in [english, simplifiedChinese] {
                #expect(AccountLocalization.string(key, locale: locale) != key, "\(key) 缺少 \(locale.identifier) 文案")
            }
        }
        #expect(SignInReason.checkIn.messageLocalizationKey == "checkIn.signIn.message")
        // AI 点数页的分组标题和行尾状态
        let pageKeys = [
            "ai.points.section.model", "ai.points.section.privacy",
            "ai.traceConsent.on", "ai.traceConsent.off", "ai.chatHistory.cleared",
        ]
        for key in pageKeys {
            for locale in [english, simplifiedChinese] {
                // 缺文案时返回 key 本身
                #expect(AccountLocalization.string(key, locale: locale) != key, "\(key) 缺少 \(locale.identifier) 文案")
            }
        }
    }

    @Test("快捷语音和 AI 对话的模型：每边都有标题和说明，且有中英文")
    func describesEveryModelScope() {
        let locales = [Locale(identifier: "en"), Locale(identifier: "zh-Hans")]
        for scope in AIModelScope.allCases {
            for key in [scope.titleKey, scope.scopeNoteKey] {
                for locale in locales {
                    // 缺文案时返回 key 本身
                    #expect(AccountLocalization.string(key, locale: locale) != key, "\(key) 缺少 \(locale.identifier) 文案")
                }
            }
        }
        #expect(Set(AIModelScope.allCases.map(\.storageKey)).count == AIModelScope.allCases.count)
    }

    @Test("模型选择页：每个档位都有名称、一句话特点和不重复的具体特点，且有中英文")
    func describesEveryModelTier() {
        let locales = [Locale(identifier: "en"), Locale(identifier: "zh-Hans")]
        for tier in AIModelTier.allCases {
            #expect(!tier.highlights.isEmpty, "\(tier) 缺少特点")
            #expect(Set(tier.highlights.map(\.id)).count == tier.highlights.count, "\(tier) 的特点重复")

            let keys = [tier.titleKey, tier.summaryKey] + tier.highlights.map(\.textKey)
            for key in keys {
                for locale in locales {
                    // 缺文案时返回 key 本身
                    #expect(AccountLocalization.string(key, locale: locale) != key, "\(key) 缺少 \(locale.identifier) 文案")
                }
            }
        }
        #expect(AccountLocalization.string("ai.tier.standard.summary", locale: Locale(identifier: "zh-Hans")) == "均衡之选：速度快、扣点少，日常记账够用。")
    }

    // MARK: - 接口

    @Test("查询请求的路径、产品代号、分页参数与鉴权头")
    func buildsBillingRequests() throws {
        let endpoint = try #require(URL(string: "https://example.invalid"))
        let api = AIBillingAPI(endpoint: endpoint) { "token" }

        let wallet = api.makeURLRequest(.wallet, token: "abc")
        #expect(wallet.httpMethod == "GET")
        #expect(wallet.url?.absoluteString == "https://example.invalid/v1/billing/wallet?product=yadoa")
        #expect(wallet.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
        #expect(wallet.value(forHTTPHeaderField: AppVersion.headerName) == AppVersion.current)
        #expect(wallet.timeoutInterval == AIBillingAPI.requestTimeout)

        let firstPage = api.makeURLRequest(.entries(cursor: nil, limit: 20), token: "abc")
        #expect(firstPage.url?.path() == "/v1/billing/entries")
        #expect(firstPage.url?.query() == "product=yadoa&limit=20")

        let nextPage = api.makeURLRequest(.entries(cursor: "41", limit: 20), token: "abc")
        #expect(nextPage.url?.query() == "product=yadoa&limit=20&cursor=41")

        let models = api.makeURLRequest(.models, token: "abc")
        #expect(models.url?.absoluteString == "https://example.invalid/v1/models")

        let checkInStatus = api.makeURLRequest(.checkInStatus, token: "abc")
        #expect(checkInStatus.httpMethod == "GET")
        #expect(checkInStatus.url?.absoluteString == "https://example.invalid/v1/billing/check-in?product=yadoa")
        #expect(checkInStatus.httpBody == nil)

        let checkIn = api.makeURLRequest(.checkIn(useCard: false), token: "abc")
        #expect(checkIn.httpMethod == "POST")
        #expect(checkIn.url?.absoluteString == "https://example.invalid/v1/billing/check-in")
        #expect(checkIn.url?.query() == nil)
        #expect(checkIn.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(checkIn.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
        #expect(checkIn.value(forHTTPHeaderField: AppVersion.headerName) == AppVersion.current)
        let body = try #require(checkIn.httpBody)
        let fields = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(fields.count == 2)
        #expect(fields["product"] as? String == "yadoa")
        #expect(fields["useCard"] as? Bool == false)
        // 用补签卡签到：同一个接口，请求体带 useCard
        let withCard = api.makeURLRequest(.checkIn(useCard: true), token: "abc")
        #expect(withCard.url?.absoluteString == "https://example.invalid/v1/billing/check-in")
        let withCardBody = try #require(withCard.httpBody)
        let withCardFields = try #require(try JSONSerialization.jsonObject(with: withCardBody) as? [String: Any])
        #expect(withCardFields["useCard"] as? Bool == true)
        // 钱包仍是 GET，也不带请求体
        #expect(wallet.httpMethod == "GET")
        #expect(wallet.httpBody == nil)

        let history = api.makeURLRequest(.checkInHistory(month: "2026-11"), token: "abc")
        #expect(history.httpMethod == "GET")
        #expect(history.url?.path() == "/v1/billing/check-in/history")
        #expect(history.url?.query() == "product=yadoa&month=2026-11")
        #expect(history.httpBody == nil)

        let open = api.makeURLRequest(.openCheckInGift(id: "12", seq: 2), token: "abc")
        #expect(open.httpMethod == "POST")
        #expect(open.url?.absoluteString == "https://example.invalid/v1/billing/check-in/gifts/12/open")
        #expect(open.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let openBody = try #require(open.httpBody)
        #expect(try JSONDecoder().decode([String: Int].self, from: openBody) == ["seq": 2])

        let reset = api.makeURLRequest(
            .devResetCheckIn(AICheckInResetOptions(streak: 6, missedYesterday: true, cardUsed: false)),
            token: "abc"
        )
        #expect(reset.httpMethod == "POST")
        #expect(reset.url?.absoluteString == "https://example.invalid/v1/billing/check-in/dev-reset")
        #expect(reset.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let resetBody = try #require(reset.httpBody)
        let resetFields = try #require(try JSONSerialization.jsonObject(with: resetBody) as? [String: Any])
        #expect(resetFields.count == 4)
        #expect(resetFields["product"] as? String == "yadoa")
        #expect(resetFields["streak"] as? Int == 6)
        #expect(resetFields["missedYesterday"] as? Bool == true)
        #expect(resetFields["cardUsed"] as? Bool == false)
    }

    @Test("查询接口错误状态码映射")
    func mapsBillingErrorStatusCodes() {
        #expect(AIBillingAPI.error(statusCode: 401) == .unauthorized)
        #expect(AIBillingAPI.error(statusCode: 426) == .upgradeRequired)
        #expect(AIBillingAPI.error(statusCode: 429) == .serviceUnavailable)
        #expect(AIBillingAPI.error(statusCode: 503) == .serviceUnavailable)
        #expect(AIBillingAPI.error(statusCode: 400) == .invalidContract)
        // 签到的 409 只会是补签卡用不了；开礼包的 409 仍按状态已变处理
        #expect(AIBillingAPI.error(statusCode: 409, route: .checkIn(useCard: true)) == .checkInProtectionUnavailable)
        #expect(AIBillingAPI.error(statusCode: 409, route: .openCheckInGift(id: "12", seq: 1)) == .invalidContract)
        #expect(AIBillingAPI.error(statusCode: 400, route: .checkIn(useCard: true)) == .invalidContract)
        #expect(AIBillingAPI.error(statusCode: 503, route: .checkIn(useCard: false)) == .serviceUnavailable)
    }

    @Test("语音记账响应带回余额：200 读响应头，402 读错误详情，其余不读")
    func readsBalanceFromVoiceResponses() throws {
        let url = try #require(URL(string: "https://example.invalid/v1/yadoa/voice-session/turn"))
        let charged = try #require(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["X-AI-Points-Charged": "2", "X-AI-Points-Balance": "96"]
        ))
        #expect(VoiceSessionAPI.pointsBalance(from: charged, body: Data()) == 96)

        let simulated = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:]))
        #expect(VoiceSessionAPI.pointsBalance(from: simulated, body: Data()) == nil)

        let insufficient = try #require(HTTPURLResponse(url: url, statusCode: 402, httpVersion: nil, headerFields: [:]))
        let body = Data(#"{"code":"INSUFFICIENT_POINTS","message":"点数余额不足","details":{"required":2,"balance":1}}"#.utf8)
        #expect(VoiceSessionAPI.pointsBalance(from: insufficient, body: body) == 1)

        let unavailable = try #require(HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: [:]))
        #expect(VoiceSessionAPI.pointsBalance(from: unavailable, body: body) == nil)
    }

    // MARK: - 余额状态

    @Test("刷新取到余额与档位列表，没选过档位时两边都默认用精准算每轮点数，每次刷新都重新查档位列表")
    func refreshLoadsBalanceAndPointsPerTurn() async {
        let api = FakeAIBillingAPI()
        api.walletResults = [.success(AIWallet(balance: 100)), .success(AIWallet(balance: 98))]
        let store = AIPointsStore(api: api, defaults: .isolated()) { "user-1" }
        // 还没取到档位列表时也先按精准发送
        #expect(store.requestTier(for: .quickVoice) == .precise)

        await store.refresh()
        #expect(store.balance == 100)
        #expect(store.tierList?.appDefaultTier == .precise)
        for scope in AIModelScope.allCases {
            #expect(store.selectedTier(for: scope) == nil)
            #expect(store.requestTier(for: scope) == .precise)
            #expect(store.displayTier(for: scope) == .precise)
            #expect(store.pointsPerTurn(for: scope) == 2)
            #expect(!store.isExhausted(for: scope))
        }

        await store.refresh()
        #expect(store.balance == 98)
        #expect(api.tierCalls == 2)
    }

    @Test("运行期间服务端停用所选档位：下次刷新后不再带档位；档位列表查询失败时沿用上次的")
    func refreshPicksUpTierAvailabilityChanges() async {
        let api = FakeAIBillingAPI()
        let store = AIPointsStore(api: api, defaults: .isolated()) { "user-1" }
        store.selectTier(.precise, for: .chat)
        await store.refresh()
        #expect(store.requestTier(for: .chat) == .precise)

        let preciseDisabled = AIModelTierList(defaultTier: "standard", tiers: [
            .init(id: "standard", pointsPerTurn: 1, isAvailable: true),
            .init(id: "precise", pointsPerTurn: 2, isAvailable: false),
        ])
        api.tiersResult = .success(preciseDisabled)
        await store.refresh()
        #expect(store.requestTier(for: .chat) == nil)
        #expect(store.pointsPerTurn(for: .chat) == 1)

        api.tiersResult = .failure(.network)
        await store.refresh()
        #expect(store.tierList == preciseDisabled)
        #expect(store.requestTier(for: .chat) == nil)
    }

    @Test("余额不够所用档位但够更便宜的档位时提示切换，连最便宜的档位都不够才算真正用完")
    func distinguishesSwitchTierFromExhausted() async {
        let api = FakeAIBillingAPI()
        api.walletResults = [.success(AIWallet(balance: 1))]
        let store = AIPointsStore(api: api, defaults: .isolated()) { "user-1" }
        await store.refresh()
        // 默认的精准每句 2 点，余额只够普通档
        #expect(store.isExhausted(for: .chat))
        #expect(store.canAffordCheaperTier(for: .chat))

        store.selectTier(.standard, for: .chat)
        #expect(!store.isExhausted(for: .chat))
        #expect(!store.canAffordCheaperTier(for: .chat))
        // 快捷语音仍用默认的精准，余额不够说一句
        #expect(store.isExhausted(for: .quickVoice))

        store.balanceReporter()(0)
        #expect(store.isExhausted(for: .chat))
        #expect(!store.canAffordCheaperTier(for: .chat))
    }

    @Test("帮助改进 AI：默认关闭，按账号保存，换账号不继承，未登录时不生效")
    func keepsTraceConsentPerAccount() {
        let defaults = UserDefaults.isolated()
        var userID: String? = "user-1"
        let store = AIPointsStore(api: FakeAIBillingAPI(), defaults: defaults) { userID }
        #expect(!store.isTraceConsented)

        store.setTraceConsented(true)
        #expect(store.isTraceConsented)

        userID = "user-2"
        #expect(!store.isTraceConsented)

        userID = nil
        #expect(!store.isTraceConsented)
        store.setTraceConsented(true)

        userID = "user-1"
        let reloaded = AIPointsStore(api: FakeAIBillingAPI(), defaults: defaults) { userID }
        #expect(reloaded.isTraceConsented)
        userID = "user-2"
        #expect(!reloaded.isTraceConsented)

        userID = "user-1"
        reloaded.setTraceConsented(false)
        #expect(!reloaded.isTraceConsented)
    }

    @Test("帮助改进 AI：只在 dev 环境提供，线上（Release、DebugProd）不提供")
    func offersTraceConsentOnlyInDev() {
        #expect(AuthConfig.dev.isAITraceConsentAvailable)
        #expect(!AuthConfig.prod.isAITraceConsentAvailable)
    }

    @Test("帮助改进 AI：环境不提供时，就算本机存过授权也视为未授权，请求不带 X-AI-Trace-Consent")
    func ignoresTraceConsentWhenUnavailable() throws {
        let defaults = UserDefaults.isolated()
        let userID = "user-1"
        let store = AIPointsStore(api: FakeAIBillingAPI(), defaults: defaults, isTraceConsentAvailable: true) { userID }
        store.setTraceConsented(true)
        #expect(store.isTraceConsented)

        let store2 = AIPointsStore(api: FakeAIBillingAPI(), defaults: defaults, isTraceConsentAvailable: false) { userID }
        #expect(!store2.isTraceConsented)
        #expect(defaults.stringArray(forKey: "ai.traceConsentUserIDs")?.contains("user-1") == true)
        store2.setTraceConsented(true)
        #expect(!store2.isTraceConsented)

        let endpoint = try #require(URL(string: "https://example.invalid"))
        let api = VoiceSessionAPI(endpoint: endpoint, isTraceConsented: { store2.isTraceConsented }) { "token" }
        let request = VoiceSessionTurnRequest(
            locale: "zh-Hans", capabilities: [], now: "2026-10-20T12:30:00-07:00", defaultAccountId: nil,
            accounts: [], categories: [], events: [.user(text: "午饭 28", selectedOptionId: nil)]
        )
        let trace = VoiceRequestTrace(sessionID: "S", turn: 1, request: 1)
        let urlRequest = try api.makeURLRequest(request, turnID: UUID(), tier: nil, trace: trace, token: "abc")
        #expect(urlRequest.value(forHTTPHeaderField: VoiceSessionAPI.traceConsentHeader) == nil)
        #expect(urlRequest.value(forHTTPHeaderField: AppVersion.headerName) == AppVersion.current)
    }

    @Test("AI 记账同意：默认未同意，按账号保存，换账号不继承，未登录不生效，可以撤回，和帮助改进 AI 互不影响")
    func keepsAIProcessingConsentPerAccount() {
        let defaults = UserDefaults.isolated()
        var userID: String? = "user-1"
        let store = AIPointsStore(api: FakeAIBillingAPI(), defaults: defaults) { userID }
        #expect(!store.isAIProcessingConsented)

        store.setAIProcessingConsented(true)
        #expect(store.isAIProcessingConsented)
        // 和“帮助改进 AI”互不影响
        #expect(!store.isTraceConsented)

        userID = "user-2"
        #expect(!store.isAIProcessingConsented)

        // 另一个账号打开“帮助改进 AI”，不会让它变成已同意
        store.setTraceConsented(true)
        #expect(!store.isAIProcessingConsented)

        userID = nil
        #expect(!store.isAIProcessingConsented)
        store.setAIProcessingConsented(true)

        userID = "user-2"
        #expect(!store.isAIProcessingConsented)

        // 新建一个 store 模拟重启，状态还在
        userID = "user-1"
        let reloaded = AIPointsStore(api: FakeAIBillingAPI(), defaults: defaults) { userID }
        #expect(reloaded.isAIProcessingConsented)
        userID = "user-2"
        #expect(!reloaded.isAIProcessingConsented)

        userID = "user-1"
        reloaded.setAIProcessingConsented(false)
        #expect(!reloaded.isAIProcessingConsented)
        // 撤回不动“帮助改进 AI”：user-1 没打开过
        #expect(!reloaded.isTraceConsented)
        let afterWithdraw = AIPointsStore(api: FakeAIBillingAPI(), defaults: defaults) { userID }
        #expect(!afterWithdraw.isAIProcessingConsented)
    }

    @Test("按余额各档位还能说几句：不够一句为 0，余额未知或档位不扣点时不显示")
    func countsTurnsLeftPerTier() async {
        let api = FakeAIBillingAPI()
        api.walletResults = [.success(AIWallet(balance: 5))]
        api.tiersResult = .success(AIModelTierList(defaultTier: "standard", tiers: [
            .init(id: "standard", pointsPerTurn: 0, isAvailable: true),
            .init(id: "precise", pointsPerTurn: 2, isAvailable: true),
        ]))
        let store = AIPointsStore(api: api, defaults: .isolated()) { "user-1" }
        #expect(store.turnsLeft(for: .precise) == nil)

        await store.refresh()
        #expect(store.turnsLeft(for: .precise) == 2)
        #expect(store.turnsLeft(for: .standard) == nil)

        store.balanceReporter()(1)
        #expect(store.turnsLeft(for: .precise) == 0)
    }

    @Test("选档位：快捷语音和 AI 对话分开保存在本机，每轮点数各自变化，重新创建后仍记得")
    func selectsTierPerScopeAndPersists() async {
        let api = FakeAIBillingAPI()
        api.walletResults = [.success(AIWallet(balance: 2))]
        let defaults = UserDefaults.isolated()
        let store = AIPointsStore(api: api, defaults: defaults) { "user-1" }
        await store.refresh()

        store.selectTier(.standard, for: .chat)
        #expect(store.requestTier(for: .chat) == .standard)
        #expect(store.displayTier(for: .chat) == .standard)
        #expect(store.pointsPerTurn(for: .chat) == 1)
        // 另一边不受影响，仍用默认的精准
        #expect(store.selectedTier(for: .quickVoice) == nil)
        #expect(store.requestTier(for: .quickVoice) == .precise)
        #expect(store.pointsPerTurn(for: .quickVoice) == 2)

        store.selectTier(.precise, for: .quickVoice)
        #expect(store.requestTier(for: .quickVoice) == .precise)
        #expect(store.requestTier(for: .chat) == .standard)

        store.balanceReporter()(1)
        #expect(!store.isExhausted(for: .chat))
        #expect(store.isExhausted(for: .quickVoice))

        let reopened = AIPointsStore(api: api, defaults: defaults) { "user-1" }
        #expect(reopened.selectedTier(for: .chat) == .standard)
        #expect(reopened.selectedTier(for: .quickVoice) == .precise)
        // 还没取到档位列表时先按所选档位发送
        #expect(reopened.requestTier(for: .chat) == .standard)
        #expect(reopened.pointsPerTurn(for: .chat) == nil)
    }

    @Test("所选档位服务端已停用时退回精准；精准也停用时不带档位，按服务端默认档位显示与计点")
    func unavailableSelectedTierFallsBackToDefault() async {
        let api = FakeAIBillingAPI()
        api.tiersResult = .success(AIModelTierList(defaultTier: "standard", tiers: [
            .init(id: "standard", pointsPerTurn: 1, isAvailable: false),
            .init(id: "precise", pointsPerTurn: 2, isAvailable: true),
        ]))
        let store = AIPointsStore(api: api, defaults: .isolated()) { "user-1" }
        store.selectTier(.standard, for: .quickVoice)

        await store.refresh()
        #expect(store.requestTier(for: .quickVoice) == .precise)
        #expect(store.pointsPerTurn(for: .quickVoice) == 2)

        let preciseDisabled = AIModelTierList(defaultTier: "standard", tiers: [
            .init(id: "standard", pointsPerTurn: 1, isAvailable: true),
            .init(id: "precise", pointsPerTurn: 2, isAvailable: false),
        ])
        api.tiersResult = .success(preciseDisabled)
        store.selectTier(.precise, for: .quickVoice)
        await store.refresh()
        #expect(store.selectedTier(for: .quickVoice) == .precise)
        #expect(store.requestTier(for: .quickVoice) == nil)
        #expect(store.displayTier(for: .quickVoice) == .standard)
        #expect(store.pointsPerTurn(for: .quickVoice) == 1)
        // 没选过的一边也一样，“默认”标记落到服务端的默认档位上
        #expect(store.requestTier(for: .chat) == nil)
        #expect(store.displayTier(for: .chat) == .standard)
        #expect(preciseDisabled.appDefaultTier == .standard)
    }

    @Test("刷新失败保留已有余额，未登录时清空余额")
    func refreshFailureKeepsBalanceAndSignOutClears() async {
        let api = FakeAIBillingAPI()
        api.walletResults = [.success(AIWallet(balance: 50)), .failure(.timeout)]
        var userID: String? = "user-1"
        let store = AIPointsStore(api: api, defaults: .isolated()) { userID }

        await store.refresh()
        await store.refresh()
        #expect(store.balance == 50)
        #expect(store.failure == .timeout)

        userID = nil
        await store.refresh()
        #expect(store.balance == nil)
        #expect(store.failure == nil)
        // 档位列表与账号无关，退出登录后保留
        #expect(store.pointsPerTurn(for: .quickVoice) == 2)
    }

    @Test("语音记账带回的余额就地更新；换账号后不展示旧账号余额")
    func reportsBalanceAndClearsOnAccountSwitch() async {
        let api = FakeAIBillingAPI()
        api.walletResults = [.success(AIWallet(balance: 10))]
        var userID: String? = "user-1"
        let store = AIPointsStore(api: api, defaults: .isolated()) { userID }

        await store.refresh()
        store.balanceReporter()(0)
        #expect(store.balance == 0)
        #expect(store.isExhausted(for: .quickVoice))

        userID = "user-2"
        api.walletResults = [.failure(.network)]
        await store.refresh()
        #expect(store.balance == nil)
        #expect(!store.isExhausted(for: .quickVoice))

        userID = nil
        store.balanceReporter()(5)
        #expect(store.balance == nil)
    }

    @Test("语音请求期间换了账号或退出登录，带回的余额丢弃")
    func dropsBalanceReportedForPreviousAccount() async {
        let api = FakeAIBillingAPI()
        api.walletResults = [.success(AIWallet(balance: 80))]
        var userID: String? = "user-1"
        let store = AIPointsStore(api: api, defaults: .isolated()) { userID }

        let reportForUser1 = store.balanceReporter()
        userID = "user-2"
        await store.refresh()
        reportForUser1(3)
        #expect(store.balance == 80)

        let reportBeforeSignOut = store.balanceReporter()
        userID = nil
        await store.refresh()
        reportBeforeSignOut(3)
        #expect(store.balance == nil)
    }

    @Test("刷新进行中换了账号：新账号另起一次请求，旧账号结果丢弃；退出登录立即清空")
    func refreshInFlightDoesNotLeakAcrossAccounts() async {
        let api = FakeAIBillingAPI()
        let gate = AsyncSaveGate()
        api.walletGate = gate
        api.walletResults = [.success(AIWallet(balance: 100)), .success(AIWallet(balance: 7))]
        var userID: String? = "user-1"
        let store = AIPointsStore(api: api, defaults: .isolated()) { userID }

        let user1Refresh = Task { await store.refresh() }
        while !gate.hasStarted {
            await Task.yield()
        }
        // 第一个账号的查询已挂起；去掉闸门，新账号的查询直接返回
        api.walletGate = nil

        userID = "user-2"
        await store.refresh()
        #expect(api.walletCalls == 2)
        #expect(store.balance == 7)

        gate.resume()
        await user1Refresh.value
        #expect(store.balance == 7)

        userID = nil
        await store.refresh()
        #expect(store.balance == nil)
    }

    @Test("刷新进行中语音回报了更新的余额，晚到的刷新不再覆盖余额和批次")
    func staleRefreshDoesNotOverwriteReportedBalance() async {
        let soon = Date(timeIntervalSince1970: 1_800_930_720)
        let later = soon.addingTimeInterval(86_400)
        let lots = [AICreditLot(points: 3, expiresAt: soon), AICreditLot(points: 10, expiresAt: later)]
        let api = FakeAIBillingAPI()
        api.walletResults = [.success(AIWallet(balance: 13, lots: lots))]
        let store = AIPointsStore(api: api, defaults: .isolated()) { "user-1" }
        await store.refresh()

        let gate = AsyncSaveGate()
        api.walletGate = gate
        api.walletResults.append(.success(AIWallet(balance: 13, lots: lots)))
        let refresh = Task { await store.refresh() }
        while !gate.hasStarted {
            await Task.yield()
        }

        store.balanceReporter()(11)
        #expect(store.balance == 11)
        let deducted = [AICreditLot(points: 1, expiresAt: soon), AICreditLot(points: 10, expiresAt: later)]
        #expect(store.lots == deducted)

        gate.resume()
        await refresh.value
        #expect(store.balance == 11)
        #expect(store.lots == deducted)
        #expect(store.failure == nil)
    }

    @Test("语音请求期间完成的刷新读的是扣点前的余额，语音回报随后回来时照常覆盖")
    func reportAfterRefreshDuringRequestOverwritesRefresh() async {
        let api = FakeAIBillingAPI()
        api.walletResults = [.success(AIWallet(balance: 40))]
        let store = AIPointsStore(api: api, defaults: .isolated()) { "user-1" }

        let report = store.balanceReporter()
        await store.refresh()
        #expect(store.balance == 40)
        report(38)
        #expect(store.balance == 38)

        // 回报之后才发起的刷新仍可覆盖
        api.walletResults = [.success(AIWallet(balance: 30))]
        await store.refresh()
        #expect(store.balance == 30)
    }

    @Test("不知道每轮点数时按 1 点判断是否用完")
    func exhaustedFallsBackToOnePoint() {
        let api = FakeAIBillingAPI()
        let store = AIPointsStore(api: api, defaults: .isolated()) { "user-1" }

        store.balanceReporter()(1)
        #expect(!store.isExhausted(for: .quickVoice))
        store.balanceReporter()(0)
        #expect(store.isExhausted(for: .quickVoice))
    }

    @Test("最近过期的一批：扣点先扣最早过期的批次，已到期的批次不算")
    func tracksNextExpiringLot() async {
        let soon = Date(timeIntervalSince1970: 1_800_930_720)
        let later = soon.addingTimeInterval(86_400 * 30)
        let api = FakeAIBillingAPI()
        api.walletResults = [.success(AIWallet(
            balance: 13,
            lots: [AICreditLot(points: 3, expiresAt: soon), AICreditLot(points: 10, expiresAt: later)]
        ))]
        let store = AIPointsStore(api: api, defaults: .isolated()) { "user-1" }
        let now = soon.addingTimeInterval(-86_400)

        await store.refresh()
        #expect(store.nextExpiringLot(now: now) == AICreditLot(points: 3, expiresAt: soon))

        store.balanceReporter()(11)
        #expect(store.lots == [AICreditLot(points: 1, expiresAt: soon), AICreditLot(points: 10, expiresAt: later)])

        store.balanceReporter()(9)
        #expect(store.nextExpiringLot(now: now) == AICreditLot(points: 9, expiresAt: later))
        #expect(store.nextExpiringLot(now: later) == nil)

        store.balanceReporter()(0)
        #expect(store.nextExpiringLot(now: now) == nil)
    }

    @Test("到期明细：只列有剩余且未到期的批次；语音扣点后批次保留来源与入账信息")
    func listsActiveLotsKeepingSource() async {
        let soon = Date(timeIntervalSince1970: 1_800_930_720)
        let later = soon.addingTimeInterval(86_400 * 30)
        let createdAt = soon.addingTimeInterval(-86_400 * 90)
        let welcome = AICreditLot(
            points: 3,
            expiresAt: soon,
            originalPoints: 100,
            kind: .grant,
            reason: AICreditEntry.initialGrantReason,
            product: "yadoa",
            createdAt: createdAt
        )
        let refund = AICreditLot(points: 10, expiresAt: later, originalPoints: 10, kind: .refund, createdAt: createdAt)
        let api = FakeAIBillingAPI()
        api.walletResults = [.success(AIWallet(balance: 13, lots: [welcome, refund]))]
        let store = AIPointsStore(api: api, defaults: .isolated()) { "user-1" }
        let now = soon.addingTimeInterval(-86_400)

        #expect(store.activeLots(now: now).isEmpty)
        await store.refresh()
        #expect(store.activeLots(now: now) == [welcome, refund])
        #expect(store.activeLots(now: soon) == [refund])

        store.balanceReporter()(11)
        let deducted = store.activeLots(now: now)
        #expect(deducted == [welcome.withPoints(1), refund])
        #expect(deducted.first?.originalPoints == 100)
        #expect(deducted.first?.kind == .grant)
        #expect(deducted.first?.product == "yadoa")
        #expect(deducted.first?.createdAt == createdAt)

        store.balanceReporter()(0)
        #expect(store.activeLots(now: now).isEmpty)
    }

    @Test("买来的点数永不过期：批次解码出空的到期时间，排在最后、最后才扣，不算最近过期的一批")
    func handlesNeverExpiringPurchasedLots() async throws {
        let walletJSON = """
        {"mode":"enforce","balance":305,"lots":[
          {"points":5,"originalPoints":12,"kind":"grant","reason":"daily_check_in","product":"yadoa",
           "createdAt":"2026-11-21T02:00:00.000Z","expiresAt":"2026-11-22T02:00:00.000Z"},
          {"points":300,"originalPoints":300,"kind":"purchase","reason":"app_store_purchase","product":"yadoa",
           "createdAt":"2026-11-21T03:00:00.000Z","expiresAt":null}
        ],"ruleVersion":"2026-11-22.1"}
        """
        let wallet = try JSONDecoder().decode(AIWallet.self, from: Data(walletJSON.utf8))
        let purchased = try #require(wallet.lots.last)
        #expect(purchased.expiresAt == nil)
        #expect(purchased.kind == .purchase)
        #expect(purchased.titleKey == "ai.entry.purchase")
        #expect(purchased.symbol == "cart")
        #expect(purchased.expiryText(locale: Locale(identifier: "en_US")) == nil)

        let api = FakeAIBillingAPI()
        api.walletResults = [.success(wallet)]
        let store = AIPointsStore(api: api, defaults: .isolated()) { "user-1" }
        let now = Date(timeIntervalSince1970: 1_795_233_600)  // 2026-11-21T04:00:00Z，签到点数还没过期
        await store.refresh()
        #expect(store.activeLots(now: now).map(\.points) == [5, 300])
        #expect(store.nextExpiringLot(now: now)?.points == 5)

        // 签到点数过期后，只剩永不过期的批次：仍在到期明细里，但没有“最近过期”的提示
        let afterExpiry = now.addingTimeInterval(86_400)
        #expect(store.activeLots(now: afterExpiry).map(\.points) == [300])
        #expect(store.nextExpiringLot(now: afterExpiry) == nil)

        // 语音扣点先扣会过期的那批，买来的点数最后才动
        store.balanceReporter()(301)
        #expect(store.lots.map(\.points) == [1, 300])
        store.balanceReporter()(250)
        #expect(store.lots.map(\.points) == [250])
        #expect(store.lots.first?.expiresAt == nil)
    }

    @Test("购买相关的明细：购买、退款扣回、退款撤销各有标题与图标，不认识的调整仍是“调整”")
    func mapsPurchaseEntries() {
        let date = Date(timeIntervalSince1970: 1_795_320_000)
        let purchase = AICreditEntry(
            id: "9", kind: .purchase, points: 300, balanceAfter: 305, reason: "app_store_purchase", product: "yadoa", createdAt: date
        )
        #expect(purchase.titleKey == "ai.entry.purchase")
        #expect(purchase.symbol == "cart")
        let refund = AICreditEntry(
            id: "10", kind: .adjust, points: -200, balanceAfter: 105, reason: AICreditEntry.purchaseRefundReason, createdAt: date
        )
        #expect(refund.titleKey == "ai.entry.purchaseRefund")
        #expect(refund.symbol == "cart")
        let reversed = AICreditEntry(
            id: "11", kind: .adjust, points: 200, balanceAfter: 305, reason: AICreditEntry.purchaseRefundReversedReason, createdAt: date
        )
        #expect(reversed.titleKey == "ai.entry.purchaseRefundReversed")
        let manual = AICreditEntry(id: "12", kind: .adjust, points: 5, balanceAfter: 310, reason: "compensation", createdAt: date)
        #expect(manual.titleKey == "ai.entry.adjust")
        #expect(manual.symbol == "slider.horizontal.3")

        let english = Locale(identifier: "en")
        let simplifiedChinese = Locale(identifier: "zh-Hans")
        #expect(AccountLocalization.string("ai.entry.purchase", locale: simplifiedChinese) == "购买点数")
        #expect(AccountLocalization.string("ai.lots.neverExpires", locale: simplifiedChinese) == "永久有效")
        #expect(AccountLocalization.formatted("ai.store.points", value: "300", locale: simplifiedChinese) == "300 点")
        #expect(AccountLocalization.formatted("ai.store.points", value: "300", locale: english) == "300 points")
        #expect(
            AccountLocalization.formatted("ai.store.notice.credited.message", value: "1,000", locale: english)
                == "1,000 points have been added to your balance."
        )
        let storeKeys = [
            "ai.entry.purchase", "ai.entry.purchaseRefund", "ai.entry.purchaseRefundReversed", "ai.lots.neverExpires",
            "ai.store.title", "ai.store.points", "ai.store.badge.popular", "ai.store.badge.bestValue", "ai.store.footnote",
            "ai.store.purchase.hint", "ai.store.period", "ai.store.subscription.terms", "ai.store.manageSubscriptions",
            "ai.store.restore", "ai.store.notice.credited.title", "ai.store.notice.credited.message",
            "ai.store.notice.pending.title", "ai.store.notice.pending.message", "ai.store.notice.delayed.title",
            "ai.store.notice.delayed.message", "ai.store.notice.otherAccount.title", "ai.store.notice.otherAccount.message",
            "ai.store.notice.cannotCredit.title", "ai.store.notice.cannotCredit.message",
            "ai.store.notice.failed.title", "ai.store.notice.failed.message",
            "ai.store.promotion.starter", "ai.store.promotion.bonus", "ai.store.promotion.bonusPoints",
            "ai.store.promotion.daysLeft", "ai.store.promotion.endsOn", "voice.failure.insufficientPoints.starterHint",
        ]
        for key in storeKeys {
            for locale in [english, simplifiedChinese] {
                #expect(AccountLocalization.string(key, locale: locale) != key, "\(key) 缺少 \(locale.identifier) 文案")
            }
        }
    }

    @Test("充值请求：商品列表带产品代号和商店地区，上传交易是 POST 并带产品代号和签名交易")
    func buildsStoreRequests() throws {
        let endpoint = try #require(URL(string: "https://example.invalid"))
        let api = AIBillingAPI(endpoint: endpoint) { "token" }

        let catalog = api.makeURLRequest(.storeCatalog(storefront: nil), token: "abc")
        #expect(catalog.httpMethod == "GET")
        #expect(catalog.url?.absoluteString == "https://example.invalid/v1/store/catalog?product=yadoa")
        #expect(catalog.httpBody == nil)

        // 取到商店地区时才带上 storefront；空字符串等同于没有
        let regional = api.makeURLRequest(.storeCatalog(storefront: "CHN"), token: "abc")
        #expect(regional.url?.absoluteString == "https://example.invalid/v1/store/catalog?product=yadoa&storefront=CHN")
        let empty = api.makeURLRequest(.storeCatalog(storefront: ""), token: "abc")
        #expect(empty.url?.absoluteString == "https://example.invalid/v1/store/catalog?product=yadoa")

        let purchase = api.makeURLRequest(.submitPurchase(signedTransaction: "jws.payload.sig"), token: "abc")
        #expect(purchase.httpMethod == "POST")
        #expect(purchase.url?.absoluteString == "https://example.invalid/v1/store/purchases")
        #expect(purchase.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(purchase.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
        let body = try #require(purchase.httpBody)
        let fields = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(fields.count == 2)
        #expect(fields["product"] as? String == "yadoa")
        #expect(fields["signedTransaction"] as? String == "jws.payload.sig")
    }

    @Test("同时发起的刷新共用一次请求")
    func concurrentRefreshesShareOneRequest() async {
        let api = FakeAIBillingAPI()
        let gate = AsyncSaveGate()
        api.walletGate = gate
        api.walletResults = [.success(AIWallet(balance: 100))]
        let store = AIPointsStore(api: api, defaults: .isolated()) { "user-1" }

        let first = Task { await store.refresh() }
        while !gate.hasStarted {
            await Task.yield()
        }
        // 第一次查询已挂起；去掉闸门，第二次若真的再发请求只会让断言失败，不会卡住用例
        api.walletGate = nil
        #expect(store.isRefreshing)

        let second = Task { await store.refresh() }
        for _ in 0..<5 {
            await Task.yield()
        }
        gate.resume()
        await first.value
        await second.value

        #expect(api.walletCalls == 1)
        #expect(store.balance == 100)
        #expect(!store.isRefreshing)
    }

    // MARK: - 流水分页

    @Test("流水分页：第一页替换，下一页追加并按 ID 去重，最后一页后不再加载")
    func feedPaginates() async {
        let api = FakeAIBillingAPI()
        api.entryPages = [
            nil: .success(AICreditEntryPage(entries: [Self.entry(id: "5"), Self.entry(id: "4")], nextCursor: "4")),
            "4": .success(AICreditEntryPage(entries: [Self.entry(id: "4"), Self.entry(id: "3")], nextCursor: nil)),
        ]
        let feed = AICreditEntryFeed(api: api)
        #expect(!feed.hasMore)

        await feed.reload()
        #expect(feed.entries.map(\.id) == ["5", "4"])
        #expect(feed.hasLoaded)
        #expect(feed.hasMore)

        await feed.loadMore()
        #expect(feed.entries.map(\.id) == ["5", "4", "3"])
        #expect(!feed.hasMore)

        await feed.loadMore()
        #expect(api.requestedCursors == [nil, "4"])

        await feed.reload()
        #expect(feed.entries.map(\.id) == ["5", "4"])
    }

    @Test("流水加载失败：第一页失败可重试，下一页失败后不自动加载、重试时接着加载")
    func feedRetriesAfterFailure() async {
        let api = FakeAIBillingAPI()
        api.entryPages = [nil: .failure(.network)]
        let feed = AICreditEntryFeed(api: api)

        await feed.reload()
        #expect(feed.failure == .network)
        #expect(!feed.hasLoaded)

        api.entryPages = [
            nil: .success(AICreditEntryPage(entries: [Self.entry(id: "2")], nextCursor: "2")),
            "2": .failure(.timeout),
        ]
        await feed.retry()
        #expect(feed.entries.map(\.id) == ["2"])
        #expect(feed.failure == nil)

        await feed.loadMore()
        #expect(feed.failure == .timeout)
        await feed.loadMore()
        #expect(api.requestedCursors == [nil, nil, "2"])

        api.entryPages["2"] = .success(AICreditEntryPage(entries: [Self.entry(id: "1")], nextCursor: nil))
        await feed.retry()
        #expect(feed.entries.map(\.id) == ["2", "1"])
        #expect(feed.failure == nil)
        #expect(!feed.hasMore)
    }

    @Test("下拉刷新失败后重试：重新加载第一页，不去拉下一页")
    func feedRetryAfterRefreshFailureReloadsFirstPage() async {
        let api = FakeAIBillingAPI()
        api.entryPages = [
            nil: .success(AICreditEntryPage(entries: [Self.entry(id: "5")], nextCursor: "5")),
            "5": .success(AICreditEntryPage(entries: [Self.entry(id: "4")], nextCursor: nil)),
        ]
        let feed = AICreditEntryFeed(api: api)
        await feed.reload()

        api.entryPages[nil] = .failure(.timeout)
        await feed.reload()
        #expect(feed.failure == .timeout)
        #expect(feed.entries.map(\.id) == ["5"])

        api.entryPages[nil] = .success(AICreditEntryPage(entries: [Self.entry(id: "6"), Self.entry(id: "5")], nextCursor: "5"))
        await feed.retry()
        #expect(feed.failure == nil)
        #expect(feed.entries.map(\.id) == ["6", "5"])
        #expect(api.requestedCursors == [nil, nil, nil])
    }

    @Test("流水第一页为空时已加载且没有更多")
    func feedHandlesEmptyHistory() async {
        let api = FakeAIBillingAPI()
        api.entryPages = [nil: .success(AICreditEntryPage(entries: [], nextCursor: nil))]
        let feed = AICreditEntryFeed(api: api)

        await feed.reload()
        #expect(feed.hasLoaded)
        #expect(feed.entries.isEmpty)
        #expect(!feed.hasMore)
    }

    // MARK: - 每日签到

    @Test("签到成功：余额用返回值，签到批次按过期时间插入，状态变为已签")
    func checkInSucceeds() async {
        let api = FakeAIBillingAPI()
        let later = Date(timeIntervalSince1970: 1_900_000_000)
        api.walletResults = [.success(AIWallet(balance: 100, lots: [AICreditLot(points: 100, expiresAt: later)]))]
        api.checkInStatusResults = [.success(Self.pendingCheckInStatus)]
        let store = AIPointsStore(api: api, defaults: .isolated()) { "user-1" }
        await store.refresh()
        await store.refreshCheckInStatus()
        #expect(store.shouldOfferCheckIn)

        let result = Self.checkInResult(points: 42, balance: 142, isDuplicate: false)
        api.checkInResult = .success(result)
        let outcome = await store.checkIn()

        #expect(outcome == .success(result))
        #expect(store.balance == 142)
        #expect(store.lots.count == 2)
        #expect(store.lots.first?.reason == AICreditEntry.dailyCheckInReason)
        #expect(store.lots.compactMap(\.expiresAt) == store.lots.compactMap(\.expiresAt).sorted())
        #expect(store.checkInStatus?.checkedIn == true)
        #expect(store.checkInStatus?.checkIn?.points == 42)
        #expect(store.checkInStatus?.minPoints == 10)
        #expect(!store.shouldOfferCheckIn)
        #expect(!store.isCheckingIn)
        #expect(api.checkInCalls == 1)
        // 不传时不用补签卡
        #expect(api.checkInRequests == [false])
        #expect(api.walletCalls == 1)
    }

    @Test("重复签到：不追加批次，重新拉一次钱包，状态为已签")
    func checkInDuplicateRefreshesWallet() async {
        let api = FakeAIBillingAPI()
        api.walletResults = [.success(AIWallet(balance: 142))]
        api.checkInStatusResults = [.success(Self.pendingCheckInStatus)]
        let store = AIPointsStore(api: api, defaults: .isolated()) { "user-1" }
        await store.refresh()
        await store.refreshCheckInStatus()
        #expect(api.walletCalls == 1)

        api.checkInResult = .success(Self.checkInResult(points: 42, balance: 142, isDuplicate: true))
        _ = await store.checkIn()

        #expect(store.lots.isEmpty)
        #expect(api.walletCalls == 2)
        #expect(store.balance == 142)
        #expect(store.checkInStatus?.checkedIn == true)
        #expect(!store.shouldOfferCheckIn)
    }

    @Test("签到失败：余额和批次不变，返回对应错误，仍可签到")
    func checkInFailureKeepsState() async {
        let api = FakeAIBillingAPI()
        api.walletResults = [.success(AIWallet(balance: 100, lots: [AICreditLot(points: 100, expiresAt: .distantFuture)]))]
        api.checkInStatusResults = [.success(Self.pendingCheckInStatus)]
        let store = AIPointsStore(api: api, defaults: .isolated()) { "user-1" }
        await store.refresh()
        await store.refreshCheckInStatus()

        api.checkInResult = .failure(.network)
        let outcome = await store.checkIn()

        #expect(outcome == .failure(.network))
        #expect(store.balance == 100)
        #expect(store.lots.count == 1)
        #expect(store.shouldOfferCheckIn)
        #expect(!store.isCheckingIn)
    }

    @Test("签到状态：没拿到过时刷新失败为 nil，拿到过后刷新失败保留上一次的，未登录为 nil，换账号后清空")
    func checkInStatusLifecycle() async {
        let api = FakeAIBillingAPI()
        var userID: String? = "user-1"
        let store = AIPointsStore(api: api, defaults: .isolated()) { userID }

        api.checkInStatusResults = [.failure(.network)]
        await store.refreshCheckInStatus()
        #expect(store.checkInStatus == nil)
        #expect(!store.shouldOfferCheckIn)

        api.checkInStatusResults = [.success(Self.pendingCheckInStatus)]
        await store.refreshCheckInStatus()
        #expect(store.shouldOfferCheckIn)

        // 拿到过之后一次网络抖动：保留上一次的状态，签到页不整页清空
        api.checkInStatusResults = [.failure(.network)]
        await store.refreshCheckInStatus()
        #expect(store.checkInStatus == Self.pendingCheckInStatus)
        #expect(store.shouldOfferCheckIn)

        // 换账号：刷新余额时发现账号变了，先清空旧账号的状态
        userID = "user-2"
        await store.refresh()
        #expect(store.checkInStatus == nil)

        userID = nil
        await store.refreshCheckInStatus()
        #expect(store.checkInStatus == nil)
        #expect(await store.checkIn() == .failure(.notSignedIn))
    }

    @Test("签到得到礼包：连签天数用返回值，礼包追加到待开列表，规则和首签日期沿用之前的状态，重复签到不重复追加、以返回的打开次数为准")
    func checkInAddsEarnedGifts() async {
        let api = FakeAIBillingAPI()
        api.walletResults = [.success(AIWallet(balance: 100))]
        api.checkInStatusResults = [.success(Self.pendingStatus(streak: 6))]
        let store = AIPointsStore(api: api, defaults: .isolated()) { "user-1" }
        await store.refresh()
        await store.refreshCheckInStatus()

        let gift = Self.gift(id: "12", tier: .weekly, streak: 7)
        api.checkInResult = .success(Self.checkInResult(points: 12, balance: 112, isDuplicate: false, streak: 7, gifts: [gift]))
        let outcome = await store.checkIn()

        #expect((try? outcome.get())?.newGifts == [gift])
        #expect(store.checkInStatus?.streak == 7)
        #expect(store.checkInStatus?.checkIn?.streak == 7)
        #expect(store.checkInStatus?.giftTiers == Self.giftRules)
        #expect(store.checkInStatus?.firstCheckInDate == "2026-10-01")
        #expect(store.checkInStatus?.validHours == 24)
        #expect(store.unopenedGifts == [gift])

        api.checkInResult = .success(Self.checkInResult(points: 12, balance: 112, isDuplicate: true, streak: 7, gifts: [gift]))
        _ = await store.checkIn()
        #expect(store.unopenedGifts == [gift])

        // 当天重复签到带回的礼包以返回的为准：已在别的设备上开完的从待开列表移除
        let openedElsewhere = Self.gift(id: "12", tier: .weekly, streak: 7, openedCount: 1)
        api.checkInResult = .success(
            Self.checkInResult(points: 12, balance: 142, isDuplicate: true, streak: 7, gifts: [openedElsewhere])
        )
        _ = await store.checkIn()
        #expect(store.unopenedGifts.isEmpty)
    }

    @Test("刷新签到状态进行中用户签到了：晚到的刷新结果是签到之前的，不能把已签状态和新礼包盖回去")
    func staleCheckInStatusRefreshDoesNotOverwriteCheckIn() async {
        let api = FakeAIBillingAPI()
        api.walletResults = [.success(AIWallet(balance: 100))]
        api.checkInStatusResults = [.success(Self.pendingStatus(streak: 6))]
        let store = AIPointsStore(api: api, defaults: .isolated()) { "user-1" }
        await store.refresh()
        await store.refreshCheckInStatus()
        #expect(store.checkInStatus?.checkedIn == false)

        // 再发起一次刷新并挂起，它拿到的仍是“今天未签”的旧状态
        let gate = AsyncSaveGate()
        api.checkInStatusGate = gate
        let staleRefresh = Task { await store.refreshCheckInStatus() }
        while !gate.hasStarted {
            await Task.yield()
        }

        // 刷新挂起期间用户签到成功，得到一个新礼包
        let gift = Self.gift(id: "12", tier: .weekly, streak: 7)
        api.checkInResult = .success(Self.checkInResult(points: 12, balance: 112, isDuplicate: false, streak: 7, gifts: [gift]))
        _ = await store.checkIn()
        #expect(store.checkInStatus?.checkedIn == true)

        gate.resume()
        await staleRefresh.value
        #expect(store.checkInStatus?.checkedIn == true)
        #expect(store.unopenedGifts == [gift])
    }

    @Test("用补签卡签到：请求带 useCard，连签取返回值，补签卡换成剩余张数、今天不能再用；不用卡时卡留着")
    func checkInWithProtectionCard() async {
        let api = FakeAIBillingAPI()
        api.walletResults = [.success(AIWallet(balance: 100))]
        let protection = AICheckInProtection(cardsPerMonth: 1, cardsLeft: 1, pendingDate: "2026-11-17")
        api.checkInStatusResults = [.success(Self.pendingStatus(streak: 6, protection: protection))]
        let store = AIPointsStore(api: api, defaults: .isolated()) { "user-1" }
        await store.refresh()
        await store.refreshCheckInStatus()
        #expect(store.checkInStatus?.protectionOffer == AICheckInProtectionOffer(missedDate: "2026-11-17", keptStreak: 6, cardsLeft: 1))

        let gift = Self.gift(id: "12", tier: .weekly, streak: 7)
        api.checkInResult = .success(
            Self.checkInResult(
                points: 12, balance: 112, isDuplicate: false, streak: 7, gifts: [gift],
                protectedDate: "2026-11-17", cardsLeft: 0
            )
        )
        let outcome = await store.checkIn(useCard: true)

        #expect((try? outcome.get())?.keptStreak == 6)
        #expect(api.checkInRequests == [true])
        #expect(store.balance == 112)
        #expect(store.checkInStatus?.streak == 7)
        #expect(store.checkInStatus?.protection == AICheckInProtection(cardsPerMonth: 1, cardsLeft: 0, pendingDate: nil))
        #expect(store.checkInStatus?.protectionOffer == nil)
        #expect(store.unopenedGifts == [gift])

        // 不用卡：连签从 1 算，卡留着，今天也不能再用
        let other = FakeAIBillingAPI()
        other.walletResults = [.success(AIWallet(balance: 100))]
        other.checkInStatusResults = [.success(Self.pendingStatus(streak: 6, protection: protection))]
        let skipping = AIPointsStore(api: other, defaults: .isolated()) { "user-1" }
        await skipping.refresh()
        await skipping.refreshCheckInStatus()
        other.checkInResult = .success(Self.checkInResult(points: 5, balance: 105, isDuplicate: false, streak: 1, cardsLeft: 1))
        _ = await skipping.checkIn(useCard: false)
        #expect(other.checkInRequests == [false])
        #expect(skipping.checkInStatus?.streak == 1)
        #expect(skipping.checkInStatus?.protection == AICheckInProtection(cardsPerMonth: 1, cardsLeft: 1, pendingDate: nil))
        #expect(skipping.checkInStatus?.protectionOffer == nil)
    }

    @Test("补签卡用不了（409）：没有签到，余额和批次不变，重拉签到状态按最新情况显示；网络错误不重拉")
    func checkInProtectionUnavailableRefreshesStatus() async {
        let api = FakeAIBillingAPI()
        let later = Date(timeIntervalSince1970: 1_900_000_000)
        api.walletResults = [.success(AIWallet(balance: 100, lots: [AICreditLot(points: 100, expiresAt: later)]))]
        let protection = AICheckInProtection(cardsPerMonth: 1, cardsLeft: 1, pendingDate: "2026-11-17")
        // 第二次查询：已跨过零点，连漏两天，卡用不上了
        let refreshed = Self.pendingStatus(streak: 0, protection: AICheckInProtection(cardsPerMonth: 1, cardsLeft: 1, pendingDate: nil))
        api.checkInStatusResults = [.success(Self.pendingStatus(streak: 6, protection: protection)), .success(refreshed)]
        let store = AIPointsStore(api: api, defaults: .isolated()) { "user-1" }
        await store.refresh()
        await store.refreshCheckInStatus()

        api.checkInResult = .failure(.network)
        #expect(await store.checkIn(useCard: true) == .failure(.network))
        #expect(api.checkInStatusCalls == 1)
        #expect(store.checkInStatus?.protectionOffer != nil)

        api.checkInResult = .failure(.checkInProtectionUnavailable)
        #expect(await store.checkIn(useCard: true) == .failure(.checkInProtectionUnavailable))
        #expect(api.checkInRequests == [true, true])
        #expect(api.checkInStatusCalls == 2)
        #expect(store.checkInStatus == refreshed)
        #expect(store.checkInStatus?.protectionOffer == nil)
        #expect(store.shouldOfferCheckIn)
        #expect(store.balance == 100)
        #expect(store.lots.count == 1)
        #expect(!store.isCheckingIn)
    }

    @Test("打开年度礼包：第一次后礼包留在待开列表，第二次后移除；余额用返回值，每次的点数按过期时间插入批次")
    func openGiftTwiceForYearly() async {
        let api = FakeAIBillingAPI()
        let later = Date(timeIntervalSince1970: 1_900_000_000)
        api.walletResults = [.success(AIWallet(balance: 100, lots: [AICreditLot(points: 100, expiresAt: later)]))]
        let yearly = Self.gift(id: "20", tier: .yearly, streak: 365, totalOpens: 2)
        api.checkInStatusResults = [.success(Self.pendingStatus(streak: 365, gifts: [yearly]))]
        let store = AIPointsStore(api: api, defaults: .isolated()) { "user-1" }
        await store.refresh()
        await store.refreshCheckInStatus()

        let afterFirst = Self.gift(id: "20", tier: .yearly, streak: 365, totalOpens: 2, openedCount: 1)
        api.openResults = [.success(Self.openResult(gift: afterFirst, seq: 1, points: 365, balance: 465, validDays: 365))]
        let first = await store.openGift(yearly)

        #expect((try? first.get())?.points == 365)
        #expect(api.openRequests.map { $0.seq } == [1])
        #expect(store.balance == 465)
        #expect(store.unopenedGifts == [afterFirst])
        #expect(store.lots.first?.reason == "check_in_gift_yearly")
        #expect(store.lots.compactMap(\.expiresAt) == store.lots.compactMap(\.expiresAt).sorted())

        let afterSecond = Self.gift(id: "20", tier: .yearly, streak: 365, totalOpens: 2, openedCount: 2)
        api.openResults = [.success(Self.openResult(gift: afterSecond, seq: 2, points: 233, balance: 698, validDays: 365))]
        _ = await store.openGift(afterFirst)

        #expect(api.openRequests.map { $0.seq } == [1, 2])
        #expect(api.openRequests.map { $0.id } == ["20", "20"])
        #expect(store.balance == 698)
        #expect(store.unopenedGifts.isEmpty)
        #expect(store.lots.filter { $0.reason == "check_in_gift_yearly" }.map(\.points).sorted() == [233, 365])
        #expect(!store.isOpeningGift)
        #expect(api.walletCalls == 1)

        // 开完的礼包不再发请求
        #expect(await store.openGift(afterSecond) == .failure(.invalidContract))
        #expect(api.openRequests.count == 2)
    }

    @Test("开礼包重发：这一次早已开过时不在本机写余额和批次，重新拉一次钱包")
    func openGiftDuplicateRefreshesWallet() async {
        let api = FakeAIBillingAPI()
        api.walletResults = [.success(AIWallet(balance: 130))]
        let weekly = Self.gift(id: "12", tier: .weekly, streak: 7)
        api.checkInStatusResults = [.success(Self.pendingStatus(streak: 7, gifts: [weekly]))]
        let store = AIPointsStore(api: api, defaults: .isolated()) { "user-1" }
        await store.refresh()
        await store.refreshCheckInStatus()

        let opened = Self.gift(id: "12", tier: .weekly, streak: 7, openedCount: 1)
        api.openResults = [.success(Self.openResult(gift: opened, seq: 1, points: 30, balance: 130, isDuplicate: true))]
        _ = await store.openGift(weekly)

        #expect(store.lots.isEmpty)
        #expect(api.walletCalls == 2)
        #expect(store.unopenedGifts.isEmpty)
    }

    @Test("开礼包失败：网络错误时待开列表不变、不重拉状态；礼包状态已变（404、409）时重拉签到状态")
    func openGiftFailureHandling() async {
        let api = FakeAIBillingAPI()
        api.walletResults = [.success(AIWallet(balance: 100))]
        let weekly = Self.gift(id: "12", tier: .weekly, streak: 7)
        api.checkInStatusResults = [
            .success(Self.pendingStatus(streak: 7, gifts: [weekly])),
            .success(Self.pendingStatus(streak: 7)),
        ]
        let store = AIPointsStore(api: api, defaults: .isolated()) { "user-1" }
        await store.refresh()
        await store.refreshCheckInStatus()

        api.openResults = [.failure(.network)]
        #expect(await store.openGift(weekly) == .failure(.network))
        #expect(api.checkInStatusCalls == 1)
        #expect(store.unopenedGifts == [weekly])
        #expect(store.balance == 100)
        #expect(!store.isOpeningGift)

        api.openResults = [.failure(.invalidContract)]
        #expect(await store.openGift(weekly) == .failure(.invalidContract))
        #expect(api.checkInStatusCalls == 2)
        #expect(store.unopenedGifts.isEmpty)
    }

    @Test("签到引导按账号只弹一次：看过后不再弹，重启后仍记得，换账号重新弹，未登录不弹")
    func checkInGuideIsPerAccount() {
        var userID: String? = "user-1"
        let defaults = UserDefaults.isolated()
        let store = AIPointsStore(api: FakeAIBillingAPI(), defaults: defaults) { userID }
        #expect(store.shouldShowCheckInGuide)

        store.markCheckInGuideShown()
        #expect(!store.shouldShowCheckInGuide)

        let restarted = AIPointsStore(api: FakeAIBillingAPI(), defaults: defaults) { userID }
        #expect(!restarted.shouldShowCheckInGuide)

        userID = "user-2"
        #expect(store.shouldShowCheckInGuide)

        userID = nil
        #expect(!store.shouldShowCheckInGuide)
        store.markCheckInGuideShown()
        userID = "user-2"
        #expect(store.shouldShowCheckInGuide)
    }

    @Test("开发测试：重置签到引导只影响当前账号，重启后仍生效，未登录时不做任何事")
    func resetCheckInGuideIsPerAccount() {
        var userID: String? = "user-1"
        let defaults = UserDefaults.isolated()
        let store = AIPointsStore(api: FakeAIBillingAPI(), defaults: defaults) { userID }
        store.markCheckInGuideShown()
        userID = "user-2"
        store.markCheckInGuideShown()

        userID = "user-1"
        store.resetCheckInGuide()
        #expect(store.shouldShowCheckInGuide)
        let restarted = AIPointsStore(api: FakeAIBillingAPI(), defaults: defaults) { userID }
        #expect(restarted.shouldShowCheckInGuide)

        userID = "user-2"
        #expect(!store.shouldShowCheckInGuide)

        userID = nil
        store.resetCheckInGuide()
        userID = "user-2"
        #expect(!store.shouldShowCheckInGuide)
    }

    @Test("开发测试：重置签到成功时换上返回的状态并刷新余额，失败时状态不变，未登录或不允许联网时不发请求")
    func resetCheckInForTesting() async {
        let api = FakeAIBillingAPI()
        var userID: String? = "user-1"
        var isNetworkAllowed = true
        let store = AIPointsStore(
            api: api,
            defaults: .isolated(),
            currentUserID: { userID },
            isNetworkAllowed: { isNetworkAllowed }
        )
        let weekly = Self.gift(id: "12", tier: .weekly, streak: 7)
        api.checkInStatusResults = [.success(Self.pendingStatus(streak: 7, gifts: [weekly]))]
        await store.refreshCheckInStatus()
        api.walletResults = [.success(AIWallet(balance: 101))]

        let reset = Self.pendingStatus(streak: 6)
        api.resetResults = [.success(reset)]
        #expect(await store.resetCheckInForTesting(AICheckInResetOptions(streak: 6)) == .success(reset))
        #expect(api.resetRequests == [AICheckInResetOptions(streak: 6)])
        #expect(store.checkInStatus == reset)
        #expect(store.unopenedGifts.isEmpty)
        #expect(store.balance == 101)

        // 补签卡的测试选项原样传给服务端
        let missed = AICheckInResetOptions(streak: 6, missedYesterday: true, cardUsed: true)
        #expect(await store.resetCheckInForTesting(missed) == .success(reset))

        api.resetResults = [.failure(.invalidContract)]
        #expect(await store.resetCheckInForTesting(AICheckInResetOptions(streak: 0)) == .failure(.invalidContract))
        #expect(store.checkInStatus == reset)

        isNetworkAllowed = false
        #expect(await store.resetCheckInForTesting(AICheckInResetOptions(streak: 0)) == .failure(.network))
        isNetworkAllowed = true
        userID = nil
        #expect(await store.resetCheckInForTesting(AICheckInResetOptions(streak: 0)) == .failure(.notSignedIn))
        #expect(api.resetRequests == [AICheckInResetOptions(streak: 6), missed, AICheckInResetOptions(streak: 0)])
    }

    @Test("签到日历：按月查询，未登录或不允许联网时不发请求")
    func fetchesCheckInMonth() async {
        let api = FakeAIBillingAPI()
        var userID: String? = "user-1"
        var isNetworkAllowed = true
        let store = AIPointsStore(
            api: api,
            defaults: .isolated(),
            currentUserID: { userID },
            isNetworkAllowed: { isNetworkAllowed }
        )
        let month = AICheckInMonth(
            month: "2026-11",
            today: "2026-11-18",
            firstCheckInDate: "2026-10-03",
            days: [AICheckInDay(date: "2026-11-07", points: 9, streak: 7, giftTiers: [.weekly])],
            protectedDates: ["2026-11-06"]
        )
        api.historyResult = .success(month)

        #expect(await store.fetchCheckInMonth("2026-11") == .success(month))
        #expect(api.requestedMonths == ["2026-11"])

        isNetworkAllowed = false
        #expect(await store.fetchCheckInMonth("2026-10") == .failure(.network))
        isNetworkAllowed = true
        userID = nil
        #expect(await store.fetchCheckInMonth("2026-10") == .failure(.notSignedIn))
        #expect(api.requestedMonths == ["2026-11"])
    }

    // MARK: - 辅助

    /// 周礼包规则：每连签 7 天一个，21～50 点，7 天有效。
    private static let weeklyRule = AICheckInGiftRule(
        tier: .weekly,
        everyDays: 7,
        openings: [AICheckInGiftOpening(minPoints: 21, maxPoints: 50)],
        validDays: 7
    )

    /// 年度礼包规则：每连签 365 天一个，开两次，365 天有效。
    private static let yearlyRule = AICheckInGiftRule(
        tier: .yearly,
        everyDays: 365,
        openings: [AICheckInGiftOpening(minPoints: 365, maxPoints: 365), AICheckInGiftOpening(minPoints: 100, maxPoints: 365)],
        validDays: 365
    )

    /// 签到状态里带的礼包规则。
    private static let giftRules = [weeklyRule, yearlyRule]

    /// 今天还没签、带连签天数、待开礼包和补签卡的状态。
    private static func pendingStatus(
        streak: Int,
        gifts: [AICheckInGift] = [],
        protection: AICheckInProtection? = nil
    ) -> AICheckInStatus {
        AICheckInStatus(
            date: "2026-11-18",
            checkedIn: false,
            checkIn: nil,
            minPoints: 1,
            maxPoints: 20,
            validHours: 24,
            streak: streak,
            firstCheckInDate: "2026-10-01",
            gifts: gifts,
            giftTiers: giftRules,
            protection: protection
        )
    }

    /// 构造一个礼包。
    private static func gift(
        id: String,
        tier: AICheckInGiftTier,
        streak: Int,
        totalOpens: Int = 1,
        openedCount: Int = 0
    ) -> AICheckInGift {
        AICheckInGift(
            id: id,
            tier: tier,
            streak: streak,
            checkInDate: "2026-11-18",
            totalOpens: totalOpens,
            openedCount: openedCount,
            createdAt: Date(timeIntervalSince1970: 1_795_000_000)
        )
    }

    /// 构造一次开礼包的结果。
    private static func openResult(
        gift: AICheckInGift,
        seq: Int,
        points: Int,
        balance: Int,
        isDuplicate: Bool = false,
        validDays: Int = 7
    ) -> AICheckInGiftOpenResult {
        let createdAt = Date(timeIntervalSince1970: 1_795_000_000)
        return AICheckInGiftOpenResult(
            gift: gift,
            seq: seq,
            points: points,
            isDuplicate: isDuplicate,
            balance: balance,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(Double(validDays) * 86_400)
        )
    }

    /// 今天还没签到的状态。
    private static let pendingCheckInStatus = AICheckInStatus(
        date: "2026-11-05", checkedIn: false, checkIn: nil, minPoints: 10, maxPoints: 50
    )

    /// 构造一次签到结果，24 小时后过期。
    private static func checkInResult(
        points: Int,
        balance: Int,
        isDuplicate: Bool,
        streak: Int = 0,
        gifts: [AICheckInGift] = [],
        protectedDate: String? = nil,
        cardsLeft: Int? = nil
    ) -> AICheckInResult {
        let createdAt = Date(timeIntervalSince1970: 1_793_154_720)
        return AICheckInResult(
            date: "2026-11-05",
            points: points,
            isBonus: points >= 40,
            isDuplicate: isDuplicate,
            balance: balance,
            streak: streak,
            gifts: gifts,
            protectedDate: protectedDate,
            cardsLeft: cardsLeft,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(24 * 3600)
        )
    }

    /// 构造一条流水。
    private static func entry(
        id: String = "1",
        kind: AICreditEntryKind = .charge,
        points: Int = -2,
        feature: String? = nil,
        reason: String? = nil,
        product: String? = nil
    ) -> AICreditEntry {
        AICreditEntry(
            id: id,
            kind: kind,
            points: points,
            balanceAfter: 0,
            feature: feature,
            reason: reason,
            product: product,
            createdAt: Date(timeIntervalSince1970: 1_793_154_720)
        )
    }
}

/// 按预设结果返回的点数查询接口，并记录调用次数。
@MainActor
private final class FakeAIBillingAPI: AIBillingFetching {
    /// 依次返回的余额结果；用完后重复最后一个。
    var walletResults: [Result<AIWallet, AIBillingAPIError>] = [.success(AIWallet(balance: 0))]

    /// 按游标返回的流水结果；游标为 nil 表示第一页。
    var entryPages: [String?: Result<AICreditEntryPage, AIBillingAPIError>] = [:]

    /// 档位列表结果；默认普通档每轮 1 点，精准档每轮 2 点。
    var tiersResult: Result<AIModelTierList, AIBillingAPIError> = .success(AIModelTierList(defaultTier: "standard", tiers: [
        .init(id: "standard", pointsPerTurn: 1, isAvailable: true),
        .init(id: "precise", pointsPerTurn: 2, isAvailable: true),
    ]))

    /// 依次返回的签到状态结果；用完后重复最后一个。
    var checkInStatusResults: [Result<AICheckInStatus, AIBillingAPIError>] = [.failure(.invalidContract)]

    /// 签到结果。
    var checkInResult: Result<AICheckInResult, AIBillingAPIError> = .failure(.invalidContract)

    /// 签到日历结果。
    var historyResult: Result<AICheckInMonth, AIBillingAPIError> = .failure(.invalidContract)

    /// 依次返回的开礼包结果；用完后重复最后一个。
    var openResults: [Result<AICheckInGiftOpenResult, AIBillingAPIError>] = [.failure(.invalidContract)]

    /// 依次查询过的签到日历月份。
    private(set) var requestedMonths: [String] = []

    /// 依次打开过的礼包 id 与第几次。
    private(set) var openRequests: [(id: String, seq: Int)] = []

    /// 依次返回的重置签到结果；用完后重复最后一个。
    var resetResults: [Result<AICheckInStatus, AIBillingAPIError>] = [.failure(.invalidContract)]

    /// 依次请求过的重置签到选项。
    private(set) var resetRequests: [AICheckInResetOptions] = []

    /// 设置后查询余额时先挂起，直到用例恢复。
    var walletGate: AsyncSaveGate?

    /// 设置后查询签到状态时先挂起，直到用例恢复。
    var checkInStatusGate: AsyncSaveGate?

    /// 查询余额的次数。
    private(set) var walletCalls = 0

    /// 查询档位列表的次数。
    private(set) var tierCalls = 0

    /// 查询签到状态的次数。
    private(set) var checkInStatusCalls = 0

    /// 签到的次数。
    private(set) var checkInCalls = 0

    /// 依次签到时是否用补签卡。
    private(set) var checkInRequests: [Bool] = []

    /// 依次请求过的流水游标。
    private(set) var requestedCursors: [String?] = []

    func fetchWallet() async throws -> AIWallet {
        let index = min(walletCalls, walletResults.count - 1)
        walletCalls += 1
        if let walletGate {
            await walletGate.wait()
        }
        return try walletResults[index].get()
    }

    func fetchEntries(cursor: String?) async throws -> AICreditEntryPage {
        requestedCursors.append(cursor)
        guard let result = entryPages[cursor] else { throw AIBillingAPIError.invalidContract }
        return try result.get()
    }

    func fetchModelTiers() async throws -> AIModelTierList {
        tierCalls += 1
        return try tiersResult.get()
    }

    func fetchCheckInStatus() async throws -> AICheckInStatus {
        let index = min(checkInStatusCalls, checkInStatusResults.count - 1)
        checkInStatusCalls += 1
        if let checkInStatusGate {
            await checkInStatusGate.wait()
        }
        return try checkInStatusResults[index].get()
    }

    func checkIn(useCard: Bool) async throws -> AICheckInResult {
        checkInCalls += 1
        checkInRequests.append(useCard)
        return try checkInResult.get()
    }

    func fetchCheckInHistory(month: String) async throws -> AICheckInMonth {
        requestedMonths.append(month)
        return try historyResult.get()
    }

    func openCheckInGift(id: String, seq: Int) async throws -> AICheckInGiftOpenResult {
        let index = min(openRequests.count, openResults.count - 1)
        openRequests.append((id: id, seq: seq))
        return try openResults[index].get()
    }

    func resetCheckInForTesting(_ options: AICheckInResetOptions) async throws -> AICheckInStatus {
        let index = min(resetRequests.count, resetResults.count - 1)
        resetRequests.append(options)
        return try resetResults[index].get()
    }
}

private extension UserDefaults {
    /// 每个用例独立的本机偏好，不读到模拟器里 App 保存的档位，用例之间也互不影响。
    ///
    /// - Returns: 空的偏好存储。
    static func isolated() -> UserDefaults {
        let suiteName = "AIPointsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("无法创建测试用的偏好存储")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
