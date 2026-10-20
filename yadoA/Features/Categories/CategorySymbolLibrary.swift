import Foundation

/// 图标库中的一个图标及其搜索关键词。
struct CategorySymbol: Identifiable, Hashable, Sendable {
    /// SF Symbol 名称。
    let name: String

    /// 中英文搜索关键词；搜索时不区分界面语言，全部参与匹配。
    let keywords: [String]

    /// 使用 SF Symbol 名称作为标识。
    var id: String { name }
}

/// 图标库中的一个分组及其图标。
struct CategorySymbolSection: Identifiable, Sendable {
    /// 所属主题分组。
    let group: CategorySymbolGroup

    /// 分组内的图标，按展示顺序排列。
    let symbols: [CategorySymbol]

    /// 使用分组作为标识。
    var id: CategorySymbolGroup { group }
}

/// 图标库的主题分组。
enum CategorySymbolGroup: String, CaseIterable, Identifiable, Sendable {
    /// 餐饮。
    case dining
    /// 交通。
    case transportation
    /// 购物。
    case shopping
    /// 居家。
    case home
    /// 服饰美容。
    case beauty
    /// 医疗健康。
    case health
    /// 娱乐运动。
    case entertainment
    /// 学习办公。
    case study
    /// 通讯数码。
    case digital
    /// 金融收入。
    case finance
    /// 人情社交。
    case social
    /// 宠物。
    case pets
    /// 旅行。
    case travel
    /// 其他。
    case other

    /// 使用 rawValue 作为标识。
    var id: String { rawValue }

    /// String Catalog 中的分组名称键。
    var localizationKey: String { "category.symbol.group.\(rawValue)" }

    /// 返回当前语言环境下的分组名称。
    func localizedTitle(locale: Locale = .current) -> String {
        AccountLocalization.string(localizationKey, locale: locale)
    }
}

/// 分类可选的 SF Symbols 图标库。
///
/// 只收录 iOS 18（SF Symbols 6）及更早版本已有的图标，单元测试会逐个加载确认。
/// 关键词由我们自己维护，因为 SF Symbol 名称只有英文。
enum CategorySymbolLibrary {
    /// 按分组排列的全部图标。
    static let groups: [CategorySymbolSection] = [
        CategorySymbolSection(group: .dining, symbols: [
            symbol("fork.knife", "餐饮 吃饭 正餐 午饭 晚饭 dining food meal lunch dinner"),
            symbol("fork.knife.circle", "餐厅 下馆子 restaurant eat out"),
            symbol("cup.and.saucer", "咖啡 茶 下午茶 coffee tea cafe"),
            symbol("mug", "咖啡 杯 热饮 mug coffee"),
            symbol("takeoutbag.and.cup.and.straw", "外卖 快餐 奶茶 takeout fast food delivery"),
            symbol("wineglass", "酒 红酒 喝酒 wine alcohol drink"),
            symbol("birthday.cake", "蛋糕 甜品 生日 cake dessert birthday"),
            symbol("carrot", "蔬菜 买菜 菜市场 vegetable grocery"),
            symbol("frying.pan", "做饭 下厨 厨具 cooking pan"),
            symbol("waterbottle", "饮料 水 矿泉水 water drink bottle"),
            symbol("flame", "烧烤 火锅 bbq hotpot grill"),
            symbol("basket", "菜篮 生鲜 超市 basket grocery"),
            symbol("refrigerator", "冰箱 食材 fridge"),
            symbol("cooktop", "厨房 灶台 kitchen stove")
        ]),
        CategorySymbolSection(group: .transportation, symbols: [
            symbol("bus", "公交 巴士 交通 bus transit"),
            symbol("bus.doubledecker", "大巴 观光车 coach double decker"),
            symbol("tram", "电车 有轨电车 tram"),
            symbol("tram.fill.tunnel", "地铁 轨道交通 subway metro"),
            symbol("train.side.front.car", "火车 高铁 动车 train railway"),
            symbol("car", "汽车 打车 出租车 car taxi"),
            symbol("car.side", "开车 自驾 用车 driving car"),
            symbol("bolt.car", "电动车 新能源 充电 electric car ev"),
            symbol("ev.charger", "充电桩 充电 charging ev"),
            symbol("fuelpump", "加油 油费 gas fuel petrol"),
            symbol("parkingsign", "停车 停车费 parking"),
            symbol("road.lanes", "高速 过路费 路费 toll highway road"),
            symbol("steeringwheel", "驾校 驾驶 driving steering"),
            symbol("bicycle", "自行车 单车 共享单车 bike bicycle"),
            symbol("scooter", "滑板车 电动车 scooter"),
            symbol("ferry", "轮渡 渡船 ferry boat"),
            symbol("cablecar", "缆车 索道 cable car"),
            symbol("box.truck", "货车 搬家 物流 truck moving"),
            symbol("figure.walk", "步行 走路 walk"),
            symbol("signpost.right", "路牌 出行 commute direction")
        ]),
        CategorySymbolSection(group: .shopping, symbols: [
            symbol("bag", "购物 买东西 shopping bag"),
            symbol("cart", "超市 日用 购物车 supermarket cart groceries"),
            symbol("cart.badge.plus", "网购 加购 online shopping"),
            symbol("handbag", "包 手提包 handbag purse"),
            symbol("shippingbox", "快递 包裹 网购 package delivery parcel"),
            symbol("storefront", "商店 便利店 门店 store shop"),
            symbol("tag", "标签 打折 价格 tag price sale"),
            symbol("giftcard", "礼品卡 购物卡 gift card voucher"),
            symbol("barcode", "条码 商品 barcode product"),
            symbol("qrcode", "扫码 付款 二维码 qr code scan pay"),
            symbol("percent", "折扣 优惠 discount percent"),
            symbol("bag.badge.plus", "囤货 采购 purchase"),
            symbol("sparkles", "新品 好物 sparkle new")
        ]),
        CategorySymbolSection(group: .home, symbols: [
            symbol("house", "住房 房租 房贷 家 house rent home mortgage"),
            symbol("building.2", "公寓 小区 物业 apartment property"),
            symbol("sofa", "家具 沙发 居家 furniture sofa"),
            symbol("chair.lounge", "躺椅 家居 chair lounge"),
            symbol("lamp.desk", "台灯 灯具 lamp light"),
            symbol("lightbulb", "电费 灯泡 electricity bulb"),
            symbol("bolt", "电费 用电 electricity power"),
            symbol("drop", "水费 用水 water bill"),
            symbol("flame.circle", "燃气 煤气 gas bill"),
            symbol("washer", "洗衣机 洗衣 laundry washer"),
            symbol("dishwasher", "洗碗机 dishwasher"),
            symbol("oven", "烤箱 家电 oven appliance"),
            symbol("microwave", "微波炉 microwave"),
            symbol("air.conditioner.horizontal", "空调 air conditioner"),
            symbol("fan", "风扇 fan"),
            symbol("toilet", "卫浴 马桶 toilet bathroom"),
            symbol("shower", "淋浴 洗澡 shower"),
            symbol("bathtub", "浴缸 bath"),
            symbol("key", "钥匙 门锁 key lock"),
            symbol("hammer", "维修 装修 repair hammer"),
            symbol("wrench.and.screwdriver", "维修 工具 修理 tools repair maintenance"),
            symbol("paintbrush", "装修 刷漆 paint renovation"),
            symbol("bubbles.and.sparkles", "清洁 保洁 家政 cleaning housekeeping"),
            symbol("trash", "垃圾 清运 trash garbage"),
            symbol("cabinet", "柜子 收纳 cabinet storage"),
            symbol("bed.double", "床 床品 酒店 住宿 bed hotel")
        ]),
        CategorySymbolSection(group: .beauty, symbols: [
            symbol("tshirt", "衣服 服装 服饰 clothes clothing shirt"),
            symbol("shoe", "鞋子 鞋 shoes"),
            symbol("shoe.2", "运动鞋 球鞋 sneakers"),
            symbol("hanger", "衣架 干洗 hanger dry cleaning"),
            symbol("eyeglasses", "眼镜 配镜 glasses"),
            symbol("scissors", "理发 剪发 haircut scissors"),
            symbol("comb", "美发 发型 hair comb"),
            symbol("mustache", "剃须 男士护理 shave grooming"),
            symbol("hands.sparkles", "美甲 护手 nail manicure"),
            symbol("wand.and.stars", "化妆 美妆 化妆品 makeup cosmetics"),
            symbol("crown", "首饰 珠宝 饰品 jewelry accessories"),
            symbol("applewatch", "手表 腕表 watch")
        ]),
        CategorySymbolSection(group: .health, symbols: [
            symbol("cross.case", "医疗 看病 医药箱 medical clinic"),
            symbol("cross", "医院 急诊 hospital"),
            symbol("pills", "药 买药 药店 medicine pharmacy pills"),
            symbol("stethoscope", "体检 门诊 checkup doctor"),
            symbol("syringe", "打针 疫苗 vaccine injection"),
            symbol("bandage", "外伤 创可贴 bandage"),
            symbol("facemask", "口罩 防护 mask"),
            symbol("cross.vial", "化验 检查 lab test"),
            symbol("medical.thermometer", "发烧 体温 thermometer fever"),
            symbol("heart.text.square", "健康 保健 health"),
            symbol("waveform.path.ecg", "心电图 检查 ecg"),
            symbol("brain.head.profile", "心理 咨询 mental therapy"),
            symbol("lungs", "呼吸 肺 lungs"),
            symbol("eye", "眼科 视力 eye"),
            symbol("ear", "耳科 听力 ear"),
            symbol("allergens", "过敏 allergy"),
            symbol("staroflife", "急救 救护 emergency"),
            symbol("ivfluid.bag", "输液 住院 iv hospital stay")
        ]),
        CategorySymbolSection(group: .entertainment, symbols: [
            symbol("gamecontroller", "游戏 娱乐 game gaming"),
            symbol("film", "电影 观影 movie film"),
            symbol("popcorn", "电影院 零食 cinema popcorn snack"),
            symbol("tv", "电视 追剧 视频会员 tv streaming"),
            symbol("music.note", "音乐 演唱会 music concert"),
            symbol("headphones", "耳机 听歌 headphones"),
            symbol("mic", "唱歌 ktv karaoke"),
            symbol("ticket", "门票 演出 ticket show"),
            symbol("theatermasks", "话剧 剧场 theater drama"),
            symbol("guitars", "吉他 乐器 guitar instrument"),
            symbol("pianokeys", "钢琴 乐器 piano"),
            symbol("paintpalette", "画画 美术 兴趣 art painting hobby"),
            symbol("camera", "摄影 拍照 相机 photo camera"),
            symbol("dice", "桌游 骰子 board game dice"),
            symbol("puzzlepiece", "拼图 玩具 puzzle toy"),
            symbol("party.popper", "派对 聚会 party celebration"),
            symbol("balloon", "气球 庆祝 balloon"),
            symbol("sportscourt", "球场 运动 场地 sports court"),
            symbol("soccerball", "足球 football soccer"),
            symbol("basketball", "篮球 basketball"),
            symbol("tennis.racket", "网球 羽毛球 tennis badminton"),
            symbol("figure.run", "跑步 运动 running exercise"),
            symbol("dumbbell", "健身 健身房 gym fitness"),
            symbol("figure.pool.swim", "游泳 swimming"),
            symbol("figure.yoga", "瑜伽 yoga"),
            symbol("figure.skiing.downhill", "滑雪 skiing"),
            symbol("trophy", "比赛 奖杯 competition trophy")
        ]),
        CategorySymbolSection(group: .study, symbols: [
            symbol("graduationcap", "教育 学费 上学 education tuition school"),
            symbol("book", "书 买书 阅读 book reading"),
            symbol("books.vertical", "书籍 图书馆 books library"),
            symbol("book.closed", "教材 课本 textbook"),
            symbol("character.book.closed", "语言 外语 词典 language dictionary"),
            symbol("pencil", "文具 笔 stationery pencil"),
            symbol("pencil.and.ruler", "文具 绘图 stationery"),
            symbol("highlighter", "记号笔 学习 highlighter"),
            symbol("backpack", "书包 上学 backpack"),
            symbol("studentdesk", "课程 培训 补习 class course tutoring"),
            symbol("briefcase", "工作 兼职 公文包 work job"),
            symbol("doc.text", "文件 报销 单据 document receipt"),
            symbol("folder", "资料 文件夹 folder"),
            symbol("paperclip", "办公用品 paperclip office"),
            symbol("printer", "打印 复印 print copy"),
            symbol("newspaper", "报纸 订阅 news subscription"),
            symbol("magazine", "杂志 magazine"),
            symbol("calendar", "日程 年费 calendar"),
            symbol("signature", "签约 合同 contract signature")
        ]),
        CategorySymbolSection(group: .digital, symbols: [
            symbol("phone", "话费 电话 通讯 phone bill"),
            symbol("iphone", "手机 iphone mobile"),
            symbol("ipad", "平板 ipad tablet"),
            symbol("laptopcomputer", "电脑 笔记本 laptop computer"),
            symbol("desktopcomputer", "台式机 显示器 desktop monitor"),
            symbol("keyboard", "键盘 外设 keyboard"),
            symbol("airpods", "耳机 无线耳机 earbuds"),
            symbol("wifi", "宽带 网费 网络 wifi internet broadband"),
            symbol("antenna.radiowaves.left.and.right", "流量 信号 data signal"),
            symbol("simcard", "手机卡 sim card"),
            symbol("icloud", "云存储 云服务 cloud storage"),
            symbol("play.rectangle", "会员 订阅 视频 subscription membership"),
            symbol("apps.iphone", "应用 app 软件 app purchase"),
            symbol("message", "短信 消息 message"),
            symbol("envelope", "邮件 邮寄 mail email"),
            symbol("video", "视频通话 直播 video call"),
            symbol("externaldrive", "硬盘 存储 drive storage"),
            symbol("cpu", "配件 硬件 hardware chip"),
            symbol("cable.connector", "数据线 充电器 cable charger"),
            symbol("battery.100", "充电宝 电池 battery power bank")
        ]),
        CategorySymbolSection(group: .finance, symbols: [
            symbol("banknote", "工资 现金 薪水 salary cash wage"),
            symbol("star.circle", "奖金 绩效 bonus award"),
            symbol("chart.line.uptrend.xyaxis", "投资 理财 收益 股票 investment stock return"),
            symbol("chart.line.downtrend.xyaxis", "亏损 下跌 loss"),
            symbol("chart.pie", "基金 分红 资产配置 fund dividend"),
            symbol("chart.bar", "统计 报表 chart"),
            symbol("building.columns", "银行 利息 bank interest"),
            symbol("creditcard", "信用卡 还款 刷卡 credit card repayment"),
            symbol("wallet.pass", "钱包 卡包 wallet"),
            symbol("dollarsign.circle", "美元 收入 dollar income"),
            symbol("yensign.circle", "人民币 日元 元 yuan yen"),
            symbol("eurosign.circle", "欧元 euro"),
            symbol("bitcoinsign.circle", "比特币 加密货币 bitcoin crypto"),
            symbol("arrow.left.arrow.right", "转账 换汇 transfer exchange"),
            symbol("arrow.uturn.backward.circle", "退款 退货 refund return"),
            symbol("dollarsign.arrow.circlepath", "返现 回款 cashback"),
            symbol("umbrella", "保险 保费 insurance"),
            symbol("rosette", "奖励 奖品 reward prize"),
            symbol("medal", "奖金 荣誉 medal award"),
            symbol("doc.plaintext", "税费 账单 手续费 tax bill fee")
        ]),
        CategorySymbolSection(group: .social, symbols: [
            symbol("gift", "礼物 人情 红包 送礼 gift present"),
            symbol("envelope.open", "红包 礼金 份子钱 red envelope"),
            symbol("heart", "恋爱 约会 爱心 love date"),
            symbol("person.2", "朋友 社交 请客 friends social"),
            symbol("person.3", "聚会 团建 group gathering"),
            symbol("figure.2.and.child.holdinghands", "家庭 家人 孝敬 family parents"),
            symbol("bubble.left.and.bubble.right", "聊天 应酬 chat"),
            symbol("hands.clap", "婚礼 喜事 庆祝 wedding congrats"),
            symbol("hand.raised", "捐赠 公益 慈善 donation charity"),
            symbol("hand.wave", "见面 拜访 visit"),
            symbol("figure.child", "孩子 育儿 child kids"),
            symbol("stroller", "母婴 婴儿 baby"),
            symbol("teddybear", "玩具 孩子 toy")
        ]),
        CategorySymbolSection(group: .pets, symbols: [
            symbol("pawprint", "宠物 猫狗 pet"),
            symbol("dog", "狗 狗粮 dog"),
            symbol("cat", "猫 猫粮 cat"),
            symbol("bird", "鸟 bird"),
            symbol("fish", "鱼 水族 fish aquarium"),
            symbol("tortoise", "乌龟 tortoise turtle"),
            symbol("hare", "兔子 rabbit bunny"),
            symbol("lizard", "爬宠 蜥蜴 reptile lizard"),
            symbol("ladybug", "虫子 驱虫 bug"),
            symbol("ant", "蚂蚁 昆虫 ant insect")
        ]),
        CategorySymbolSection(group: .travel, symbols: [
            symbol("airplane", "旅行 机票 飞机 travel flight plane"),
            symbol("airplane.departure", "出发 出国 departure"),
            symbol("airplane.arrival", "到达 回国 arrival"),
            symbol("suitcase", "行李 出差 suitcase business trip"),
            symbol("suitcase.rolling", "旅游 行李箱 luggage trip"),
            symbol("beach.umbrella", "海边 度假 beach vacation"),
            symbol("tent", "露营 camping tent"),
            symbol("mountain.2", "爬山 登山 mountain hiking"),
            symbol("figure.hiking", "徒步 hiking"),
            symbol("binoculars", "观光 景点 sightseeing"),
            symbol("globe.asia.australia", "出境 国际 global international"),
            symbol("map", "地图 旅游 攻略 map trip"),
            symbol("location", "定位 打卡 location"),
            symbol("sailboat", "游船 帆船 sailing cruise"),
            symbol("sun.max", "阳光 度假 sunny holiday"),
            symbol("snowflake", "冰雪 滑雪场 snow winter")
        ]),
        CategorySymbolSection(group: .other, symbols: [
            symbol("ellipsis.circle", "其他 杂项 other misc"),
            symbol("square.grid.2x2", "分类 综合 category general"),
            symbol("star", "收藏 重要 star favorite"),
            symbol("bookmark", "标记 bookmark"),
            symbol("flag", "目标 计划 flag goal"),
            symbol("bell", "提醒 订阅费 reminder bell"),
            symbol("pin", "固定 pin"),
            symbol("clock", "时间 计时 time clock"),
            symbol("hourglass", "分期 等待 installment hourglass"),
            symbol("shield", "安全 保障 shield security"),
            symbol("lock", "密码 保管 lock"),
            symbol("leaf", "环保 植物 leaf plant"),
            symbol("tree", "绿植 园艺 tree garden"),
            symbol("smoke", "烟 香烟 cigarette smoke"),
            symbol("questionmark.circle", "未知 不确定 unknown"),
            symbol("exclamationmark.triangle", "罚款 意外 fine accident"),
            symbol("archivebox", "杂物 存档 archive"),
            symbol("tray", "收纳 杂费 tray"),
            symbol("globe", "网络服务 全球 globe web")
        ])
    ]

    /// 全部图标的扁平列表。
    static var allSymbols: [CategorySymbol] {
        groups.flatMap(\.symbols)
    }

    /// 按关键词过滤图标库，保留分组；关键词为空时返回全部分组。
    ///
    /// 同时匹配所有语言的关键词和 SF Symbol 名称，不区分大小写与全半角，
    /// 所以中文界面输入 coffee、英文界面输入「咖啡」都能找到。
    ///
    /// - Parameters:
    ///   - query: 用户输入的关键词。
    ///   - locale: 比较规则使用的语言环境。
    /// - Returns: 至少有一个命中图标的分组。
    static func search(
        _ query: String,
        locale: Locale = .current
    ) -> [CategorySymbolSection] {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return groups }
        return groups.compactMap { entry in
            let matched = entry.symbols.filter { symbol in
                ([symbol.name] + symbol.keywords).contains { candidate in
                    candidate.range(
                        of: cleaned,
                        options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive],
                        locale: locale
                    ) != nil
                }
            }
            return matched.isEmpty ? nil : CategorySymbolSection(group: entry.group, symbols: matched)
        }
    }

    /// 由名称和空格分隔的关键词构造图标。
    private static func symbol(_ name: String, _ keywords: String) -> CategorySymbol {
        CategorySymbol(name: name, keywords: keywords.split(separator: " ").map(String.init))
    }
}
