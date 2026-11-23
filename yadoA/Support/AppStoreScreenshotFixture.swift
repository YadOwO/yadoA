#if DEBUG
import SwiftData
import UIKit

/// App Store 宣传图用的演示场景：在隔离内存账本里写入一套演示数据，语音和 AI 对话改由本地脚本回复，不联网、不碰真实账本。
///
/// 启动参数为 `--ui-testing-in-memory --appstore-scene <场景>`，场景见 `Scene`；语言跟随 `-AppleLanguages`，
/// 中文写入中文的账户名和备注，其他语言写英文。出图流程见 `docs/appstore/capture.sh`。只在 Debug 构建里存在。
///
/// 演示数据的金额是配好的：本月支出合计 4,286.50（餐饮 1,526.00、购物 982.30、交通 612.00、居住 560.00、
/// 娱乐 318.20，其余 288.00），净资产 92,420.35；宣传图上引用的数字与这里保持一致。
enum AppStoreScreenshotFixture {
    /// 要截的画面。
    enum Scene: String {
        /// 记账页，没有语音卡片。
        case home
        /// 记账页上说完一句话：语音卡片显示结果，流水上的对勾和划线停住不消失。
        case voice
        /// 图表页。
        case charts
        /// 账户页。
        case accounts
        /// AI 对话页：发一张超市小票记一笔，再问这个月吃饭花了多少。
        case chat
    }

    /// 当前启动参数指定的场景；没有指定或不是隔离内存启动时为 nil。
    static var scene: Scene? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--ui-testing-in-memory"),
              let index = arguments.firstIndex(of: "--appstore-scene"),
              arguments.indices.contains(index + 1)
        else { return nil }
        return Scene(rawValue: arguments[index + 1])
    }

    /// 是否启用截图场景。
    static var isEnabled: Bool { scene != nil }

    /// 首页的新增、删除提示和语音卡片是否停住不收起，方便截图。
    static var holdsHighlights: Bool { scene == .voice }

    /// 启动时落在哪个 Tab；没有启用截图场景时为 nil，按用户设置的启动页面。
    static var initialTab: AppTab? {
        switch scene {
        case .home, .voice, .chat: .home
        case .charts: .charts
        case .accounts: .accounts
        case nil: nil
        }
    }

    /// 演示数据用中文还是英文。
    private static var isChinese: Bool {
        Locale.preferredLanguages.first?.hasPrefix("zh") ?? true
    }

    // MARK: - 演示账户

    /// 演示账户。
    private enum Key: CaseIterable {
        case cmb, ccb, wechat, alipay, fund, huabei, baitiao
    }

    /// 固定的账户 ID，脚本回复里要引用。
    private static func accountID(_ key: Key) -> UUID {
        let suffix = switch key {
        case .cmb: "000000000001"
        case .ccb: "000000000002"
        case .wechat: "000000000003"
        case .alipay: "000000000004"
        case .fund: "000000000005"
        case .huabei: "000000000006"
        case .baitiao: "000000000007"
        }
        return UUID(uuidString: "A55E7000-0000-4000-8000-\(suffix)")!
    }

    /// 今天早上那杯咖啡，语音场景里会被一句话删掉。
    private static let coffeeID = UUID(uuidString: "A55E7000-0000-4000-8000-0000000000CF")!

    /// 写入账户与近三个月的流水。
    ///
    /// 语音场景写入说话之前的状态（多一杯咖啡，没有午饭和打车）；其他场景直接是说完之后的状态，各张图的数字因此对得上。
    ///
    /// - Parameter container: 截图专用的内存容器。
    /// - Throws: 流水无法通过模型校验或容器保存失败时抛出错误。
    static func seed(in container: ModelContainer) throws {
        let isBeforeVoice = scene == .voice
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let createdAt = calendar.date(byAdding: .day, value: -120, to: now) ?? now
        let context = ModelContext(container)
        context.autosaveEnabled = false

        // 说完那句话之后的余额；说之前微信多 14（付了午饭 32、退回咖啡 18），支付宝多 28（打车）
        let accounts: [(Key, AccountType, String, String, String, String?, Decimal)] = [
            (.cmb, .debitCard, "debitCard.cmb", "招商银行", "China Merchants Bank", "8821", Decimal(string: "48230.35")!),
            (.ccb, .debitCard, "debitCard.ccb", "建设银行", "CCB", "0417", 21_600),
            (.wechat, .virtualAccount, "virtualAccount.wechat", "微信", "WeChat", nil, isBeforeVoice ? 2_394 : 2_380),
            (.alipay, .virtualAccount, "virtualAccount.alipay", "支付宝", "Alipay", nil, isBeforeVoice ? 5_418 : 5_390),
            (.fund, .investment, "investment.fund", "基金", "Funds", nil, 25_000),
            (.huabei, .creditCard, "creditCard.huabei", "花呗", "Huabei", nil, 6_220),
            (.baitiao, .creditCard, "creditCard.baitiao", "京东白条", "JD Baitiao", nil, 3_960)
        ]
        for (key, type, templateID, zh, en, lastFour, balance) in accounts {
            context.insert(Account(
                id: accountID(key),
                typeRawValue: type.rawValue,
                templateID: templateID,
                name: isChinese ? zh : en,
                note: nil,
                lastFourDigits: lastFour,
                balance: balance,
                currencyCode: BookkeepingCurrency.code,
                createdAt: createdAt,
                updatedAt: now
            ))
        }
        context.insert(BookkeepingPreference(defaultAccountID: accountID(.wechat)))

        // 本月：day 是距今天几天，月初不够时都落在 1 号，合计不受今天是几号影响
        let todayDay = calendar.component(.day, from: now)
        let thisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        func currentDate(_ offset: Int) -> Date {
            let day = max(1, todayDay - offset)
            return calendar.date(byAdding: .day, value: day - 1, to: thisMonth) ?? now
        }
        // 往月：day 是几号
        func pastDate(monthsAgo: Int, day: Int) -> Date {
            let month = calendar.date(byAdding: .month, value: -monthsAgo, to: thisMonth) ?? thisMonth
            let days = calendar.range(of: .day, in: .month, for: month)?.count ?? 28
            return calendar.date(byAdding: .day, value: min(day, days) - 1, to: month) ?? month
        }

        var index = 0
        func insert(_ row: Row, on date: Date, id: UUID = UUID(), savedAt: Date? = nil) throws {
            index += 1
            let day = TransactionDay.encode(date, calendar: calendar)
            // 同一天里按写入顺序排，越晚写的越靠上；今天的不能晚于现在
            let saved = savedAt ?? min(
                calendar.startOfDay(for: date).addingTimeInterval(8 * 3600 + Double(index) * 60),
                now.addingTimeInterval(-3600 - Double(index))
            )
            let note = isChinese ? row.zh : row.en
            let amount = Decimal(string: row.amount)!
            let transaction = row.isIncome
                ? try AccountTransaction.validatingIncome(
                    id: id, accountID: accountID(row.account), categoryKey: row.category,
                    amount: amount, transactionDay: day, note: note, savedAt: saved
                )
                : try AccountTransaction.validatingExpense(
                    id: id, accountID: accountID(row.account), categoryKey: row.category,
                    amount: amount, transactionDay: day, note: note, savedAt: saved
                )
            context.insert(transaction)
        }

        for row in currentMonth { try insert(row, on: currentDate(row.day)) }
        if isBeforeVoice {
            try insert(
                Row(0, dining, "咖啡", "Coffee", "18", .wechat),
                on: now, id: coffeeID, savedAt: now.addingTimeInterval(-3 * 3600)
            )
        } else {
            for row in voiceRows { try insert(row, on: now, savedAt: now.addingTimeInterval(-600)) }
        }
        for row in lastMonth { try insert(row, on: pastDate(monthsAgo: 1, day: row.day)) }
        for row in twoMonthsAgo { try insert(row, on: pastDate(monthsAgo: 2, day: row.day)) }

        try context.alignOpeningBalancesWithBalances()
        try context.save()
    }

    // MARK: - 流水

    /// 一笔演示流水。
    private struct Row {
        /// 本月为距今天几天，往月为几号。
        let day: Int
        let category: String
        let zh: String
        let en: String
        let amount: String
        let account: Key
        var isIncome = false

        init(_ day: Int, _ category: String, _ zh: String, _ en: String, _ amount: String, _ account: Key, income: Bool = false) {
            self.day = day
            self.category = category
            self.zh = zh
            self.en = en
            self.amount = amount
            self.account = account
            isIncome = income
        }
    }

    private static let dining = ExpenseCategory.dining.rawValue
    private static let shopping = ExpenseCategory.shopping.rawValue
    private static let transport = ExpenseCategory.transportation.rawValue
    private static let housing = ExpenseCategory.housing.rawValue
    private static let fun = ExpenseCategory.entertainment.rawValue
    private static let daily = ExpenseCategory.dailyNecessities.rawValue
    private static let phone = ExpenseCategory.communication.rawValue
    private static let salary = IncomeCategory.salary.rawValue
    private static let returns = IncomeCategory.investment.rawValue

    /// 那句话记下的两笔：午饭和打车。
    private static let voiceRows: [Row] = [
        Row(0, dining, "午饭", "Lunch", "32", .wechat),
        Row(0, transport, "打车", "Taxi", "28", .alipay)
    ]

    /// 本月除那句话以外的流水。
    private static let currentMonth: [Row] = [
        // 餐饮，加上午饭共 1,526.00
        Row(1, dining, "晚饭", "Dinner", "68", .wechat),
        Row(2, dining, "午饭", "Lunch", "28", .alipay),
        Row(3, dining, "咖啡", "Coffee", "22", .wechat),
        Row(3, dining, "火锅", "Hot pot", "186", .cmb),
        Row(4, dining, "早餐", "Breakfast", "12", .alipay),
        Row(5, dining, "午饭", "Lunch", "35", .wechat),
        Row(6, dining, "聚餐", "Team dinner", "268", .cmb),
        Row(6, dining, "午饭", "Lunch", "32", .wechat),
        Row(7, dining, "外卖", "Takeout", "45.50", .alipay),
        Row(8, dining, "午饭", "Lunch", "30", .wechat),
        Row(9, dining, "咖啡", "Coffee", "26", .wechat),
        Row(10, dining, "晚饭", "Dinner", "72", .wechat),
        Row(11, dining, "午饭", "Lunch", "34", .alipay),
        Row(11, dining, "咖啡", "Coffee", "25", .wechat),
        Row(12, dining, "烧烤", "BBQ", "132", .cmb),
        Row(13, dining, "早餐", "Breakfast", "9.50", .alipay),
        Row(13, dining, "晚饭", "Dinner", "70", .wechat),
        Row(14, dining, "午饭", "Lunch", "31", .wechat),
        Row(15, dining, "奶茶", "Bubble tea", "18", .alipay),
        Row(15, dining, "晚饭", "Dinner", "76", .wechat),
        Row(16, dining, "晚饭", "Dinner", "88", .wechat),
        Row(17, dining, "午饭", "Lunch", "29", .wechat),
        Row(18, dining, "咖啡", "Coffee", "24", .wechat),
        Row(18, dining, "午饭", "Lunch", "30", .alipay),
        Row(19, dining, "晚饭", "Dinner", "56", .alipay),
        Row(20, dining, "午饭", "Lunch", "33", .wechat),
        Row(21, dining, "早餐", "Breakfast", "14", .alipay),
        // 购物 982.30
        Row(1, shopping, "超市", "Groceries", "126.40", .cmb),
        Row(5, shopping, "衣服", "Clothes", "399", .huabei),
        Row(12, shopping, "书", "Books", "68", .alipay),
        Row(16, shopping, "耳机", "Headphones", "269", .huabei),
        Row(19, shopping, "超市", "Groceries", "119.90", .cmb),
        // 交通，加上打车共 612.00
        Row(1, transport, "地铁", "Subway", "4", .alipay),
        Row(3, transport, "地铁", "Subway", "4", .alipay),
        Row(4, transport, "打车", "Taxi", "36", .alipay),
        Row(7, transport, "加油", "Gas", "320", .cmb),
        Row(10, transport, "地铁", "Subway", "8", .alipay),
        Row(13, transport, "打车", "Taxi", "42", .alipay),
        Row(15, transport, "高铁", "Train", "130", .alipay),
        Row(17, transport, "地铁", "Subway", "4", .alipay),
        Row(20, transport, "打车", "Taxi", "36", .alipay),
        // 居住 560.00
        Row(6, housing, "物业费", "Property fee", "380", .ccb),
        Row(14, housing, "水电", "Utilities", "180", .ccb),
        // 娱乐 318.20
        Row(2, fun, "电影", "Movie", "76", .wechat),
        Row(8, fun, "会员", "Membership", "25", .alipay),
        Row(11, fun, "KTV", "Karaoke", "158", .wechat),
        Row(17, fun, "游戏", "Game", "59.20", .alipay),
        // 日用 168.00、通讯 120.00
        Row(2, daily, "水果", "Fruit", "23.50", .alipay),
        Row(9, daily, "日用品", "Household", "86.90", .cmb),
        Row(20, daily, "水果", "Fruit", "57.60", .alipay),
        Row(10, phone, "话费", "Phone bill", "120", .alipay),
        // 收入
        Row(7, salary, "工资", "Salary", "12500", .cmb, income: true),
        Row(12, returns, "基金收益", "Fund returns", "186.20", .fund, income: true)
    ]

    /// 上个月，餐饮 1,736.00。
    private static let lastMonth: [Row] = [
        Row(2, dining, "午饭", "Lunch", "36", .wechat),
        Row(5, dining, "聚餐", "Team dinner", "298", .cmb),
        Row(8, dining, "火锅", "Hot pot", "212", .cmb),
        Row(11, dining, "晚饭", "Dinner", "86", .wechat),
        Row(14, dining, "外卖", "Takeout", "52", .alipay),
        Row(17, dining, "午饭", "Lunch", "34", .wechat),
        Row(19, dining, "咖啡", "Coffee", "28", .wechat),
        Row(21, dining, "烧烤", "BBQ", "168", .cmb),
        Row(23, dining, "晚饭", "Dinner", "94", .wechat),
        Row(25, dining, "早餐", "Breakfast", "16", .alipay),
        Row(27, dining, "日料", "Sushi", "712", .cmb),
        Row(4, shopping, "超市", "Groceries", "186.50", .cmb),
        Row(10, shopping, "鞋", "Shoes", "599", .huabei),
        Row(20, shopping, "超市", "Groceries", "154.50", .cmb),
        Row(26, shopping, "网购", "Online order", "300", .baitiao),
        Row(3, transport, "加油", "Gas", "300", .cmb),
        Row(9, transport, "打车", "Taxi", "48", .alipay),
        Row(16, transport, "地铁", "Subway", "12", .alipay),
        Row(22, transport, "高铁", "Train", "220", .alipay),
        Row(6, housing, "物业费", "Property fee", "380", .ccb),
        Row(14, housing, "水电", "Utilities", "180", .ccb),
        Row(12, fun, "电影", "Movie", "90", .wechat),
        Row(24, fun, "演出", "Concert", "170", .wechat),
        Row(7, daily, "日用品", "Household", "128", .cmb),
        Row(18, daily, "水果", "Fruit", "82", .alipay),
        Row(10, phone, "话费", "Phone bill", "120", .alipay),
        Row(15, salary, "工资", "Salary", "12500", .cmb, income: true),
        Row(15, returns, "基金收益", "Fund returns", "152.60", .fund, income: true)
    ]

    /// 两个月前，餐饮 1,610.00。
    private static let twoMonthsAgo: [Row] = [
        Row(3, dining, "午饭", "Lunch", "32", .wechat),
        Row(6, dining, "火锅", "Hot pot", "198", .cmb),
        Row(9, dining, "晚饭", "Dinner", "78", .wechat),
        Row(12, dining, "聚餐", "Team dinner", "326", .cmb),
        Row(15, dining, "外卖", "Takeout", "48", .alipay),
        Row(18, dining, "晚饭", "Dinner", "92", .wechat),
        Row(21, dining, "烧烤", "BBQ", "146", .cmb),
        Row(24, dining, "午饭", "Lunch", "35", .wechat),
        Row(27, dining, "日料", "Sushi", "655", .cmb),
        Row(5, shopping, "超市", "Groceries", "168", .cmb),
        Row(13, shopping, "衣服", "Clothes", "459", .huabei),
        Row(23, shopping, "超市", "Groceries", "233", .cmb),
        Row(4, transport, "加油", "Gas", "310", .cmb),
        Row(11, transport, "打车", "Taxi", "52", .alipay),
        Row(20, transport, "高铁", "Train", "178", .alipay),
        Row(6, housing, "物业费", "Property fee", "380", .ccb),
        Row(14, housing, "水电", "Utilities", "180", .ccb),
        Row(16, fun, "电影", "Movie", "80", .wechat),
        Row(26, fun, "游戏", "Game", "110", .alipay),
        Row(8, daily, "日用品", "Household", "112", .cmb),
        Row(19, daily, "水果", "Fruit", "68", .alipay),
        Row(10, phone, "话费", "Phone bill", "120", .alipay),
        Row(15, salary, "工资", "Salary", "12500", .cmb, income: true)
    ]

    // MARK: - 脚本回复

    /// 代替真实 AI 服务的会话接口：按场景依次返回写好的工具调用和回复，执行仍走 App 自己的本地逻辑。
    ///
    /// - Returns: 当前场景的脚本接口；没有脚本的场景收到请求时按服务不可用处理。
    static func makeAPI() -> VoiceSessionTurnSending {
        let today = dateString(Date())
        let text = isChinese
        var responses: [VoiceSessionTurnResponse] = []
        switch scene {
        case .voice:
            responses = [.toolCalls([
                createCall("c1", "32", .wechat, dining, text ? "午饭" : "Lunch", today),
                createCall("c2", "28", .alipay, transport, text ? "打车" : "Taxi", today),
                .deleteTransaction(id: "c3", input: VoiceDeleteTransactionInput(id: coffeeID.uuidString))
            ], canFinishLocally: true)]
        case .chat:
            let monthStart = dateString(
                Calendar(identifier: .gregorian).date(
                    from: Calendar(identifier: .gregorian).dateComponents([.year, .month], from: Date())
                ) ?? Date()
            )
            responses = [
                .toolCalls([createCall("c1", "81.40", .wechat, shopping, text ? "超市" : "Groceries", today)], canFinishLocally: true),
                .toolCalls([.summarizeTransactions(id: "c2", input: VoiceSummarizeTransactionsInput(
                    filter: VoiceTransactionFilter(dateFrom: monthStart, dateTo: today, type: .expense, categoryIds: [dining])
                ))], canFinishLocally: false),
                .reply(text: text
                    ? "这个月吃饭一共花了 ¥1,526.00，最大的一笔是聚餐 ¥268.00。"
                    : "You've spent CN¥1,526.00 on dining this month. The largest was a team dinner at CN¥268.00.")
            ]
        case .home, .charts, .accounts, nil:
            break
        }
        return ScriptedVoiceAPI(responses: responses)
    }

    /// 会话创建好以后，按场景替用户说话或发图。
    ///
    /// - Parameter voice: 根导航持有的语音状态，会话已经创建。
    static func play(on voice: VoiceBookkeepingState) async {
        guard let scene, let session = voice.session else { return }
        switch scene {
        case .voice:
            // 等记账页出现，新增和删除的提示才会标到流水上
            try? await Task.sleep(for: .seconds(1.5))
            await session.send(isChinese
                ? "午饭 32 微信付，打车 28，早上那杯咖啡删掉"
                : "Lunch 32 on WeChat, taxi 28, and delete this morning's coffee")
        case .chat:
            voice.isChatPresented = true
            try? await Task.sleep(for: .seconds(1))
            let data = receiptJPEG()
            if let fileName = try? AIChatImageStore.production.save(data) {
                await session.send("", images: [VoiceImageUpload(fileName: fileName, data: data)], scope: .chat)
            }
            try? await Task.sleep(for: .milliseconds(400))
            await session.send(
                isChinese ? "这个月吃饭花了多少" : "How much did I spend on food this month?",
                scope: .chat
            )
        case .home, .charts, .accounts:
            break
        }
    }

    private static func createCall(
        _ id: String, _ amount: String, _ account: Key, _ category: String, _ note: String, _ date: String
    ) -> VoiceToolCall {
        .createTransaction(id: id, input: VoiceCreateTransactionInput(
            type: .expense, amount: amount, accountId: accountID(account).uuidString,
            categoryId: category, date: date, note: note, inferredFields: []
        ))
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// 画一张放在桌上的超市小票，当作用户拍的照片。
    private static func receiptJPEG() -> Data {
        let size = CGSize(width: 900, height: 1200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let lines: [(String, String)] = isChinese
            ? [("牛奶", "15.80"), ("鸡蛋", "12.90"), ("西兰花", "8.60"), ("苹果", "21.20"), ("纸巾", "22.90")]
            : [("Milk", "15.80"), ("Eggs", "12.90"), ("Broccoli", "8.60"), ("Apples", "21.20"), ("Tissues", "22.90")]
        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let cg = renderer.cgContext
            // 桌面
            let colors = [UIColor(red: 0.80, green: 0.76, blue: 0.69, alpha: 1).cgColor,
                          UIColor(red: 0.69, green: 0.64, blue: 0.56, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            // 小票
            cg.translateBy(x: size.width / 2, y: size.height / 2)
            cg.rotate(by: -0.05)
            let paper = CGRect(x: -280, y: -500, width: 560, height: 1000)
            cg.setShadow(offset: CGSize(width: 0, height: 18), blur: 30, color: UIColor.black.withAlphaComponent(0.25).cgColor)
            UIColor(red: 1, green: 0.99, blue: 0.97, alpha: 1).setFill()
            cg.fill(paper)
            cg.setShadow(offset: .zero, blur: 0)

            let ink = UIColor(white: 0.18, alpha: 1)
            let mono = UIFont.monospacedSystemFont(ofSize: 30, weight: .regular)
            let bold = UIFont.monospacedSystemFont(ofSize: 34, weight: .bold)
            let centered = NSMutableParagraphStyle()
            centered.alignment = .center
            func draw(_ text: String, _ font: UIFont, at y: CGFloat, align: NSTextAlignment = .left) {
                let style = NSMutableParagraphStyle()
                style.alignment = align
                (text as NSString).draw(
                    in: CGRect(x: paper.minX + 50, y: y, width: paper.width - 100, height: 50),
                    withAttributes: [.font: font, .foregroundColor: ink, .paragraphStyle: style]
                )
            }
            draw(isChinese ? "鲜丰超市" : "FRESH MART", UIFont.systemFont(ofSize: 44, weight: .bold), at: paper.minY + 60, align: .center)
            draw(dateString(Date()) + "  12:46", mono, at: paper.minY + 130, align: .center)
            let dash = String(repeating: "-", count: 26)
            draw(dash, mono, at: paper.minY + 190, align: .center)
            for (i, line) in lines.enumerated() {
                let y = paper.minY + 250 + CGFloat(i) * 62
                draw(line.0, mono, at: y)
                draw(line.1, mono, at: y, align: .right)
            }
            draw(dash, mono, at: paper.minY + 570, align: .center)
            draw(isChinese ? "合计" : "TOTAL", bold, at: paper.minY + 630)
            draw("81.40", bold, at: paper.minY + 630, align: .right)
            draw(isChinese ? "微信支付" : "WeChat Pay", mono, at: paper.minY + 700)
            draw("81.40", mono, at: paper.minY + 700, align: .right)
            draw(isChinese ? "谢谢惠顾" : "THANK YOU", mono, at: paper.minY + 860, align: .center)
        }
        return image.jpegData(compressionQuality: 0.85) ?? Data()
    }
}

/// 按顺序返回写好的响应，不联网。
private final class ScriptedVoiceAPI: VoiceSessionTurnSending {
    private var responses: [VoiceSessionTurnResponse]

    init(responses: [VoiceSessionTurnResponse]) {
        self.responses = responses
    }

    func send(
        _ request: VoiceSessionTurnRequest,
        turnID: UUID,
        tier: AIModelTier?,
        trace: VoiceRequestTrace
    ) async throws -> VoiceSessionTurnResponse {
        // 稍等一下，处理中的状态和真实请求一样会出现
        try? await Task.sleep(for: .milliseconds(300))
        guard !responses.isEmpty else { throw VoiceSessionAPIError.serviceUnavailable }
        return responses.removeFirst()
    }
}
#endif
